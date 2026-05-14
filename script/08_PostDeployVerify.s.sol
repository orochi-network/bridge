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
    error RoleMissing(string role, address account);
    error PoolOwnershipNotHandedOff(address pool, address owner, address expectedMultisig);

    function run() external view {
        NetworkConfig memory local = getConfig(block.chainid);
        NetworkConfig memory remote = getConfig(_remoteChainId(block.chainid));

        address localPool = Deployments.readAddress(block.chainid, "pool");
        address localToken = (block.chainid == 1 || block.chainid == 11_155_111)
            ? Deployments.readAddress(block.chainid, "wrappedON")
            : local.onToken;
        address remotePool = Deployments.readAddress(_remoteChainId(block.chainid), "pool");
        address remoteToken = _remoteTokenAddress(remote);

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
        }

        // Optional: check ownership handoff if MULTISIG env var is set.
        try vm.envAddress("MULTISIG") returns (address multisig) {
            if (multisig != address(0)) _checkOwnershipHandoff(localPool, multisig);
        } catch {
            console.log("  (skipping multisig handoff check -- MULTISIG env var not set)");
        }

        console.log("All checks passed.");
    }

    function _checkRegistry(address registry, address token, address expectedPool) internal view {
        address actualPool = ITokenAdminRegistry(registry).getPool(token);
        if (actualPool != expectedPool) revert PoolNotRegistered(token, expectedPool, actualPool);
        console.log("[ok] TokenAdminRegistry.getPool(%s) == %s", token, expectedPool);
    }

    function _checkPoolWiring(address pool, address expectedRouter, address expectedRmn) internal view {
        address router = TokenPool(pool).getRouter();
        if (router != expectedRouter) revert RouterMismatch(expectedRouter, router);

        address rmn = TokenPool(pool).getRmnProxy();
        if (rmn != expectedRmn) revert RmnMismatch(expectedRmn, rmn);

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

        bytes[] memory remotePools = TokenPool(pool).getRemotePools(remoteSelector);
        bool found;
        for (uint256 i = 0; i < remotePools.length; ++i) {
            if (abi.decode(remotePools[i], (address)) == expectedRemotePool) {
                found = true;
                break;
            }
        }
        if (!found) revert RemotePoolNotLinked(remoteSelector, expectedRemotePool);

        bytes memory remoteTokenBytes = TokenPool(pool).getRemoteToken(remoteSelector);
        address remoteToken = abi.decode(remoteTokenBytes, (address));
        if (remoteToken != expectedRemoteToken) {
            revert RemoteTokenMismatch(remoteSelector, expectedRemoteToken, remoteToken);
        }

        console.log("[ok] pool.isSupportedChain(%d) == true", remoteSelector);
        console.log("[ok] pool.getRemotePools(%d) contains %s", remoteSelector, expectedRemotePool);
        console.log("[ok] pool.getRemoteToken(%d) == %s", remoteSelector, expectedRemoteToken);
    }

    function _checkRateLimits(address pool, uint64 remoteSelector) internal view {
        RateLimiter.TokenBucket memory outbound = TokenPool(pool).getCurrentOutboundRateLimiterState(remoteSelector);
        if (!outbound.isEnabled) revert RateLimitDisabled("outbound");
        RateLimiter.TokenBucket memory inbound = TokenPool(pool).getCurrentInboundRateLimiterState(remoteSelector);
        if (!inbound.isEnabled) revert RateLimitDisabled("inbound");

        console.log("[ok] outbound rate limit: cap=%d rate=%d", outbound.capacity, outbound.rate);
        console.log("[ok] inbound  rate limit: cap=%d rate=%d", inbound.capacity, inbound.rate);
    }

    function _checkWonRoles(WrappedON won, address pool) internal view {
        if (!won.hasRole(won.MINTER_ROLE(), pool)) revert RoleMissing("MINTER_ROLE", pool);
        if (!won.hasRole(won.BURNER_ROLE(), pool)) revert RoleMissing("BURNER_ROLE", pool);

        console.log("[ok] wON.hasRole(MINTER_ROLE, %s)", pool);
        console.log("[ok] wON.hasRole(BURNER_ROLE, %s)", pool);
    }

    function _checkOwnershipHandoff(address pool, address multisig) internal view {
        // Pool owner should be the multisig (after multisig.acceptOwnership()).
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("owner()"));
        require(ok && data.length == 32, "pool owner() call failed");
        address owner = abi.decode(data, (address));
        if (owner != multisig) revert PoolOwnershipNotHandedOff(pool, owner, multisig);
        console.log("[ok] pool.owner() == multisig %s", multisig);
    }

    function _remoteChainId(uint256 chainId) internal pure returns (uint256) {
        if (chainId == 1) return 56;
        if (chainId == 56) return 1;
        if (chainId == 11_155_111) return 97;
        if (chainId == 97) return 11_155_111;
        revert UnsupportedChain(chainId);
    }

    function _remoteTokenAddress(NetworkConfig memory remote) internal view returns (address) {
        // The remote token recorded on the LOCAL pool points at:
        //   - wON on the ETH side (if the remote chain is ETH/Sepolia), or
        //   - canonical ON on the BSC side.
        if (remote.chainSelector == ETH_MAINNET_SELECTOR) {
            return Deployments.readAddress(1, "wrappedON");
        }
        if (remote.chainSelector == SEPOLIA_SELECTOR) {
            return Deployments.readAddress(11_155_111, "wrappedON");
        }
        return remote.onToken;
    }
}
