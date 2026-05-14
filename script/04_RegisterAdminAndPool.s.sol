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

interface IAccessControlRead {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @dev The deployed `RegistryModuleOwnerCustom` on Ethereum and BSC mainnet is at version
/// 1.6.0, which exposes `registerAccessControlDefaultAdmin` for tokens that use OZ
/// `AccessControl.DEFAULT_ADMIN_ROLE`. The vendored ABI at v2.17.0-ccip1.5.16 only ships the
/// 1.5.0 contract, so we call the extra selector via this interface.
interface IRegistryModuleOwnerCustom16 {
    function registerAccessControlDefaultAdmin(address token) external;
}

/// @notice Registers the token admin in TokenAdminRegistry, accepts the admin role, and sets the pool.
///
/// Ethereum path: wON exposes `getCCIPAdmin` — use `registerAdminViaGetCCIPAdmin`.
/// BSC path: probes the canonical ON token for whichever admin interface it supports.
///   1. `getCCIPAdmin` (matches Chainlink's wrapper convention).
///   2. `Ownable.owner` (most common on BSC tokens).
///   3. OZ `AccessControl.DEFAULT_ADMIN_ROLE` (registry 1.6 path).
///   4. Manual fallback: revert with a clear instruction — the token owner must call
///      `TokenAdminRegistry.proposeAdministrator(token, admin)` manually before this script can finish.
contract RegisterAdminAndPool is Script, Helper {
    error CannotResolveCCIPAdmin(address token, string detail);

    function run() external {
        NetworkConfig memory cfg = getConfig(block.chainid);
        _requireSet(cfg.registryModuleOwnerCustom, "registryModuleOwnerCustom");
        _requireSet(cfg.tokenAdminRegistry, "tokenAdminRegistry");

        address token = (block.chainid == 1 || block.chainid == 11_155_111)
            ? Deployments.readAddress(block.chainid, "wrappedON")
            : cfg.onToken;
        _requireSet(token, "token (wON or canonical ON)");

        address pool = Deployments.readAddress(block.chainid, "pool");
        _requireSet(pool, "pool (run script 02 first)");

        address broadcaster = msg.sender;

        vm.startBroadcast();
        _registerAdmin(token, cfg.registryModuleOwnerCustom, broadcaster);
        TokenAdminRegistry(cfg.tokenAdminRegistry).acceptAdminRole(token);
        TokenAdminRegistry(cfg.tokenAdminRegistry).setPool(token, pool);
        vm.stopBroadcast();

        console.log("Registered admin + pool for token %s -> pool %s", token, pool);

        // Post-registration assertion — fails fast if the registration didn't land where we expect.
        address registered = TokenAdminRegistry(cfg.tokenAdminRegistry).getPool(token);
        require(registered == pool, "TokenAdminRegistry pool mismatch after setPool");
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

        // Path 3: AccessControl.DEFAULT_ADMIN_ROLE (registry 1.6 path).
        try IAccessControlRead(token).hasRole(0x00, broadcaster) returns (bool has) {
            if (has) {
                IRegistryModuleOwnerCustom16(moduleAddr).registerAccessControlDefaultAdmin(token);
                return;
            }
        } catch { /* not supported */ }

        revert CannotResolveCCIPAdmin(
            token,
            "broadcaster is neither getCCIPAdmin() nor owner() nor AccessControl admin of token; ask token owner to call TokenAdminRegistry.proposeAdministrator(token, broadcaster), then re-run skipping registration."
        );
    }
}
