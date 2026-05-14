// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

interface ITokenPoolOwnable {
    function transferOwnership(address to) external;
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

interface ITokenAdminRegistry {
    function transferAdminRole(address localToken, address newAdmin) external;
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
///     orphaned if the multisig setup turns out to be misconfigured). Use the
///     `renounceDeployerAdmin()` entry point below once you've verified the multisig works.
///
/// Required env vars:
///   MULTISIG  — checksummed address of the destination multisig (e.g. Safe).
contract TransferOwnership is Script, Helper {
    error MultisigEnvMissing();

    function run() external {
        address multisig = vm.envAddress("MULTISIG");
        if (multisig == address(0)) revert MultisigEnvMissing();
        _handoff(multisig);
    }

    function _handoff(address multisig) internal {
        NetworkConfig memory cfg = getConfig(block.chainid);
        _requireSet(cfg.tokenAdminRegistry, "tokenAdminRegistry");

        address pool = Deployments.readAddress(block.chainid, "pool");
        address token = (block.chainid == 1 || block.chainid == 11_155_111)
            ? Deployments.readAddress(block.chainid, "wrappedON")
            : cfg.onToken;
        _requireSet(token, "token");

        vm.startBroadcast();

        ITokenPoolOwnable(pool).transferOwnership(multisig);
        console.log("Pool ownership transfer initiated:", pool, "->", multisig);
        console.log("   (multisig must call acceptOwnership)");

        if (block.chainid == 1 || block.chainid == 11_155_111) {
            WrappedON won = WrappedON(token);
            bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
            won.grantRole(adminRole, multisig);
            console.log("wON DEFAULT_ADMIN_ROLE granted to:", multisig);

            won.setCCIPAdmin(multisig);
            console.log("wON CCIP admin set to:           ", multisig);
        }

        ITokenAdminRegistry(cfg.tokenAdminRegistry).transferAdminRole(token, multisig);
        console.log("Registry admin role transfer initiated:", token, "->", multisig);
        console.log("   (multisig must call acceptAdminRole)");

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
    function run() external {
        if (block.chainid != 1 && block.chainid != 11_155_111) revert UnsupportedChain(block.chainid);

        WrappedON won = WrappedON(Deployments.readAddress(block.chainid, "wrappedON"));
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
        address deployer = msg.sender;

        require(won.hasRole(adminRole, deployer), "deployer does not hold admin role");
        require(address(uint160(uint256(vm.load(address(won), bytes32(0))))) != address(0), "wON not initialized");

        vm.startBroadcast();
        won.renounceRole(adminRole, deployer);
        vm.stopBroadcast();

        console.log("Deployer", deployer, "renounced DEFAULT_ADMIN_ROLE on wON", address(won));
    }
}
