// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Helper} from "./Helper.sol";

interface IGetCCIPAdmin {
    function getCCIPAdmin() external view returns (address);
}

interface IOwnable {
    function owner() external view returns (address);
}

interface IAccessControlRead {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Read-only probe of the BSC ON token's CCIP-admin registration path (issue #22).
///
///         `script/04_RegisterAdminAndPool.s.sol` resolves the admin path at *broadcast* time
///         and reverts mid-deploy if none of paths 1-3 match. This script runs the SAME probe
///         WITHOUT broadcasting, so an operator can confirm on live BSC (or a fork) which path
///         script 04 will take BEFORE mainnet — closing the `TEST-7` / legacy `H-4` open item.
///
///         Run against BSC:
///             DEPLOYER=0x<deployer EOA> make validate-bsc-admin RPC=<bsc rpc>
///         On testnet (chainId 97) the canonical ON is not hardcoded; point at your mock:
///             BSC_ON=0x<mock> DEPLOYER=0x<eoa> make validate-bsc-admin RPC=<bsc_testnet rpc>
///
///         With DEPLOYER set the script resolves the path and reverts on the path-4
///         fallthrough (so it can gate a deploy). With DEPLOYER unset it just prints the
///         token's admin surfaces. View-only; never broadcasts.
contract ValidateBscAdmin is Script, Helper {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    error NoResolvablePath(address token, address deployer);

    function run() external view {
        uint256 cid = block.chainid;
        require(cid == 56 || cid == 97, "run against BSC mainnet (56) or BSC testnet (97)");

        NetworkConfig memory cfg = getConfig(cid);
        address token = vm.envOr("BSC_ON", cfg.onToken);
        require(token != address(0), "no BSC ON token configured: set BSC_ON=0x.. (testnet mock)");

        address deployer = vm.envOr("DEPLOYER", address(0));

        console.log("BSC ON token:", token);
        if (deployer == address(0)) {
            console.log("DEPLOYER unset - probing admin surfaces only (set DEPLOYER=0x.. to resolve the path):");
        } else {
            console.log("Deployer (script 04 broadcaster):", deployer);
        }

        bool p1;
        bool p2;
        bool p3;

        // Path 1: getCCIPAdmin() (Chainlink wrapper convention; what wON itself uses).
        try IGetCCIPAdmin(token).getCCIPAdmin() returns (address a) {
            console.log("  [path 1] getCCIPAdmin() =", a);
            p1 = (deployer != address(0) && a == deployer);
        } catch {
            console.log("  [path 1] getCCIPAdmin(): not implemented");
        }

        // Path 2: Ownable.owner() (most common on BSC tokens).
        try IOwnable(token).owner() returns (address o) {
            console.log("  [path 2] owner() =", o);
            p2 = (deployer != address(0) && o == deployer);
        } catch {
            console.log("  [path 2] owner(): not implemented");
        }

        // Path 3: OZ AccessControl.DEFAULT_ADMIN_ROLE (registry 1.6 path).
        if (deployer != address(0)) {
            try IAccessControlRead(token).hasRole(DEFAULT_ADMIN_ROLE, deployer) returns (bool h) {
                console.log("  [path 3] hasRole(DEFAULT_ADMIN_ROLE, deployer) =", h);
                p3 = h;
            } catch {
                console.log("  [path 3] hasRole(): not implemented");
            }
        } else {
            console.log("  [path 3] hasRole(): skipped (DEPLOYER unset)");
        }

        if (deployer == address(0)) {
            console.log("Set DEPLOYER=0x.. and re-run to confirm which path script 04 will take.");
            return;
        }

        if (p1) {
            console.log("RESOLVED: script 04 -> path 1 (registerAdminViaGetCCIPAdmin). No front-running window.");
            return;
        }
        if (p2) {
            console.log("RESOLVED: script 04 -> path 2 (registerAdminViaOwner). No front-running window.");
            return;
        }
        if (p3) {
            console.log("RESOLVED: script 04 -> path 3 (registerAccessControlDefaultAdmin). No front-running window.");
            return;
        }

        console.log("UNRESOLVED (path 4): deployer is neither getCCIPAdmin nor owner nor DEFAULT_ADMIN_ROLE holder.");
        console.log("Coordinate with the ON token owner / Chainlink BEFORE mainnet broadcast (RUNBOOK 0.2).");
        revert NoResolvablePath(token, deployer);
    }
}
