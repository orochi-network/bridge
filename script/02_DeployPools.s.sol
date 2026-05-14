// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {BurnMintTokenPool} from "@chainlink/contracts-ccip/ccip/pools/BurnMintTokenPool.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/ccip/pools/LockReleaseTokenPool.sol";
import {IBurnMintERC20} from "@chainlink/contracts-ccip/shared/token/ERC20/IBurnMintERC20.sol";
// Pool ctors expect the CCIP-vendored IERC20; importing the same path avoids a type clash.
import {IERC20} from "@chainlink/contracts-ccip/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

/// @notice Chain-dispatched pool deployment.
///         - Ethereum (chainid 1 / 11155111): deploys BurnMintTokenPool against wON.
///         - BSC      (chainid 56 / 97):      deploys LockReleaseTokenPool against ON.
contract DeployPools is Script, Helper {
    function run() external returns (address pool) {
        NetworkConfig memory cfg = getConfig(block.chainid);

        if (block.chainid == 1 || block.chainid == 11_155_111) {
            address won = Deployments.readAddress(block.chainid, "wrappedON");
            vm.startBroadcast();
            BurnMintTokenPool p =
                new BurnMintTokenPool(IBurnMintERC20(won), 18, new address[](0), cfg.rmnProxy, cfg.router);
            vm.stopBroadcast();
            pool = address(p);
            console.log("BurnMintTokenPool:", pool);
        } else if (block.chainid == 56 || block.chainid == 97) {
            _requireSet(cfg.onToken, "onToken (canonical ON on BSC)");
            vm.startBroadcast();
            LockReleaseTokenPool p = new LockReleaseTokenPool(
                IERC20(cfg.onToken),
                18,
                new address[](0),
                cfg.rmnProxy,
                false, // acceptLiquidity = false: withdrawLiquidity is permanently disabled (footgun removed)
                cfg.router
            );
            vm.stopBroadcast();
            pool = address(p);
            console.log("LockReleaseTokenPool:", pool);
        } else {
            revert UnsupportedChain(block.chainid);
        }

        Deployments.writeAddress(block.chainid, "pool", pool);
    }
}
