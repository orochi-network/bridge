// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/ccip/libraries/RateLimiter.sol";

import {PostDeployVerify} from "../script/08_PostDeployVerify.s.sol";
import {WrappedON} from "../src/WrappedON.sol";

contract _MockON18 is ERC20 {
    constructor() ERC20("Orochi Network", "ON") {}
}

/// @dev Test-only exposer for script 08's internal helpers. Each `internal` helper is
///      proxied externally so the test can exercise it without spinning up a full pool +
///      registry fixture.
contract PostDeployVerifyHarness is PostDeployVerify {
    function exposeAssert(string calldata direction, RateLimiter.TokenBucket calldata bucket) external pure {
        _assertEnabledAndConfigured(direction, bucket);
    }

    /// @notice DEP-8 harness — drives the deployer-renounce assertion with an explicit
    ///         `deployer` argument (the production-script path reads `DEPLOYER` env).
    function exposeCheckDeployerRenounced(WrappedON won, address multisig, address deployer) external view {
        _checkDeployerRenounced(won, multisig, deployer);
    }

    function exposeAssertConfiguredOrWarn(
        string calldata direction,
        RateLimiter.TokenBucket calldata bucket,
        bool strict
    ) external pure {
        _assertConfiguredOrWarn(direction, bucket, strict);
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

    /// @notice CCIP-10: when `STRICT_RATE_LIMITS=false`, a disabled bucket must NOT revert.
    ///         An enabled-but-misconfigured bucket must STILL revert — the silently-bricked
    ///         state is never a deliberate launch choice.
    function test_NonStrictPassesOnDisabledBucket() public view {
        h.exposeAssertConfiguredOrWarn("outbound", _bucket(false, 0, 0), false);
    }

    function test_NonStrictStillRejectsZeroRate() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PostDeployVerify.RateLimitMisconfigured.selector, "outbound", uint128(100 ether), uint128(0)
            )
        );
        h.exposeAssertConfiguredOrWarn("outbound", _bucket(true, 100 ether, 0), false);
    }

    // ─── DEP-8: deployer-renounce check ─────────────────────────────────────────

    /// @notice DEP-8: a non-renounced deployer (still holding DEFAULT_ADMIN_ROLE on wON)
    ///         must surface as `RoleNotRenounced(role, deployer)` — NOT silently pass. The
    ///         previous form used `msg.sender`, which in view-only `forge script` mode is
    ///         Foundry's default sender and never holds the role, so the branch was
    ///         vacuously satisfied.
    function test_CheckDeployerRenounced_RevertsWhenDeployerStillHoldsRole() public {
        _MockON18 on = new _MockON18();
        address deployer = makeAddr("deployer");
        address multisig = makeAddr("multisig");

        vm.startPrank(deployer);
        WrappedON won = new WrappedON(IERC20(address(on)), deployer);
        // Simulate partial handoff: multisig holds the admin role, but deployer hasn't
        // renounced yet. CCIP admin already transferred so the revert is on
        // RoleNotRenounced rather than the ccipAdmin RoleMissing branch.
        won.grantRole(won.DEFAULT_ADMIN_ROLE(), multisig);
        won.setCCIPAdmin(multisig);
        vm.stopPrank();
        vm.prank(multisig);
        won.acceptCCIPAdmin();

        vm.expectRevert(
            abi.encodeWithSelector(PostDeployVerify.RoleNotRenounced.selector, "DEFAULT_ADMIN_ROLE", deployer)
        );
        h.exposeCheckDeployerRenounced(won, multisig, deployer);
    }

    /// @notice DEP-8 happy path: the fully-handed-off state (multisig holds admin,
    ///         ccipAdmin == multisig, deployer has renounced) must pass without revert.
    function test_CheckDeployerRenounced_PassesAfterRenounce() public {
        _MockON18 on = new _MockON18();
        address deployer = makeAddr("deployer");
        address multisig = makeAddr("multisig");

        vm.startPrank(deployer);
        WrappedON won = new WrappedON(IERC20(address(on)), deployer);
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
        won.grantRole(adminRole, multisig);
        won.setCCIPAdmin(multisig);
        vm.stopPrank();
        vm.prank(multisig);
        won.acceptCCIPAdmin();
        // OZ 5.x: `renounceRole(role, callerConfirmation)` requires callerConfirmation == _msgSender().
        // Cache the role selector via local variable so the prank applies to the renounceRole
        // call itself rather than being consumed by a `won.DEFAULT_ADMIN_ROLE()` view fetch.
        vm.prank(deployer);
        won.renounceRole(adminRole, deployer);
        assertFalse(won.hasRole(adminRole, deployer));

        h.exposeCheckDeployerRenounced(won, multisig, deployer);
    }
}
