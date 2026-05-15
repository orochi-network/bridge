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

/// @dev Thin external wrapper around `RateLimiter._validateTokenBucketConfig` (an `internal
///      pure` function in the vendored CCIP library) so the fuzz cross-check can actually
///      execute the protocol's check rather than a hand-mirror of it. `mustBeDisabled=false`
///      matches what `TokenPool.setChainRateLimiterConfig` passes through to the validator
///      for a routine rate-limit update — see `lib/ccip/.../TokenPool.sol`
///      `setChainRateLimiterConfig` → `_setRateLimitConfig` → `_validateTokenBucketConfig(_, false)`.
///      Round-3 review [9]: lifts the fuzz from a hand-mirror to a true behavioural
///      equivalence test against the on-chain protocol code.
contract CcipRateLimiterValidator {
    function validate(RateLimiter.Config calldata cfg) external pure {
        RateLimiter._validateTokenBucketConfig(cfg, false);
    }
}

/// @notice Verifies that `_validateBucket` agrees with CCIP `RateLimiter._validateTokenBucketConfig`
///         on every boundary. A mismatch lets an operator broadcast a config that the protocol
///         then rejects mid-tx — which is exactly the failure mode SECURITY.md M-4 was
///         designed to prevent. This is a Chainlink-compliance regression test.
contract Script07PreflightTest is Test {
    UpdateRateLimitsHarness internal h;
    CcipRateLimiterValidator internal ccipValidator;

    function setUp() public {
        h = new UpdateRateLimitsHarness();
        ccipValidator = new CcipRateLimiterValidator();
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

    // ─── Cross-check: preflight ↔ actual CCIP `_validateTokenBucketConfig` ────

    /// @dev Fuzz both directions of equivalence against the REAL `RateLimiter` library
    ///      (via `CcipRateLimiterValidator` — an external wrapper around the internal
    ///      protocol check). If the script preflight diverges from the protocol — in
    ///      either direction — this fails. Round-3 review [9]: previously the fuzz
    ///      compared the script against a hand-rolled re-implementation of the rule,
    ///      so a shared misread of the protocol would have been invisible.
    function testFuzz_PreflightAgreesWithCcip(bool enabled, uint128 cap, uint128 rate) public {
        RateLimiter.Config memory cfg = _cfg(enabled, cap, rate);

        bool preflightAccepts = true;
        try h.exposeValidateBucket(cfg, "X") {}
        catch {
            preflightAccepts = false;
        }

        bool ccipAccepts = true;
        try ccipValidator.validate(cfg) {}
        catch {
            ccipAccepts = false;
        }

        // Equivalence in both directions: every config the preflight accepts must also
        // pass the protocol's check, AND vice-versa. The disabled-direction half
        // (capacity=0 + rate=0) is the case M-4's original non-strict rule got wrong.
        assertEq(preflightAccepts, ccipAccepts, "preflight diverges from RateLimiter._validateTokenBucketConfig");
    }

    /// @notice Concrete spot-check that the CCIP validator wrapper actually reaches the
    ///         protocol code. If `RateLimiter._validateTokenBucketConfig` ever shifts
    ///         its rule (e.g. a CCIP version bump that allows `rate == capacity`), this
    ///         test forces the change to surface as a fuzz-test divergence on the
    ///         relevant input rather than passing silently.
    function test_CcipValidatorRejectsEnabledRateEqualsCapacity() public {
        vm.expectRevert(); // RateLimiter.InvalidRateLimitRate
        ccipValidator.validate(_cfg(true, 100 ether, 100 ether));
    }

    function test_CcipValidatorAcceptsValidEnabledConfig() public view {
        ccipValidator.validate(_cfg(true, 100 ether, 10 ether));
    }

    function test_CcipValidatorAcceptsDisabledZeroConfig() public view {
        ccipValidator.validate(_cfg(false, 0, 0));
    }
}
