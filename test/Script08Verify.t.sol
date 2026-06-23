// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";

import {PostDeployVerify} from "../script/08_PostDeployVerify.s.sol";
import {WrappedON} from "../src/WrappedON.sol";
import {DeployWON} from "./helpers/DeployWON.sol";

/// @dev TEST-20: stand-in pool that lets each test set the rebalancer and the
///      `getRemotePool` / `getRemoteToken` payloads independently so the typed-revert
///      branches in `_checkBscRebalancer` / `_checkRemoteLink` are exercisable without a
///      full pool fixture.
contract MockBadPool {
    address public rebalancer;
    bytes public remotePoolBytes;
    bytes public remoteTokenBytes;

    function setRebalancer(address r) external {
        rebalancer = r;
    }

    function setRemotePoolBytes(bytes memory b) external {
        remotePoolBytes = b;
    }

    function setRemoteTokenBytes(bytes memory b) external {
        remoteTokenBytes = b;
    }

    function getRebalancer() external view returns (address) {
        return rebalancer;
    }

    function getRemotePools(uint64) external view returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = remotePoolBytes;
    }

    function getRemoteToken(uint64) external view returns (bytes memory) {
        return remoteTokenBytes;
    }

    /// @dev `_checkRemoteLink` calls `isSupportedChain` first; treat the configured remote
    ///      as supported so the tests reach the abi-decode length guards.
    function isSupportedChain(uint64) external pure returns (bool) {
        return true;
    }
}

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

    /// @notice TEST-20: expose the BSC-rebalancer and remote-link checks so each
    ///         typed-revert branch can be exercised against a `MockBadPool`.
    function exposeCheckBscRebalancer(address pool) external view {
        _checkBscRebalancer(pool);
    }

    function exposeCheckRemoteLink(
        address pool,
        uint64 remoteSelector,
        address expectedRemotePool,
        address expectedRemoteToken
    ) external view {
        _checkRemoteLink(pool, remoteSelector, expectedRemotePool, expectedRemoteToken);
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

        WrappedON won = DeployWON.deploy(IERC20(address(on)), deployer, deployer);
        vm.startPrank(deployer);
        // Simulate partial handoff: multisig holds the admin role + PAUSER_ROLE, but
        // deployer hasn't renounced yet. CCIP admin already transferred so the revert is
        // on RoleNotRenounced rather than the ccipAdmin RoleMissing branch.
        won.grantRole(won.DEFAULT_ADMIN_ROLE(), multisig);
        won.grantRole(won.PAUSER_ROLE(), multisig);
        won.setCCIPAdmin(multisig);
        vm.stopPrank();
        vm.prank(multisig);
        won.acceptCCIPAdmin();

        vm.expectRevert(
            abi.encodeWithSelector(PostDeployVerify.RoleNotRenounced.selector, "DEFAULT_ADMIN_ROLE", deployer)
        );
        h.exposeCheckDeployerRenounced(won, multisig, deployer);
    }

    // ─── TEST-20: BSC rebalancer + remote-link typed-revert paths ─────────────

    /// @notice TEST-20: an `UnexpectedRebalancer` revert fires when the BSC pool's slot is
    ///         non-zero. Pre-second-pass the only coverage came indirectly via fork tests.
    function test_CheckBscRebalancer_RevertsOnUnexpectedRebalancer() public {
        MockBadPool bad = new MockBadPool();
        address attacker = makeAddr("attacker");
        bad.setRebalancer(attacker);

        vm.expectRevert(abi.encodeWithSelector(PostDeployVerify.UnexpectedRebalancer.selector, address(bad), attacker));
        h.exposeCheckBscRebalancer(address(bad));
    }

    /// @notice TEST-20: a `BscRebalancerReadFailed` revert surfaces when the pool returns
    ///         non-32-byte data (or doesn't implement the selector at all). Uses an EOA
    ///         (no code) as the "pool" — the staticcall returns `ok=true,data.length=0`.
    ///         DEP-19: previously a `require` string; now a typed error.
    function test_CheckBscRebalancer_RevertsOnReadFailure() public {
        address noCode = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(PostDeployVerify.BscRebalancerReadFailed.selector, noCode));
        h.exposeCheckBscRebalancer(noCode);
    }

    /// @notice TEST-20: malformed `getRemotePool` payload surfaces as the typed
    ///         `MalformedRemoteEncoding`, not a low-level abi-decode panic. DEP-9.
    function test_CheckRemoteLink_RevertsOnMalformedRemotePool() public {
        MockBadPool bad = new MockBadPool();
        // 31 bytes of payload — one short of the canonical `abi.encode(address)` 32.
        bytes memory malformed = new bytes(31);
        bad.setRemotePoolBytes(malformed);
        bad.setRemoteTokenBytes(abi.encode(address(0xBEEF)));

        vm.expectRevert(
            abi.encodeWithSelector(PostDeployVerify.MalformedRemoteEncoding.selector, uint64(123), "remotePool", 31)
        );
        h.exposeCheckRemoteLink(address(bad), 123, address(0xCAFE), address(0xBEEF));
    }

    /// @notice TEST-20: malformed `getRemoteToken` payload surfaces the same way.
    function test_CheckRemoteLink_RevertsOnMalformedRemoteToken() public {
        MockBadPool bad = new MockBadPool();
        bad.setRemotePoolBytes(abi.encode(address(0xCAFE)));
        bytes memory malformed = new bytes(33);
        bad.setRemoteTokenBytes(malformed);

        vm.expectRevert(
            abi.encodeWithSelector(PostDeployVerify.MalformedRemoteEncoding.selector, uint64(456), "remoteToken", 33)
        );
        h.exposeCheckRemoteLink(address(bad), 456, address(0xCAFE), address(0xBEEF));
    }

    /// @notice DEP-8 happy path: the fully-handed-off state (multisig holds DEFAULT_ADMIN,
    ///         ccipAdmin == multisig, deployer has renounced DEFAULT_ADMIN_ROLE)
    ///         must pass without revert.
    function test_CheckDeployerRenounced_PassesAfterRenounce() public {
        _MockON18 on = new _MockON18();
        address deployer = makeAddr("deployer");
        address multisig = makeAddr("multisig");

        WrappedON won = DeployWON.deploy(IERC20(address(on)), deployer, deployer);
        vm.startPrank(deployer);
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
        won.grantRole(adminRole, multisig);
        won.grantRole(won.PAUSER_ROLE(), multisig);
        won.setCCIPAdmin(multisig);
        // OZ 5.x: `renounceRole(role, callerConfirmation)` requires callerConfirmation == _msgSender();
        // inside this `startPrank(deployer)` block _msgSender() is the deployer.
        won.renounceRole(adminRole, deployer);
        vm.stopPrank();
        vm.prank(multisig);
        won.acceptCCIPAdmin();
        assertFalse(won.hasRole(adminRole, deployer));

        h.exposeCheckDeployerRenounced(won, multisig, deployer);
    }
}
