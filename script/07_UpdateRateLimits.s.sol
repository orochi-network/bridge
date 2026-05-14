// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {TokenPool} from "@chainlink/contracts-ccip/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/ccip/libraries/RateLimiter.sol";

import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

/// @notice Adjusts the rate-limit bucket on the local pool for its remote counterpart.
///         Callable by pool owner or the configured rate-limit admin.
///
/// Required env vars:
///   OUTBOUND_CAPACITY  uint128, wei (e.g. 200000000000000000000000 = 200,000 ON)
///   OUTBOUND_RATE      uint128, tokens/sec
///   INBOUND_CAPACITY   uint128
///   INBOUND_RATE       uint128
///   OUTBOUND_ENABLED   bool ("true"/"false") — default true
///   INBOUND_ENABLED    bool — default true
contract UpdateRateLimits is Script, Helper {
    function run() external {
        NetworkConfig memory local = getConfig(block.chainid);
        uint64 remoteSelector = _remoteSelector(block.chainid);

        address localPool = Deployments.readAddress(block.chainid, "pool");

        RateLimiter.Config memory outbound = RateLimiter.Config({
            isEnabled: vm.envOr("OUTBOUND_ENABLED", true),
            capacity: uint128(vm.envUint("OUTBOUND_CAPACITY")),
            rate: uint128(vm.envUint("OUTBOUND_RATE"))
        });
        RateLimiter.Config memory inbound = RateLimiter.Config({
            isEnabled: vm.envOr("INBOUND_ENABLED", true),
            capacity: uint128(vm.envUint("INBOUND_CAPACITY")),
            rate: uint128(vm.envUint("INBOUND_RATE"))
        });

        vm.startBroadcast();
        TokenPool(localPool).setChainRateLimiterConfig(remoteSelector, outbound, inbound);
        vm.stopBroadcast();

        console.log("Pool %s (chain %d) -> remote selector %d", localPool, local.chainSelector, remoteSelector);
        console.log("  outbound: enabled=%s cap=%d rate=%d", outbound.isEnabled, outbound.capacity, outbound.rate);
        console.log("  inbound:  enabled=%s cap=%d rate=%d", inbound.isEnabled, inbound.capacity, inbound.rate);
    }

    function _remoteSelector(uint256 chainId) internal pure returns (uint64) {
        if (chainId == 1) return BSC_MAINNET_SELECTOR;
        if (chainId == 56) return ETH_MAINNET_SELECTOR;
        if (chainId == 11_155_111) return BSC_TESTNET_SELECTOR;
        if (chainId == 97) return SEPOLIA_SELECTOR;
        revert UnsupportedChain(chainId);
    }
}
