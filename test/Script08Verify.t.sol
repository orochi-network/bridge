// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/ccip/libraries/RateLimiter.sol";

import {PostDeployVerify} from "../script/08_PostDeployVerify.s.sol";

/// @dev Test-only exposer for script 08's internal `_assertEnabledAndConfigured`. The
///      helper is `internal pure`; expose it externally so each branch can be exercised
///      without spinning up a full pool + registry fixture.
contract PostDeployVerifyHarness is PostDeployVerify {
    function exposeAssert(string calldata direction, RateLimiter.TokenBucket calldata bucket) external pure {
        _assertEnabledAndConfigured(direction, bucket);
    }
}

/// @notice Locks `_assertEnabledAndConfigured` against the four cases that matter for
///         post-deploy verification (round-4 review [3]): an enabled + correctly-sized
///         bucket passes; a disabled bucket reverts `RateLimitDisabled`; an enabled
///         bucket with `rate == 0` OR `capacity == 0` reverts `RateLimitMisconfigured`
///         (the silently-bricked configuration the round-3 fix was built to detect).
///
///         The assertion runs inside `_checkRateLimits`, which `make verify-eth/bsc`
///         invokes after every deploy — a regression here would only show up when the
///         first user transaction failed on-chain.
contract Script08VerifyTest is Test {
    PostDeployVerifyHarness internal h;

    function setUp() public {
        h = new PostDeployVerifyHarness();
    }

    function _bucket(bool enabled, uint128 cap, uint128 rate) internal view returns (RateLimiter.TokenBucket memory) {
        return RateLimiter.TokenBucket({
            tokens: 0, lastUpdated: uint32(block.timestamp), isEnabled: enabled, capacity: cap, rate: rate
        });
    }

    function test_PassesOnEnabledAndConfigured() public view {
        h.exposeAssert("outbound", _bucket(true, 100_000 ether, 10 ether));
    }

    function test_RevertsWhenDisabled() public {
        vm.expectRevert(abi.encodeWithSelector(PostDeployVerify.RateLimitDisabled.selector, "outbound"));
        h.exposeAssert("outbound", _bucket(false, 0, 0));
    }

    function test_RevertsWhenEnabledAndZeroRate() public {
        // The silently-bricked case: bucket is enabled but rate=0 so it never refills.
        // CCIP's own _validateTokenBucketConfig would reject this at write time, but a
        // stuck state could leave it on-chain — this is the case R-33 was built to
        // surface in `make verify-*` before the first user transaction.
        vm.expectRevert(
            abi.encodeWithSelector(
                PostDeployVerify.RateLimitMisconfigured.selector, "outbound", uint128(100 ether), uint128(0)
            )
        );
        h.exposeAssert("outbound", _bucket(true, 100 ether, 0));
    }

    function test_RevertsWhenEnabledAndZeroCapacity() public {
        vm.expectRevert(
            abi.encodeWithSelector(PostDeployVerify.RateLimitMisconfigured.selector, "inbound", uint128(0), uint128(1))
        );
        h.exposeAssert("inbound", _bucket(true, 0, 1));
    }
}
