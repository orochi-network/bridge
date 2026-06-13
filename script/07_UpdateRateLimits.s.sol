// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";

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
///   OUTBOUND_ENABLED   bool — accepts ONLY the literal strings "true" or "false".
///                      Default: true. `1`, `yes`, `on`, etc. cause Foundry to revert
///                      mid-broadcast — pass an exact string.
///   INBOUND_ENABLED    bool — same constraint as OUTBOUND_ENABLED. Default: true.
contract UpdateRateLimits is Script, Helper {
    error RemoteChainNotWired(uint64 remoteSelector);

    function run() external {
        NetworkConfig memory local = getConfig(block.chainid);
        uint64 remoteSelector = _remoteSelector(block.chainid);

        address localPool = Deployments.tryReadAddress(block.chainid, "pool");
        _requireSet(localPool, "localPool (run script 02 first)");

        // DEP-10: refuse to broadcast against an unwired remote selector. Without this
        // preflight, `setChainRateLimiterConfig` reverts deep inside the pool with the
        // generic "non-existent chain" path — the operator pays gas and gets no actionable
        // diagnostic. Mirror script 05 / script 08's `isSupportedChain` posture.
        if (!TokenPool(localPool).isSupportedChain(remoteSelector)) {
            revert RemoteChainNotWired(remoteSelector);
        }

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

        // Preflight: validate the bucket config off-chain so any mistake fails before a
        // Gnosis Safe batch rather than mid-broadcast. This check is intentionally STRICTER
        // than CCIP 1.6.1's `RateLimiter._validateTokenBucketConfig`:
        //
        //   isEnabled=true  : rate > 0 AND rate < capacity (strict)
        //   isEnabled=false : capacity == 0 AND rate == 0
        //
        // 1.6.1 reverts ONLY on `rate > capacity` — it accepts `rate == capacity` and
        // `rate == 0` — but we reject those early for a clearer operator UX (an enabled
        // `rate == 0` bucket never refills; `rate == capacity` is almost always a typo). The
        // guarantee is one-directional: anything this preflight accepts, the protocol also
        // accepts, so no config that passes here can revert mid-broadcast. The earlier preflight
        // (`capacity > 0` always, `rate <= capacity` non-strict, no `rate > 0` check, no
        // disabled-case handling) both let bad configs through and blocked the valid
        // disabled-state (capacity=0, rate=0). See test/Script07Preflight.t.sol.
        _validateBucket(outbound, "OUTBOUND");
        _validateBucket(inbound, "INBOUND");

        vm.startBroadcast();
        TokenPool(localPool).setChainRateLimiterConfig(remoteSelector, outbound, inbound);
        vm.stopBroadcast();

        console.log("Pool %s (chain %d) -> remote selector %d", localPool, local.chainSelector, remoteSelector);
        console.log("  outbound: enabled=%s cap=%d rate=%d", outbound.isEnabled, outbound.capacity, outbound.rate);
        console.log("  inbound:  enabled=%s cap=%d rate=%d", inbound.isEnabled, inbound.capacity, inbound.rate);
    }

    function _validateBucket(RateLimiter.Config memory cfg, string memory label) internal pure {
        if (cfg.isEnabled) {
            require(cfg.rate > 0, string.concat(label, "_RATE must be > 0 when enabled"));
            require(cfg.rate < cfg.capacity, string.concat(label, "_RATE must be < ", label, "_CAPACITY (strict)"));
        } else {
            require(cfg.capacity == 0, string.concat(label, "_CAPACITY must be 0 when disabled"));
            require(cfg.rate == 0, string.concat(label, "_RATE must be 0 when disabled"));
        }
    }
}
