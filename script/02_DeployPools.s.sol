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
///
/// Idempotent: if `deployments/<chainId>.json` already records a `pool` entry, the
/// script skips + logs rather than deploying a new pool (which would overwrite the
/// JSON and orphan the previous pool from subsequent scripts). To force a redeploy,
/// delete the `pool` entry from the JSON file. Round-3 review [6].
contract DeployPools is Script, Helper {
    /// @dev DEP-13: see `01_DeployWrappedON.s.sol` for the same-named error / rationale.
    error DeploymentsJsonCorrupt(uint256 chainId, string key);

    function run() external returns (address pool) {
        NetworkConfig memory cfg = getConfig(block.chainid);

        _requireSet(cfg.router, "router");
        _requireSet(cfg.rmnProxy, "rmnProxy");

        address existing = Deployments.tryReadAddress(block.chainid, "pool");
        if (existing != address(0)) {
            console.log("Pool already deployed at:", existing);
            console.log("Skipping. Delete the `pool` entry in deployments/<chainId>.json to redeploy.");
            return existing;
        }
        // DEP-13: same JSON-validity gate as script 01. Missing file / missing key continue
        // the deploy; corrupt JSON refuses so we don't broadcast on top of a potentially-
        // existing on-chain pool. See `Deployments.jsonIsValid` NatSpec.
        if (!Deployments.jsonIsValid(block.chainid)) {
            revert DeploymentsJsonCorrupt(block.chainid, "pool");
        }

        if (block.chainid == 1 || block.chainid == 11_155_111) {
            address won = Deployments.tryReadAddress(block.chainid, "wrappedON");
            _requireSet(won, "wrappedON (run script 01 first)");
            vm.startBroadcast();
            BurnMintTokenPool p = new BurnMintTokenPool(IBurnMintERC20(won), new address[](0), cfg.rmnProxy, cfg.router);
            vm.stopBroadcast();
            pool = address(p);
            console.log("BurnMintTokenPool:", pool);
        } else if (block.chainid == 56 || block.chainid == 97) {
            _requireSet(cfg.onToken, "onToken (canonical ON on BSC)");
            vm.startBroadcast();
            // acceptLiquidity=false blocks `provideLiquidity` ONLY. By Chainlink's CCT design,
            // `withdrawLiquidity` and `setRebalancer` remain operator-controlled: the pool
            // owner (the ops multisig after handoff) has custody of the locked-ON reserve.
            // This is the documented Chainlink trust model.
            LockReleaseTokenPool p =
                new LockReleaseTokenPool(IERC20(cfg.onToken), new address[](0), cfg.rmnProxy, false, cfg.router);
            vm.stopBroadcast();
            pool = address(p);
            console.log("LockReleaseTokenPool:", pool);
        } else {
            revert UnsupportedChain(block.chainid);
        }

        Deployments.writeAddress(block.chainid, "pool", pool);
    }
}
