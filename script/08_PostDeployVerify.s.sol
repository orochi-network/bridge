// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

interface ITokenAdminRegistry {
    function getPool(address localToken) external view returns (address);
    /// @dev 96-byte static struct {administrator, pendingAdministrator, tokenPool}. CCIP's
    ///      `getTokenConfig` returns the struct; flat-decoding to three addresses is ABI-
    ///      equivalent for an all-static-member struct (the same shape scripts 04/06 use).
    function getTokenConfig(address localToken)
        external
        view
        returns (address administrator, address pendingAdministrator, address tokenPool);
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
    /// @dev DEP-23: the upgrade-authority wiring (added with the UUPS/timelock model) was not
    ///      independently verified post-deploy. A role whose admin is not what the model
    ///      requires — e.g. `UPGRADER_ROLE` still admin'd by `DEFAULT_ADMIN_ROLE` instead of
    ///      self-administered — would let the multisig bypass the 48h timelock. Surface it.
    error RoleAdminMismatch(string role, bytes32 expected, bytes32 actual);
    /// @dev DEP-23: the deployed timelock's `minDelay` did not match the deploy-time value
    ///      (`TIMELOCK_DELAY` env, default 48h) — a shorter delay silently weakens the upgrade
    ///      reaction window.
    error TimelockDelayMismatch(uint256 expected, uint256 actual);
    error PoolOwnershipNotHandedOff(address pool, address owner, address expectedMultisig);
    error UnexpectedRebalancer(address pool, address rebalancer);
    /// @dev DEP-9: `TokenPool.setRemotePool` accepts raw `bytes` with no encoding constraint.
    ///      A non-32-byte stored value would otherwise surface as a low-level abi-decode panic
    ///      inside `_checkRemoteLink`; surface it as a typed revert instead.
    error MalformedRemoteEncoding(uint64 selector, string field, uint256 actualLength);
    error DeployerEnvMissing();
    /// @dev DEP-11: the recorded deployer in `deployments/<chainId>.json` did not match the
    ///      operator-supplied `DEPLOYER` env. The renounce check would otherwise vacuously
    ///      pass for any wrong address (a typo'd EOA trivially does not hold the role).
    error DeployerAddressMismatch(address envSupplied, address recorded);
    /// @dev DEP-12: a literal `MULTISIG=0x000…` would silently skip the entire handoff
    ///      block under the previous `if (multisig != address(0))` guard. The script now
    ///      treats explicit zero as an operator error: refuse to verify and surface the typo.
    error MultisigIsZeroAddress();
    /// @dev DEP-19: typed sibling errors for the staticcall helpers that previously used
    ///      `require` strings. Matches the rest of this script's error vocabulary so Slither's
    ///      `prefer-custom-errors` detector stays quiet and `vm.expectRevert(selector)` works.
    error BscRebalancerReadFailed(address pool);
    error PoolOwnerReadFailed(address pool);
    /// @dev DEP-25: `make verify-*` previously printed "all checks passed" while the
    ///      TokenAdminRegistry admin role was still pending-acceptance by the multisig (or,
    ///      if `transferAdminRole` was never broadcast, still held by the deployer). The
    ///      registry administrator can re-point the token's pool via `setPool`, so a half-
    ///      handed-off registry is a custody-relevant gap — especially on the BSC leg, which
    ///      has no `RenounceDeployerAdmin` precondition to compensate. Surface both states.
    error RegistryAdminNotHandedOff(address token, address expectedMultisig, address actualAdmin);
    error RegistryAdminTransferPending(address token, address pendingAdmin);

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

        // ETH side only: the upgradeable model (UUPS proxy + timelock) lives here. Read the
        // timelock recorded by script 01 once and reuse it for the upgrade-authority checks
        // (always-on) and the post-handoff timelock-role check (below).
        address wonTimelock;
        if (block.chainid == 1 || block.chainid == 11_155_111) {
            _checkWonRoles(WrappedON(localToken), localPool);
            wonTimelock = Deployments.tryReadAddress(block.chainid, "wrappedONTimelock");
            _requireSet(wonTimelock, "wrappedONTimelock (run script 01 on this chain first)");
            _checkUpgradeAuthority(WrappedON(localToken), wonTimelock);
        } else {
            // BSC side: assert the LockReleaseTokenPool's rebalancer slot is zero. Any
            // non-zero rebalancer is a custody-grade event under the Chainlink CCT trust
            // model (`setRebalancer` → `withdrawLiquidity` can drain the locked-ON
            // reserve). Catch accidental/malicious sets at deploy-time and on every
            // verify run. SECURITY: CCIP-1.
            _checkBscRebalancer(localPool);
        }

