// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    function run() external returns (WrappedON won) {
        NetworkConfig memory cfg = getConfig(block.chainid);
        _requireSet(cfg.onToken, "onToken (canonical ON ERC20)");

        address existing = Deployments.tryReadAddress(block.chainid, "wrappedON");
        if (existing != address(0)) {
            console.log("WrappedON already deployed at:", existing);
            console.log("Skipping. Delete the `wrappedON` entry in deployments/<chainId>.json to redeploy.");
            return WrappedON(existing);
        }

        address admin = msg.sender;

        vm.startBroadcast();
        won = new WrappedON(IERC20(cfg.onToken), admin);
        vm.stopBroadcast();

        console.log("WrappedON:", address(won));
        console.log("admin:    ", admin);
        Deployments.writeAddress(block.chainid, "wrappedON", address(won));
    }
}
