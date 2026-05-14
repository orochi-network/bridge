// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {TokenAdminRegistry} from "@chainlink/contracts-ccip/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {
    RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";

import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

interface IGetCCIPAdmin {
    function getCCIPAdmin() external view returns (address);
}

interface IOwnable {
    function owner() external view returns (address);
}

/// @notice Registers the token admin in TokenAdminRegistry, accepts the admin role, and sets the pool.
///
/// Ethereum path: wON exposes `getCCIPAdmin` — use `registerAdminViaGetCCIPAdmin`.
/// BSC path: branches on what the existing ON token supports.
///   1. Tries `getCCIPAdmin` first (cheap probe).
///   2. Falls back to `registerAdminViaOwner` if `Ownable.owner` returns the broadcaster.
///   3. Reverts with a clear instruction if neither works — the token owner must call
///      `TokenAdminRegistry.proposeAdministrator(token, admin)` manually before this script can finish.
contract RegisterAdminAndPool is Script, Helper {
    error CannotResolveCCIPAdmin(address token, string detail);

    function run() external {
        NetworkConfig memory cfg = getConfig(block.chainid);

        address token = (block.chainid == 1 || block.chainid == 11_155_111)
            ? Deployments.readAddress(block.chainid, "wrappedON")
            : cfg.onToken;
        _requireSet(token, "token (wON or canonical ON)");

        address pool = Deployments.readAddress(block.chainid, "pool");
        address broadcaster = msg.sender;

        vm.startBroadcast();
        _registerAdmin(token, cfg.registryModuleOwnerCustom, broadcaster);
        TokenAdminRegistry(cfg.tokenAdminRegistry).acceptAdminRole(token);
        TokenAdminRegistry(cfg.tokenAdminRegistry).setPool(token, pool);
        vm.stopBroadcast();

        console.log("Registered admin + pool for token %s -> pool %s", token, pool);
    }

    function _registerAdmin(address token, address moduleAddr, address broadcaster) internal {
        RegistryModuleOwnerCustom module = RegistryModuleOwnerCustom(moduleAddr);

        // Path 1: getCCIPAdmin (wON, or any token implementing IGetCCIPAdmin).
        try IGetCCIPAdmin(token).getCCIPAdmin() returns (address ccipAdmin) {
            if (ccipAdmin == broadcaster) {
                module.registerAdminViaGetCCIPAdmin(token);
                return;
            }
        } catch { /* not supported */ }

        // Path 2: Ownable.owner (common on many BSC tokens).
        try IOwnable(token).owner() returns (address tokenOwner) {
            if (tokenOwner == broadcaster) {
                module.registerAdminViaOwner(token);
                return;
            }
        } catch { /* not supported */ }

        revert CannotResolveCCIPAdmin(
            token,
            "broadcaster is neither getCCIPAdmin() nor owner() of token; ask token owner to call TokenAdminRegistry.proposeAdministrator(token, broadcaster), then re-run skipping registration."
        );
    }
}
