// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/ccip/libraries/RateLimiter.sol";

import {UpdateRateLimits} from "../script/07_UpdateRateLimits.s.sol";

/// @dev Test-only exposer for the script's `_validateBucket` so we can hit each preflight
///      branch without a full broadcast simulation.
contract UpdateRateLimitsHarness is UpdateRateLimits {
    function exposeValidateBucket(RateLimiter.Config calldata cfg, string calldata label) external pure {
        _validateBucket(cfg, label);
    }
}

/// @notice Verifies that `_validateBucket` agrees with CCIP `RateLimiter._validateTokenBucketConfig`
///         on every boundary. A mismatch lets an operator broadcast a config that the protocol
///         then rejects mid-tx — which is exactly the failure mode SECURITY.md M-4 was
///         designed to prevent. This is a Chainlink-compliance regression test.
contract Script07PreflightTest is Test {
    UpdateRateLimitsHarness internal h;

    function setUp() public {
        h = new UpdateRateLimitsHarness();
    }

    function _cfg(bool enabled, uint128 cap, uint128 rate) internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: enabled, capacity: cap, rate: rate});
    }

    // ─── Enabled case ──────────────────────────────────────────────────────────

    function test_AcceptsValidEnabledConfig() public view {
        h.exposeValidateBucket(_cfg(true, 100_000 ether, 10 ether), "OUTBOUND");
    }

    function test_RejectsEnabledZeroRate() public {
        vm.expectRevert("OUTBOUND_RATE must be > 0 when enabled");
        h.exposeValidateBucket(_cfg(true, 100_000 ether, 0), "OUTBOUND");
    }

    function test_RejectsEnabledRateEqualsCapacity() public {
        // CCIP's _validateTokenBucketConfig requires `rate < capacity` (strict).
        vm.expectRevert("OUTBOUND_RATE must be < OUTBOUND_CAPACITY (strict)");
        h.exposeValidateBucket(_cfg(true, 100 ether, 100 ether), "OUTBOUND");
    }

    function test_RejectsEnabledRateAboveCapacity() public {
        vm.expectRevert("OUTBOUND_RATE must be < OUTBOUND_CAPACITY (strict)");
        h.exposeValidateBucket(_cfg(true, 100 ether, 101 ether), "OUTBOUND");
    }

    function test_RejectsEnabledZeroCapacity() public {
        // capacity == 0 + rate > 0 fails rate < capacity. Same revert message.
        vm.expectRevert("OUTBOUND_RATE must be < OUTBOUND_CAPACITY (strict)");
        h.exposeValidateBucket(_cfg(true, 0, 1), "OUTBOUND");
    }

    // ─── Disabled case ─────────────────────────────────────────────────────────

    function test_AcceptsDisabledZeroConfig() public view {
        h.exposeValidateBucket(_cfg(false, 0, 0), "INBOUND");
    }

    function test_RejectsDisabledNonZeroCapacity() public {
        vm.expectRevert("INBOUND_CAPACITY must be 0 when disabled");
        h.exposeValidateBucket(_cfg(false, 1, 0), "INBOUND");
    }

    function test_RejectsDisabledNonZeroRate() public {
        vm.expectRevert("INBOUND_RATE must be 0 when disabled");
        h.exposeValidateBucket(_cfg(false, 0, 1), "INBOUND");
    }

    // ─── Cross-check: any preflight-accepted config is also CCIP-accepted ──────

    /// @dev If our preflight accepts a config, CCIP must also accept it. Fuzz over both
    ///      enabled and disabled configs to lock this property.
    function testFuzz_PreflightAgreesWithCcip(bool enabled, uint128 cap, uint128 rate) public {
        RateLimiter.Config memory cfg = _cfg(enabled, cap, rate);

        bool preflightAccepts = true;
        try h.exposeValidateBucket(cfg, "X") {}
        catch {
            preflightAccepts = false;
        }

        bool ccipAccepts = true;
        try this._callCcipValidate(cfg) {}
        catch {
            ccipAccepts = false;
        }

        // The key property: when our preflight accepts, CCIP must too. (CCIP-strict and
        // preflight-strict are now equivalent; this fuzz pins them together.)
        if (preflightAccepts) {
            assertTrue(ccipAccepts, "preflight accepted a config CCIP would reject");
        }
        if (ccipAccepts) {
            assertTrue(preflightAccepts, "preflight rejected a config CCIP would accept");
        }
    }

    function _callCcipValidate(RateLimiter.Config calldata cfg) external pure {
        // Internal Solidity reflection: we can't call `RateLimiter._validateTokenBucketConfig`
        // directly (internal). Re-implement the protocol's exact check here so the fuzz
        // compares the script's preflight against the protocol's published rule.
        if (cfg.isEnabled) {
            require(cfg.rate < cfg.capacity && cfg.rate != 0, "ccip-enabled invalid");
        } else {
            require(cfg.rate == 0 && cfg.capacity == 0, "ccip-disabled non-zero");
        }
    }
}
