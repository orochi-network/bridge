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

interface ITokenAdminRegistryConfig {
    // 96-byte static struct {administrator, pendingAdministrator, tokenPool}.
    function getTokenConfig(address token)
        external
        view
        returns (address administrator, address pendingAdministrator, address tokenPool);
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
///   4. Manual fallback: revert with a clear instruction. `TokenAdminRegistry.proposeAdministrator`
///      is gated to registered registry modules and the registry owner (Chainlink) — operators
///      cannot call it directly. Recovery requires either (a) the token owner calling
///      `RegistryModuleOwnerCustom.registerAdminViaOwner(token)` themselves (which is permissionless
///      for the token's `Ownable.owner`), or (b) coordinating with Chainlink to register the token
///      out-of-band. After the admin is set, re-run this script with `--skip-register` semantics —
///      `acceptAdminRole` and `setPool` are idempotent.
contract RegisterAdminAndPool is Script, Helper {
    error CannotResolveCCIPAdmin(address token, string detail);

    function run() external {
        NetworkConfig memory cfg = getConfig(block.chainid);
        _requireSet(cfg.registryModuleOwnerCustom, "registryModuleOwnerCustom");
        _requireSet(cfg.tokenAdminRegistry, "tokenAdminRegistry");

        address token = (block.chainid == 1 || block.chainid == 11_155_111)
            ? Deployments.tryReadAddress(block.chainid, "wrappedON")
            : cfg.onToken;
        _requireSet(token, "token (wON or canonical ON)");

        address pool = Deployments.tryReadAddress(block.chainid, "pool");
        _requireSet(pool, "pool (run script 02 first)");

        address broadcaster = msg.sender;

        // Idempotency probe: if a previous run already registered the broadcaster and
        // accepted the admin role, re-running `_registerAdmin`/`acceptAdminRole` would
        // revert (`AlreadyRegistered` / `OnlyPendingAdministrator`), blocking a partial-
        // failure retry. Probe the registry state first and skip the already-done steps.
        // SECURITY: DEP-1.
        (address regAdmin, address regPending, address regPool) =
            ITokenAdminRegistryConfig(cfg.tokenAdminRegistry).getTokenConfig(token);

        vm.startBroadcast();
        if (regAdmin == broadcaster) {
            // Both registration and acceptance already complete; only ensure setPool lands.
            console.log("Admin already accepted for token %s - skipping register/accept", token);
        } else if (regPending == broadcaster) {
            // Registration already proposed (broadcaster is the pending admin); only the
            // `acceptAdminRole` + `setPool` calls need to execute.
            console.log("Admin already proposed for token %s - skipping register, accepting now", token);
            TokenAdminRegistry(cfg.tokenAdminRegistry).acceptAdminRole(token);
        } else {
            _registerAdmin(token, cfg.registryModuleOwnerCustom, broadcaster);
            TokenAdminRegistry(cfg.tokenAdminRegistry).acceptAdminRole(token);
        }
        // `setPool` is owner-only but idempotent at the protocol level: writing the same
        // pool twice is a no-op. Always call it so a partial run that registered the admin
        // but never reached setPool can complete cleanly.
        if (regPool != pool) {
            TokenAdminRegistry(cfg.tokenAdminRegistry).setPool(token, pool);
        } else {
            console.log("Pool already wired in registry to %s - skipping setPool", pool);
        }
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
                console.log("[path 1] registerAdminViaGetCCIPAdmin -- token %s, admin %s", token, broadcaster);
                module.registerAdminViaGetCCIPAdmin(token);
                return;
            }
        } catch { /* not supported */ }

        // Path 2: Ownable.owner (common on many BSC tokens).
        try IOwnable(token).owner() returns (address tokenOwner) {
            if (tokenOwner == broadcaster) {
                console.log("[path 2] registerAdminViaOwner -- token %s, owner %s", token, broadcaster);
                module.registerAdminViaOwner(token);
                return;
            }
        } catch { /* not supported */ }

        // Path 3: AccessControl.DEFAULT_ADMIN_ROLE (registry 1.6 path).
        // Wrap the v1.6 selector call in its OWN try/catch so an operator running against
        // a registry without `registerAccessControlDefaultAdmin` (e.g. an unexpectedly
        // v1.5 deployment) falls through to the path-4 diagnostic revert. Catch the
        // EMPTY revert (selector not in the contract's dispatcher → 0-byte return) only;
        // any structured revert from a real v1.6 call — token already registered, registry
        // paused, AccessControl re-check failure, etc. — propagates so the operator sees
        // the actual reason rather than the misleading `CannotResolveCCIPAdmin` diagnostic
        // (round-3 review [7]).
        try IAccessControlRead(token).hasRole(0x00, broadcaster) returns (bool has) {
            if (has) {
                try IRegistryModuleOwnerCustom16(moduleAddr).registerAccessControlDefaultAdmin(token) {
                    console.log("[path 3] registerAccessControlDefaultAdmin -- token %s, admin %s", token, broadcaster);
                    return;
                } catch (bytes memory reason) {
                    // Heuristic: an EMPTY revert (`reason.length == 0`) is how Solidity
                    // surfaces a call to a function selector that isn't in the contract's
                    // dispatcher — which is what we get from an unexpectedly-v1.5 registry
                    // that doesn't have `registerAccessControlDefaultAdmin`. This is the
                    // ONLY case we fall through on. Any structured revert — `Error(string)`,
                    // custom errors, `Panic(uint256)` — has a non-zero `reason` and is
                    // bubbled up so the operator sees the actual cause (e.g. token already
                    // registered with a different admin, registry paused).
                    //
                    // Caveat: this heuristic also matches a module that explicitly does a
                    // plain `revert();` with no reason. The deployed v1.6 module doesn't do
                    // that; a future version that did would silently fall through to the
                    // path-4 `CannotResolveCCIPAdmin` diagnostic. Round-3 review [5].
                    if (reason.length != 0) {
                        assembly {
                            revert(add(reason, 0x20), mload(reason))
                        }
                    }
                }
            }
        } catch { /* token does not implement IAccessControlRead */ }

        revert CannotResolveCCIPAdmin(
            token,
            "broadcaster is neither getCCIPAdmin() nor Ownable.owner() nor AccessControl admin of token. Recovery: have the token's Ownable.owner call RegistryModuleOwnerCustom.registerAdminViaOwner(token) (permissionless for the owner), or coordinate with Chainlink to register the admin via the registry. proposeAdministrator on TokenAdminRegistry is NOT operator-callable - it is gated to registered registry modules / Chainlink."
        );
    }
}
