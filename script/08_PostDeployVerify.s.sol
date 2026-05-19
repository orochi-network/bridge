// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {TokenPool} from "@chainlink/contracts-ccip/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/ccip/libraries/RateLimiter.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

interface ITokenAdminRegistry {
    function getPool(address localToken) external view returns (address);
}

/// @notice Programmatic verification that the deployment on the current chain is correctly wired.
///         Run on each chain AFTER 01-05 have executed. Reverts loudly on any mismatch; otherwise
///         prints a green report. View-only — no broadcast.
contract PostDeployVerify is Script, Helper {
    error PoolNotRegistered(address token, address expectedPool, address actualPool);
    error RouterMismatch(address expected, address actual);
    error RmnMismatch(address expected, address actual);
    error RemoteChainNotSupported(uint64 selector);
    error RemotePoolNotLinked(uint64 selector, address expectedRemotePool);
    error RemoteTokenMismatch(uint64 selector, address expected, address actual);
    error RateLimitDisabled(string direction);
    error RateLimitMisconfigured(string direction, uint128 capacity, uint128 rate);
    error RoleMissing(string role, address account);
    error RoleNotRenounced(string role, address account);
    error PoolOwnershipNotHandedOff(address pool, address owner, address expectedMultisig);
    error UnexpectedRebalancer(address pool, address rebalancer);

    function run() external view {
        NetworkConfig memory local = getConfig(block.chainid);
        NetworkConfig memory remote = getConfig(_remoteChainId(block.chainid));

        address localPool = Deployments.tryReadAddress(block.chainid, "pool");
        _requireSet(localPool, "localPool (run script 02 on this chain first)");
        address localToken = (block.chainid == 1 || block.chainid == 11_155_111)
            ? Deployments.tryReadAddress(block.chainid, "wrappedON")
            : local.onToken;
        _requireSet(localToken, "localToken (wON not deployed?)");
        address remotePool = Deployments.tryReadAddress(_remoteChainId(block.chainid), "pool");
        _requireSet(remotePool, "remotePool (run script 02 on the remote chain first)");
        address remoteToken = _remoteTokenAddress(remote);
        _requireSet(remoteToken, "remoteToken");
        // SECURITY: DEP-4 — surface unfilled Helper addresses as MissingAddress here
        // instead of bubbling up later as a confusing `RouterMismatch(0x0, …)`.
        _requireSet(local.tokenAdminRegistry, "tokenAdminRegistry");
        _requireSet(local.router, "router");
        _requireSet(local.rmnProxy, "rmnProxy");

        console.log("=== Post-deploy verification -- chainId %d ===", block.chainid);
        console.log("  localPool   =", localPool);
        console.log("  localToken  =", localToken);
        console.log("  remotePool  =", remotePool);
        console.log("  remoteToken =", remoteToken);

        _checkRegistry(local.tokenAdminRegistry, localToken, localPool);
        _checkPoolWiring(localPool, local.router, local.rmnProxy);
        _checkRemoteLink(localPool, remote.chainSelector, remotePool, remoteToken);
        _checkRateLimits(localPool, remote.chainSelector);

        if (block.chainid == 1 || block.chainid == 11_155_111) {
            _checkWonRoles(WrappedON(localToken), localPool);
        } else {
            // BSC side: assert the LockReleaseTokenPool's rebalancer slot is zero. Any
            // non-zero rebalancer is a custody-grade event under the Chainlink CCT trust
            // model (`setRebalancer` → `withdrawLiquidity` can drain the locked-ON
            // reserve). Catch accidental/malicious sets at deploy-time and on every
            // verify run. SECURITY: CCIP-1.
            _checkBscRebalancer(localPool);
        }

        // Optional: check ownership handoff if MULTISIG env var is set.
        try vm.envAddress("MULTISIG") returns (address multisig) {
            if (multisig != address(0)) {
                _checkOwnershipHandoff(localPool, multisig);
                if (block.chainid == 1 || block.chainid == 11_155_111) {
                    _checkDeployerRenounced(WrappedON(localToken), multisig);
                }
            }
        } catch {
            console.log("  (skipping multisig handoff check -- MULTISIG env var not set)");
        }

        console.log("All checks passed.");
    }

    function _checkRegistry(address registry, address token, address expectedPool) internal view {
        address actualPool = ITokenAdminRegistry(registry).getPool(token);
        if (actualPool != expectedPool) {
            revert PoolNotRegistered(token, expectedPool, actualPool);
        }
        console.log("[ok] TokenAdminRegistry.getPool(%s) == %s", token, expectedPool);
    }

    function _checkPoolWiring(address pool, address expectedRouter, address expectedRmn) internal view {
        address router = TokenPool(pool).getRouter();
        if (router != expectedRouter) {
            revert RouterMismatch(expectedRouter, router);
        }

        address rmn = TokenPool(pool).getRmnProxy();
        if (rmn != expectedRmn) {
            revert RmnMismatch(expectedRmn, rmn);
        }

        console.log("[ok] pool.getRouter() == %s", expectedRouter);
        console.log("[ok] pool.getRmnProxy() == %s", expectedRmn);
    }

    function _checkRemoteLink(
        address pool,
        uint64 remoteSelector,
        address expectedRemotePool,
        address expectedRemoteToken
    ) internal view {
        if (!TokenPool(pool).isSupportedChain(remoteSelector)) {
            revert RemoteChainNotSupported(remoteSelector);
        }

        bytes memory remotePoolBytes = TokenPool(pool).getRemotePool(remoteSelector);
        address remotePool = abi.decode(remotePoolBytes, (address));
        if (remotePool != expectedRemotePool) {
            revert RemotePoolNotLinked(remoteSelector, expectedRemotePool);
        }

        bytes memory remoteTokenBytes = TokenPool(pool).getRemoteToken(remoteSelector);
        address remoteToken = abi.decode(remoteTokenBytes, (address));
        if (remoteToken != expectedRemoteToken) {
            revert RemoteTokenMismatch(remoteSelector, expectedRemoteToken, remoteToken);
        }

        console.log("[ok] pool.isSupportedChain(%d) == true", remoteSelector);
        console.log("[ok] pool.getRemotePool(%d) == %s", remoteSelector, expectedRemotePool);
        console.log("[ok] pool.getRemoteToken(%d) == %s", remoteSelector, expectedRemoteToken);
    }

    function _checkRateLimits(address pool, uint64 remoteSelector) internal view {
        RateLimiter.TokenBucket memory outbound = TokenPool(pool).getCurrentOutboundRateLimiterState(remoteSelector);
        _assertEnabledAndConfigured("outbound", outbound);
        RateLimiter.TokenBucket memory inbound = TokenPool(pool).getCurrentInboundRateLimiterState(remoteSelector);
        _assertEnabledAndConfigured("inbound", inbound);

        console.log("[ok] outbound rate limit: cap=%d rate=%d", outbound.capacity, outbound.rate);
        console.log("[ok] inbound  rate limit: cap=%d rate=%d", inbound.capacity, inbound.rate);
    }

    /// @dev An `isEnabled=true` bucket with `rate == 0` or `capacity == 0` silently bricks
    ///      all transfers in that direction — the bucket never refills, so every transfer
    ///      hits `TokenMaxCapacityExceeded`. CCIP's own `_validateTokenBucketConfig` would
    ///      have rejected such a config at write time, but a future protocol change OR a
    ///      stuck state from an aborted broadcast could leave it on-chain. Mirror the
    ///      fork-test gap [7] check (`assertGt(rate, 0)` / `assertGt(capacity, 0)`) here so
    ///      `make verify-*` catches the misconfiguration BEFORE the first user transfer.
    ///      Round-3 review [3].
    function _assertEnabledAndConfigured(string memory direction, RateLimiter.TokenBucket memory bucket) internal pure {
        if (!bucket.isEnabled) {
            revert RateLimitDisabled(direction);
        }
        if (bucket.rate == 0 || bucket.capacity == 0) {
            revert RateLimitMisconfigured(direction, bucket.capacity, bucket.rate);
        }
    }

    function _checkWonRoles(WrappedON won, address pool) internal view {
        if (!won.hasRole(won.MINTER_ROLE(), pool)) {
            revert RoleMissing("MINTER_ROLE", pool);
        }
        if (!won.hasRole(won.BURNER_ROLE(), pool)) {
            revert RoleMissing("BURNER_ROLE", pool);
        }

        console.log("[ok] wON.hasRole(MINTER_ROLE, %s)", pool);
        console.log("[ok] wON.hasRole(BURNER_ROLE, %s)", pool);
    }

    /// @dev BSC-only. Asserts the `LockReleaseTokenPool`'s rebalancer slot is empty.
    ///      Non-zero means custody of the locked-ON reserve has been delegated and can be
    ///      drained via `withdrawLiquidity`. The trust model intentionally lets the multisig
    ///      do this post-handoff, but it should NEVER be set silently — every change must
    ///      come from an audited multisig action. SECURITY: CCIP-1.
    function _checkBscRebalancer(address pool) internal view {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("getRebalancer()"));
        require(ok && data.length == 32, "pool.getRebalancer() call failed");
        address rebalancer = abi.decode(data, (address));
        if (rebalancer != address(0)) {
            revert UnexpectedRebalancer(pool, rebalancer);
        }
        console.log("[ok] BSC pool.getRebalancer() == address(0)");
    }

    function _checkOwnershipHandoff(address pool, address multisig) internal view {
        // Active state: owner == multisig (after multisig.acceptOwnership()).
        // CCIP TokenPool inherits ConfirmedOwnerWithProposal where `s_pendingOwner` is
        // `private` with no public getter (see R-49 + R-7-3), so we cannot distinguish
        // "transferOwnership never called" from "transferOwnership called, multisig
        // hasn't accepted yet" — both look like `owner == deployer`. Diagnostic says
        // both possibilities honestly rather than pretending to disambiguate.
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("owner()"));
        require(ok && data.length == 32, "pool owner() call failed");
        address owner = abi.decode(data, (address));
        if (owner == multisig) {
            console.log("[ok] pool.owner() == multisig %s", multisig);
            return;
        }

        revert PoolOwnershipNotHandedOff(pool, owner, multisig);
    }

    function _checkDeployerRenounced(WrappedON won, address multisig) internal view {
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
        if (!won.hasRole(adminRole, multisig)) {
            revert RoleMissing("DEFAULT_ADMIN_ROLE", multisig);
        }
        if (won.hasRole(adminRole, msg.sender)) {
            revert RoleNotRenounced("DEFAULT_ADMIN_ROLE", msg.sender);
        }
        if (won.getCCIPAdmin() != multisig) {
            revert RoleMissing("ccipAdmin", multisig);
        }
        console.log("[ok] wON DEFAULT_ADMIN_ROLE held only by multisig %s", multisig);
        console.log("[ok] wON ccipAdmin == multisig %s", multisig);
    }

    function _remoteChainId(uint256 chainId) internal pure returns (uint256) {
        if (chainId == 1) {
            return 56;
        }
        if (chainId == 56) {
            return 1;
        }
        if (chainId == 11_155_111) {
            return 97;
        }
        if (chainId == 97) {
            return 11_155_111;
        }
        revert UnsupportedChain(chainId);
    }

    function _remoteTokenAddress(NetworkConfig memory remote) internal view returns (address) {
        // The remote token recorded on the LOCAL pool points at:
        //   - wON on the ETH side (if the remote chain is ETH/Sepolia), or
        //   - canonical ON on the BSC side.
        if (remote.chainSelector == ETH_MAINNET_SELECTOR) {
            return Deployments.tryReadAddress(1, "wrappedON");
        }
        if (remote.chainSelector == SEPOLIA_SELECTOR) {
            return Deployments.tryReadAddress(11_155_111, "wrappedON");
        }
        return remote.onToken;
    }
}