        // Optional: check ownership handoff if MULTISIG env var is set.
        // DEP-12: `vm.envOr` returns the default on unset; explicit zero is treated as an
        // operator typo and surfaces via `MultisigIsZeroAddress` rather than silently
        // skipping the whole handoff block. The previous `try/catch` over `envAddress` plus
        // `if (multisig != address(0))` skip combined to swallow both cases.
        address multisig = vm.envOr("MULTISIG", address(0));
        if (multisig == address(0)) {
            // Distinguish "literal MULTISIG=0x…0" from "MULTISIG unset" so the operator
            // sees the right diagnostic. `envOr` cannot disambiguate, so probe the var
            // explicitly via the try/catch.
            try vm.envAddress("MULTISIG") returns (
                address /* unused */
            ) {
                revert MultisigIsZeroAddress();
            } catch {
                console.log("  (skipping multisig handoff check -- MULTISIG env var not set)");
            }
        } else {
            _checkOwnershipHandoff(localPool, multisig);
            // DEP-25: the registry admin role must also have fully landed on the multisig.
            // Runs on BOTH chains in the MULTISIG-set branch — the BSC leg is the one with
            // no renounce precondition to otherwise catch a half-completed registry handoff.
            _checkRegistryAdminHandoff(local.tokenAdminRegistry, localToken, multisig);
            if (block.chainid == 1 || block.chainid == 11_155_111) {
                // DEP-8: read DEPLOYER from env explicitly. View-only `forge script`
                // resolves `msg.sender` to Foundry's default sender (`0x1804c8AB…`),
                // not the deployer EOA, so the renounce check was vacuously satisfied
                // when invoked through `make verify-*`. Require `DEPLOYER` so the check
                // actually tests what its name promises.
                //
                // DEP-17: use `vm.envOr` so an unset var returns zero. A MALFORMED value
                // (e.g. truncated hex) reverts deep inside the cheatcode with Foundry's
                // native error rather than being swallowed by the previous try/catch —
                // gives the operator a real diagnostic instead of a confusing
                // `DeployerEnvMissing` when the value is actually present-but-bad.
                address deployer = vm.envOr("DEPLOYER", address(0));
                if (deployer == address(0)) {
                    revert DeployerEnvMissing();
                }
                // DEP-11: cross-validate against the deployer recorded by script 01. The
                // recorded value is the address that ACTUALLY deployed wON — a typo in the
                // `DEPLOYER` env would otherwise pass the renounce check vacuously (a
                // wrong address trivially does not hold the role).
                address recorded = Deployments.tryReadAddress(block.chainid, "deployer");
                if (recorded != address(0) && recorded != deployer) {
                    revert DeployerAddressMismatch(deployer, recorded);
                }
                _checkDeployerRenounced(WrappedON(localToken), multisig, deployer);
                _checkTimelockHandoff(wonTimelock, multisig, deployer);
            }
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

    /// @dev DEP-25: verify the TokenAdminRegistry admin-role handoff completed — the multisig
    ///      is the ACTIVE `administrator` (not merely pending) and no transfer is mid-flight.
    ///      Symmetric with `RenounceDeployerAdmin._assertReadyToRenounce`'s registry check
    ///      (script 06), but unlike renounce this also runs on the BSC leg.
    function _checkRegistryAdminHandoff(address registry, address token, address multisig) internal view {
        (address administrator, address pendingAdministrator,) = ITokenAdminRegistry(registry).getTokenConfig(token);
        if (administrator != multisig) {
            revert RegistryAdminNotHandedOff(token, multisig, administrator);
        }
        if (pendingAdministrator != address(0)) {
            revert RegistryAdminTransferPending(token, pendingAdministrator);
        }
        console.log("[ok] registry administrator == multisig %s", multisig);
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

        // DEP-9: assert the stored bytes are the canonical `abi.encode(address)` shape
        // (32 bytes, left-padded) before decoding. Same protective check as the CCIP-6
        // stale-wiring path in script 05; surfaces a typed `MalformedRemoteEncoding`
        // diagnostic instead of a low-level `abi.decode` panic.
        // CCIP 1.6.1: `getRemotePools` returns `bytes[]` (a chain may hold multiple remote
        // pools); assert the expected remotePool is present.
        bytes[] memory remotePoolsBytes = TokenPool(pool).getRemotePools(remoteSelector);
        bool remotePoolLinked = false;
        for (uint256 i = 0; i < remotePoolsBytes.length; i++) {
            if (remotePoolsBytes[i].length != 32) {
                revert MalformedRemoteEncoding(remoteSelector, "remotePool", remotePoolsBytes[i].length);
            }
            if (abi.decode(remotePoolsBytes[i], (address)) == expectedRemotePool) {
                remotePoolLinked = true;
            }
        }
        if (!remotePoolLinked) {
            revert RemotePoolNotLinked(remoteSelector, expectedRemotePool);
        }

        bytes memory remoteTokenBytes = TokenPool(pool).getRemoteToken(remoteSelector);
        if (remoteTokenBytes.length != 32) {
            revert MalformedRemoteEncoding(remoteSelector, "remoteToken", remoteTokenBytes.length);
        }
        address remoteToken = abi.decode(remoteTokenBytes, (address));
        if (remoteToken != expectedRemoteToken) {
            revert RemoteTokenMismatch(remoteSelector, expectedRemoteToken, remoteToken);
        }

        console.log("[ok] pool.isSupportedChain(%d) == true", remoteSelector);
        console.log("[ok] pool.getRemotePools(%d) includes %s", remoteSelector, expectedRemotePool);
        console.log("[ok] pool.getRemoteToken(%d) == %s", remoteSelector, expectedRemoteToken);
    }

    function _checkRateLimits(address pool, uint64 remoteSelector) internal view {
        // CCIP-10: by default the verify step refuses a disabled bucket — the bridge is
        // intended to launch with rate-limits engaged. Operators who deliberately want to
        // run with limits off (and accept the corresponding C-3 unbounded-throughput
        // exposure) can set `STRICT_RATE_LIMITS=false`, which downgrades the disabled-bucket
        // revert to a console warning. The `rate==0 || capacity==0` *misconfigured* state
        // (enabled bucket that cannot serve any transfer) is ALWAYS a revert — that's the
        // silently-bricked configuration R-33 was built to catch and is never a deliberate
        // launch choice.
        bool strict = vm.envOr("STRICT_RATE_LIMITS", true);
        RateLimiter.TokenBucket memory outbound = TokenPool(pool).getCurrentOutboundRateLimiterState(remoteSelector);
        _assertConfiguredOrWarn("outbound", outbound, strict);
        RateLimiter.TokenBucket memory inbound = TokenPool(pool).getCurrentInboundRateLimiterState(remoteSelector);
        _assertConfiguredOrWarn("inbound", inbound, strict);

        // DEP-15: only log `[ok]` for buckets that are actually configured. For a disabled
        // bucket under non-strict mode, surface a `[warn]` instead so the operator-facing
        // output matches the NatSpec promise ("downgrades the disabled-bucket revert to a
        // console warning"). The previous implementation early-returned from the assertion
        // and then unconditionally logged `[ok] cap=0 rate=0`.
        _logBucket("outbound", outbound);
        _logBucket("inbound", inbound);
    }

    function _logBucket(string memory direction, RateLimiter.TokenBucket memory bucket) internal pure {
        if (bucket.isEnabled) {
            console.log("[ok] %s rate limit: cap=%d rate=%d", direction, bucket.capacity, bucket.rate);
        } else {
            console.log("[warn] %s rate limit DISABLED (STRICT_RATE_LIMITS=false)", direction);
        }
    }

    function _assertConfiguredOrWarn(string memory direction, RateLimiter.TokenBucket memory bucket, bool strict)
        internal
        pure
    {
        if (!bucket.isEnabled) {
            if (strict) {
                revert RateLimitDisabled(direction);
            }
            // Non-strict path: a deliberate "no rate-limit" launch decision. CCIP itself
            // requires capacity == rate == 0 in the disabled state, so the bucket is
            // structurally inert — no need to assert rate/capacity here.
            return;
        }
        if (bucket.rate == 0 || bucket.capacity == 0) {
            revert RateLimitMisconfigured(direction, bucket.capacity, bucket.rate);
        }
    }

    /// @dev Strict gate retained for `test/Script08Verify.t.sol` and any caller that wants
    ///      the original "must be enabled and configured" posture without threading the
    ///      `strict` toggle. Delegates to `_assertConfiguredOrWarn(strict=true)`. Round-3
    ///      review [3].
    ///
    ///      An `isEnabled=true` bucket with `rate == 0` or `capacity == 0` silently bricks
    ///      all transfers in that direction — the bucket never refills, so every transfer
    ///      hits `TokenMaxCapacityExceeded`. CCIP's own `_validateTokenBucketConfig` would
    ///      have rejected such a config at write time, but a future protocol change OR a
    ///      stuck state from an aborted broadcast could leave it on-chain.
    function _assertEnabledAndConfigured(string memory direction, RateLimiter.TokenBucket memory bucket) internal pure {
        _assertConfiguredOrWarn(direction, bucket, true);
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
        // DEP-19: typed revert so script-level errors are uniformly custom errors.
        if (!ok || data.length != 32) {
            revert BscRebalancerReadFailed(pool);
        }
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
        if (!ok || data.length != 32) {
            revert PoolOwnerReadFailed(pool);
        }
        address owner = abi.decode(data, (address));
        if (owner == multisig) {
            console.log("[ok] pool.owner() == multisig %s", multisig);
            return;
        }

        revert PoolOwnershipNotHandedOff(pool, owner, multisig);
    }

    function _checkDeployerRenounced(WrappedON won, address multisig, address deployer) internal view {
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
        if (!won.hasRole(adminRole, multisig)) {
            revert RoleMissing("DEFAULT_ADMIN_ROLE", multisig);
        }
        // DEP-8: check the supplied `deployer` rather than `msg.sender`. `forge script` in
        // view-only mode resolves msg.sender to Foundry's default sender, so the previous
        // form was always satisfied and never caught a non-renounced deployer.
        if (won.hasRole(adminRole, deployer)) {
            revert RoleNotRenounced("DEFAULT_ADMIN_ROLE", deployer);
        }
        if (won.getCCIPAdmin() != multisig) {
            revert RoleMissing("ccipAdmin", multisig);
        }
        // DEP-23: PAUSER_ROLE must have moved to the multisig and been renounced by the
        // deployer (script 06 grants it at handoff and renounces in RenounceDeployerAdmin) —
        // otherwise the emergency pause is either unavailable to ops or still wielded by the
        // retiring deployer EOA.
        bytes32 pauserRole = won.PAUSER_ROLE();
        if (!won.hasRole(pauserRole, multisig)) {
            revert RoleMissing("PAUSER_ROLE", multisig);
        }
        if (won.hasRole(pauserRole, deployer)) {
            revert RoleNotRenounced("PAUSER_ROLE", deployer);
        }
        // DEP-23: the deployer must NEVER hold UPGRADER_ROLE — it is granted only to the
        // timelock at `initialize`. A deployer copy would be an out-of-band, no-delay upgrade
        // path that defeats the timelock entirely.
        if (won.hasRole(won.UPGRADER_ROLE(), deployer)) {
            revert RoleNotRenounced("UPGRADER_ROLE", deployer);
        }
        console.log("[ok] wON DEFAULT_ADMIN_ROLE held only by multisig %s", multisig);
        console.log("[ok] wON ccipAdmin == multisig %s", multisig);
        console.log("[ok] wON DEFAULT_ADMIN_ROLE renounced by deployer %s", deployer);
        console.log("[ok] wON PAUSER_ROLE held by multisig, renounced by deployer");
        console.log("[ok] wON UPGRADER_ROLE not held by deployer");
    }

    /// @dev ETH-only, always-on. Verifies the UUPS upgrade-authority wiring established by
    ///      script 01's `initialize`, which the whole 48h-timelock guarantee rests on:
    ///        1. `UPGRADER_ROLE` is held by the deployed `TimelockController`.
    ///        2. `UPGRADER_ROLE` is SELF-ADMINISTERED (`getRoleAdmin == UPGRADER_ROLE`), so
    ///           `DEFAULT_ADMIN_ROLE` (the multisig post-handoff) cannot grant it and upgrade
    ///           with no delay (SECURITY UPG-1 mitigation #3).
    ///        3. `PAUSER_ROLE` keeps the default `DEFAULT_ADMIN_ROLE` admin (pause is halt-only).
    ///        4. The timelock's `minDelay` matches the deploy-time value (`TIMELOCK_DELAY` env,
    ///           default 48h).
    function _checkUpgradeAuthority(WrappedON won, address timelock) internal view {
        bytes32 upgrader = won.UPGRADER_ROLE();
        if (!won.hasRole(upgrader, timelock)) {
            revert RoleMissing("UPGRADER_ROLE", timelock);
        }
        bytes32 upgraderAdmin = won.getRoleAdmin(upgrader);
        if (upgraderAdmin != upgrader) {
            revert RoleAdminMismatch("UPGRADER_ROLE", upgrader, upgraderAdmin);
        }
        bytes32 defaultAdmin = won.DEFAULT_ADMIN_ROLE();
        bytes32 pauserAdmin = won.getRoleAdmin(won.PAUSER_ROLE());
        if (pauserAdmin != defaultAdmin) {
            revert RoleAdminMismatch("PAUSER_ROLE", defaultAdmin, pauserAdmin);
        }
        uint256 expectedDelay = vm.envOr("TIMELOCK_DELAY", uint256(172_800));
        uint256 actualDelay = TimelockController(payable(timelock)).getMinDelay();
        if (actualDelay != expectedDelay) {
            revert TimelockDelayMismatch(expectedDelay, actualDelay);
        }
        console.log("[ok] wON UPGRADER_ROLE held by timelock %s", timelock);
        console.log("[ok] wON UPGRADER_ROLE self-administered (admin == UPGRADER_ROLE)");
        console.log("[ok] wON PAUSER_ROLE admin == DEFAULT_ADMIN_ROLE");
        console.log("[ok] timelock minDelay == %d", actualDelay);
    }

    /// @dev ETH-only, post-handoff. The timelock's PROPOSER/EXECUTOR/CANCELLER roles must be
    ///      held by the multisig and renounced by the deployer (script 06). If the multisig
    ///      lacks any, the upgrade path is stranded (the timelock self-administers these roles,
    ///      so they can only be re-added via a timelocked proposal); if the deployer kept any,
    ///      it retains an out-of-band path to drive the timelock.
    function _checkTimelockHandoff(address timelock, address multisig, address deployer) internal view {
        TimelockController tl = TimelockController(payable(timelock));
        bytes32 proposer = tl.PROPOSER_ROLE();
        bytes32 executor = tl.EXECUTOR_ROLE();
        bytes32 canceller = tl.CANCELLER_ROLE();
        if (!tl.hasRole(proposer, multisig)) {
            revert RoleMissing("timelock PROPOSER_ROLE", multisig);
        }
        if (!tl.hasRole(executor, multisig)) {
            revert RoleMissing("timelock EXECUTOR_ROLE", multisig);
        }
        if (!tl.hasRole(canceller, multisig)) {
            revert RoleMissing("timelock CANCELLER_ROLE", multisig);
        }
        if (tl.hasRole(proposer, deployer)) {
            revert RoleNotRenounced("timelock PROPOSER_ROLE", deployer);
        }
        if (tl.hasRole(executor, deployer)) {
            revert RoleNotRenounced("timelock EXECUTOR_ROLE", deployer);
        }
        if (tl.hasRole(canceller, deployer)) {
            revert RoleNotRenounced("timelock CANCELLER_ROLE", deployer);
        }
        // DEP-24: the deployer's SETUP-ONLY timelock DEFAULT_ADMIN_ROLE (script 01) must be
        // renounced (script 06) so the timelock is fully self-administered — otherwise the
        // deployer retains the power to grant itself proposer/executor and drive an upgrade.
        if (tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), deployer)) {
            revert RoleNotRenounced("timelock DEFAULT_ADMIN_ROLE", deployer);
        }
        console.log("[ok] timelock PROPOSER/EXECUTOR/CANCELLER held by multisig %s", multisig);
        console.log("[ok] timelock roles + setup-admin renounced by deployer %s", deployer);
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
