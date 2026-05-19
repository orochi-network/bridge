// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

interface ITokenPoolOwnable {
    function transferOwnership(address to) external;
    function owner() external view returns (address);
}

interface ITokenAdminRegistry {
    function transferAdminRole(address localToken, address newAdmin) external;
}

interface ITokenAdminRegistryRead {
    // 96-byte static struct {administrator, pendingAdministrator, tokenPool}.
    function getTokenConfig(address localToken)
        external
        view
        returns (address administrator, address pendingAdministrator, address tokenPool);
}

/// @notice Begins the ownership handoff from the deployer EOA to the operations multisig.
///
/// What this script does (single broadcaster = current deployer/admin):
///   1. Pool: `transferOwnership(multisig)` (two-step; multisig must call `acceptOwnership` later).
///   2. wON (ETH side only): grant `DEFAULT_ADMIN_ROLE` to multisig; set CCIP admin to multisig.
///   3. TokenAdminRegistry: `transferAdminRole(token, multisig)` (two-step; multisig must call
///      `acceptAdminRole` later).
///
/// What this script does NOT do:
///   - It does NOT renounce the deployer's `DEFAULT_ADMIN_ROLE` on wON. That happens in a
///     SEPARATE step AFTER the multisig has confirmed it can act (so the bridge cannot be
///     orphaned if the multisig setup turns out to be misconfigured). Run the
///     `RenounceDeployerAdmin` contract (its `run()` entry point, defined below in this
///     file) once you've verified the multisig works.
///
/// Required env vars:
///   MULTISIG  — checksummed address of the destination multisig (e.g. Safe).
contract TransferOwnership is Script, Helper {
    error MultisigEnvMissing();
    error MultisigEqualsDeployer(address addr);

    function run() external {
        // Use envOr so the MissingMULTISIG case yields our own clear error rather than
        // Foundry's generic "EnvVarNotSet" — which masks the actual operator mistake.
        address multisig = vm.envOr("MULTISIG", address(0));
        if (multisig == address(0)) {
            revert MultisigEnvMissing();
        }
        // Guard against an operator setting MULTISIG=$DEPLOYER (typo or env collision).
        // Without this, every "handoff" call targets the deployer EOA — and
        // `RenounceDeployerAdmin` would then happily renounce while a perceived "multisig"
        // (the deployer) still holds the role, orphaning the contract. Round-2 review [3].
        if (multisig == msg.sender) {
            revert MultisigEqualsDeployer(multisig);
        }
        _handoff(multisig);
    }

    /// @dev Each sub-step is individually idempotent (round-4 review [2]). The RUNBOOK
    ///      preamble promises script 06 either no-ops or fast-fails on re-run; without
    ///      these per-step probes, a re-run after the initial broadcast would either
    ///      re-propose the pending CCIP admin (`setCCIPAdmin` succeeds while the deployer
    ///      still holds it) or revert deep inside `pool.transferOwnership` /
    ///      `registry.transferAdminRole` with a generic `OwnableUnauthorizedAccount`.
    function _handoff(address multisig) internal {
        NetworkConfig memory cfg = getConfig(block.chainid);
        _requireSet(cfg.tokenAdminRegistry, "tokenAdminRegistry");

        // Round-5 review [4]: mirror R-45's `tryReadAddress` switch here so an operator
        // who follows R-36's "delete the JSON entry to force redeploy" recovery path
        // sees a friendly diagnostic instead of a low-level `vm.parseJsonAddress` revert.
        address pool = Deployments.tryReadAddress(block.chainid, "pool");
        require(pool != address(0), "pool address not recorded in deployments JSON (run script 02 first)");
        address token;
        if (block.chainid == 1 || block.chainid == 11_155_111) {
            token = Deployments.tryReadAddress(block.chainid, "wrappedON");
            require(token != address(0), "wrappedON address not recorded in deployments JSON (run script 01 first)");
        } else {
            token = cfg.onToken;
        }
        _requireSet(token, "token");

        vm.startBroadcast();

        // ── Pool ownership ──
        // CCIP `TokenPool` inherits `ConfirmedOwnerWithProposal`, where `s_pendingOwner`
        // is `private` — no public `pendingOwner()` getter exists. So we cannot probe
        // the proposed state through a typed interface. Instead: skip ONLY when the
        // multisig already owns the pool (post-acceptance state); otherwise re-broadcast
        // `transferOwnership(multisig)`. Calling `transferOwnership` from the deployer
        // while the deployer is still the owner just overwrites `s_pendingOwner` with the
        // same address — harmless and idempotent (round-5 review [1]). After the multisig
        // accepts, the deployer is no longer owner and a re-run hits the
        // `owner == multisig` branch above and skips cleanly.
        ITokenPoolOwnable poolIface = ITokenPoolOwnable(pool);
        if (poolIface.owner() == multisig) {
            console.log("Pool ownership already held by multisig - skipping transferOwnership.");
        } else {
            // CCIP TokenPool inherits ConfirmedOwnerWithProposal where `s_pendingOwner`
            // is private, so we cannot read it to distinguish first-time vs. re-broadcast.
            // Round-6 review L1: log both possibilities explicitly rather than the
            // ambiguous "initiated (or re-broadcast)" wording.
            poolIface.transferOwnership(multisig);
            console.log("Broadcast transferOwnership on pool:", pool, "->", multisig);
            console.log("   (first-time call OR re-broadcast that overwrites any prior pending owner;");
            console.log("    multisig must now call acceptOwnership to complete the handoff)");
        }

        // After acceptOwnership, the multisig holds custody of the locked-ON reserve via
        // setRebalancer/withdrawLiquidity (the standard Chainlink CCT trust model).

        if (block.chainid == 1 || block.chainid == 11_155_111) {
            WrappedON won = WrappedON(token);
            bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();

            // OZ AccessControl.grantRole is already a no-op when the role is held, but
            // logging the difference helps re-run forensics.
            if (won.hasRole(adminRole, multisig)) {
                console.log("wON DEFAULT_ADMIN_ROLE already held by multisig - skipping grant.");
            } else {
                won.grantRole(adminRole, multisig);
                console.log("wON DEFAULT_ADMIN_ROLE granted to:", multisig);
            }

            // Two-step CCIP admin handoff (see WrappedON M-7): propose now; multisig must
            // call `acceptCCIPAdmin` to take possession. Keeps a typo'd MULTISIG from
            // permanently stranding the role.
            //
            // Re-run safety: once the multisig has called `acceptCCIPAdmin`, the deployer
            // is no longer the ccipAdmin and `setCCIPAdmin` would revert `OnlyCCIPAdmin`.
            // Skip cleanly in that case. Also skip if the proposal is already pending to
            // the multisig (no need to re-write the same value).
            if (won.getCCIPAdmin() == multisig) {
                console.log("wON CCIP admin already accepted by multisig - skipping setCCIPAdmin.");
            } else if (won.pendingCCIPAdmin() == multisig) {
                console.log("wON CCIP admin already proposed to multisig - skipping (multisig must acceptCCIPAdmin).");
            } else {
                won.setCCIPAdmin(multisig);
                require(won.pendingCCIPAdmin() == multisig, "wON pendingCCIPAdmin != multisig");
                console.log("wON CCIP admin proposed to:      ", multisig);
                console.log("   (multisig must call acceptCCIPAdmin)");
            }
        }

        // ── Registry admin role ──
        (address regAdmin, address regPending,) = ITokenAdminRegistryRead(cfg.tokenAdminRegistry).getTokenConfig(token);
        if (regAdmin == multisig) {
            console.log("Registry admin role already held by multisig - skipping transferAdminRole.");
        } else if (regPending == multisig) {
            console.log("Registry admin role transfer already initiated - skipping (multisig must acceptAdminRole).");
        } else {
            ITokenAdminRegistry(cfg.tokenAdminRegistry).transferAdminRole(token, multisig);
            console.log("Registry admin role transfer initiated:", token, "->", multisig);
            console.log("   (multisig must call acceptAdminRole)");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("Next steps (multisig actions):");
        console.log("  1. multisig.acceptOwnership() on pool", pool);
        console.log("  2. multisig.acceptAdminRole(token) on registry", cfg.tokenAdminRegistry);
        console.log("  3. After verifying multisig works, run RenounceDeployerAdmin.s.sol");
    }
}

/// @notice Final handoff step: deployer EOA renounces `DEFAULT_ADMIN_ROLE` on wON.
///         Run ONLY after verifying the multisig holds the role and has accepted pool ownership
///         + registry admin role on both chains. ETH side only — wON does not exist on BSC.
contract RenounceDeployerAdmin is Script, Helper {
    error MultisigEnvMissing();
    error MultisigEqualsDeployer(address addr);

    function run() external {
        if (block.chainid != 1 && block.chainid != 11_155_111) {
            revert UnsupportedChain(block.chainid);
        }

        // Multisig MUST be passed in and MUST already hold the role — otherwise the renounce
        // would leave the contract admin-less and permanently unmanageable.
        // Use envOr so the MissingMULTISIG case yields our own clear error rather than
        // Foundry's generic "EnvVarNotSet" — which masks the actual operator mistake.
        address multisig = vm.envOr("MULTISIG", address(0));
        if (multisig == address(0)) {
            revert MultisigEnvMissing();
        }
        // See TransferOwnership.run: if MULTISIG == deployer the role-holder check is
        // satisfied vacuously and renounce orphans the contract. Round-2 review [3].
        if (multisig == msg.sender) {
            revert MultisigEqualsDeployer(multisig);
        }

        // Use `tryReadAddress` so a deleted/missing entry surfaces with our own diagnostic
        // rather than a low-level `vm.parseJsonAddress` revert — R-36's "delete the JSON
        // entry to force redeploy" recovery path explicitly invites operators to remove
        // the entry, so the friendly message must actually fire (round-4 review [4]).
        // wON converted to `tryReadAddress` per round-7 review [3] (symmetric with pool).
        address wonAddr = Deployments.tryReadAddress(block.chainid, "wrappedON");
        require(wonAddr != address(0), "missing wrappedON in deployments JSON: run script 01 first");
        WrappedON won = WrappedON(wonAddr);
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
        address deployer = msg.sender;
        NetworkConfig memory cfg = getConfig(block.chainid);

        address pool = Deployments.tryReadAddress(block.chainid, "pool");

        _assertReadyToRenounce(won, multisig, deployer, pool, cfg.tokenAdminRegistry);

        vm.startBroadcast();
        won.renounceRole(adminRole, deployer);
        vm.stopBroadcast();

        require(!won.hasRole(adminRole, deployer), "renounce failed: deployer still has role");
        console.log("Deployer", deployer, "renounced DEFAULT_ADMIN_ROLE on wON", address(won));
    }

    /// @dev All pre-broadcast safety checks for the renounce step. Factored out of `run()`
    ///      with dependencies passed in so tests can drive each branch without writing a
    ///      `deployments/<chainId>.json` fixture (round-4 review [1]).
    ///
    ///      Order matters: cheap on-contract reads first, low-level staticcalls last,
    ///      so an operator with the most common mistake (multisig hasn't accepted the
    ///      wON role grant) sees a precise message rather than a generic
    ///      pool/registry-not-handed-off error.
    function _assertReadyToRenounce(WrappedON won, address multisig, address deployer, address pool, address registry)
        internal
        view
    {
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
        require(won.hasRole(adminRole, deployer), "deployer does not hold admin role");
        require(won.hasRole(adminRole, multisig), "multisig does NOT hold admin role yet");
        require(won.getCCIPAdmin() == multisig, "wON ccipAdmin not yet accepted by multisig");

        // Block the renounce until the pool and registry handoffs on THIS chain have
        // fully accepted into the multisig. wON itself is unaffected by either handoff
        // (it owns its own AccessControl admin path), but completing the renounce while
        // pool ownership or registry admin is mid-flight leaves the bridge in a known-
        // confusing half-handed-off state where the multisig has token admin but not the
        // pool it points at. Force the operator to complete handoff before renounce.
        // Round-3 review [4].
        require(pool != address(0), "pool address not recorded in deployments JSON");
        (bool poolOk, bytes memory poolData) = pool.staticcall(abi.encodeWithSignature("owner()"));
        require(poolOk && poolData.length == 32, "pool.owner() call failed");
        require(
            abi.decode(poolData, (address)) == multisig,
            "pool ownership NOT accepted by multisig (call acceptOwnership first)"
        );
        require(
            _registryAdministrator(registry, address(won)) == multisig,
            "registry adminRole NOT accepted by multisig (call acceptAdminRole first)"
        );
    }

    function _registryAdministrator(address registry, address token) internal view returns (address) {
        // TokenAdminRegistry.getTokenConfig returns a struct whose `administrator` field is
        // at offset 0. Calling via low-level staticcall + abi.decode avoids importing the
        // registry's struct ABI here.
        (bool ok, bytes memory data) = registry.staticcall(abi.encodeWithSignature("getTokenConfig(address)", token));
        require(ok && data.length >= 32, "registry.getTokenConfig() call failed");
        return abi.decode(data, (address));
    }
}
