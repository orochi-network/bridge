// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

/// @notice Deploys WrappedON on Ethereum (or any chain where a canonical ON address is set in Helper).
contract DeployWrappedON is Script, Helper {
    function run() external returns (WrappedON won) {
        NetworkConfig memory cfg = getConfig(block.chainid);
        _requireSet(cfg.onToken, "onToken (canonical ON ERC20)");

        address admin = msg.sender;

        vm.startBroadcast();
        won = new WrappedON(IERC20(cfg.onToken), admin);
        vm.stopBroadcast();

        console.log("WrappedON:", address(won));
        console.log("admin:    ", admin);
        Deployments.writeAddress(block.chainid, "wrappedON", address(won));
    }
}
