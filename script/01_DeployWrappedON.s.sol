// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

/// @notice Deploys WrappedON on Ethereum (or any chain where a canonical ON address is set in Helper).
///
/// Idempotent: if `deployments/<chainId>.json` already records a `wrappedON` entry, the
/// script skips + logs rather than deploying a new wON (which would overwrite the JSON
/// and break every downstream script that reads it). To force a redeploy, delete the
/// `wrappedON` entry from the JSON file. Round-3 review [6].
contract DeployWrappedON is Script, Helper {
    /// @dev DEP-13: distinguishes "JSON file is missing" (treat as not-deployed) from
    ///      "JSON file exists but the key parsed to zero" (suspect corruption — refuse to
    ///      silently re-deploy on top of an artefact that may already be on-chain).
    error DeploymentsJsonCorrupt(uint256 chainId, string key);

    function run() external returns (WrappedON won) {
        NetworkConfig memory cfg = getConfig(block.chainid);
        _requireSet(cfg.onToken, "onToken (canonical ON ERC20)");

        address existing = Deployments.tryReadAddress(block.chainid, "wrappedON");
        if (existing != address(0)) {
            console.log("WrappedON already deployed at:", existing);
            console.log("Skipping. Delete the `wrappedON` entry in deployments/<chainId>.json to redeploy.");
            return WrappedON(existing);
        }
        // DEP-13: `tryReadAddress` returns zero for missing-file, missing-key, AND
        // corrupt-JSON. The first two are intended deploy-or-redeploy paths; the third
        // would silently re-deploy on top of a potentially-existing on-chain artefact.
        // `jsonIsValid` returns true for missing/key-absent (allow deploy) and false for
        // corrupt-JSON (refuse). Recovery for the false case: delete the file entirely
        // (or restore from a previous good copy).
        if (!Deployments.jsonIsValid(block.chainid)) {
            revert DeploymentsJsonCorrupt(block.chainid, "wrappedON");
        }

        address admin = msg.sender;
        // NOTE: minimal UUPS-proxy deploy so the project compiles. Task 6 replaces the
        // `timelock == admin` placeholder with the real `TimelockController` (the upgrader).
        address timelock = admin;

        vm.startBroadcast();
        WrappedON impl = new WrappedON();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(WrappedON.initialize, (IERC20(cfg.onToken), admin, timelock))
        );
        won = WrappedON(address(proxy));
        vm.stopBroadcast();

        console.log("WrappedON:", address(won));
        console.log("admin:    ", admin);
        Deployments.writeAddress(block.chainid, "wrappedON", address(won));
        // DEP-11: record the deployer EOA so `08_PostDeployVerify`'s `_checkDeployerRenounced`
        // can cross-validate the operator-supplied `DEPLOYER` env var against the address that
        // actually deployed wON. Without this, a typo in `DEPLOYER` would silently pass the
        // renounce assertion (a wrong address that never held the role trivially satisfies
        // `!hasRole(adminRole, deployer)`).
        Deployments.writeAddress(block.chainid, "deployer", admin);
    }
}
