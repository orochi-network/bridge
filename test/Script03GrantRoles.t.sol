// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {GrantRoles} from "../script/03_GrantRoles.s.sol";

/// @dev Exposes `GrantRoles`'s internal pool-type identity check.
contract GrantRolesHarness is GrantRoles {
    function exposeIsExpectedPoolType(string calldata typeStr) external pure returns (bool) {
        return _isExpectedPoolType(typeStr);
    }
}

/// @notice DEP-27: the pool-type identity guard must accept ANY BurnMintTokenPool version
///         (robust to CCIP patch bumps so a submodule bump doesn't block `make deploy-eth`),
///         while still rejecting a different pool type, a non-pool (empty typeAndVersion),
///         and a bare-name impostor. The check is defense-in-depth pool identity — version
///         pinning is the submodule's job, not this guard's.
contract Script03GrantRolesTest is Test {
    GrantRolesHarness internal h;

    function setUp() public {
        h = new GrantRolesHarness();
    }

    function test_AcceptsPinnedVersion() public view {
        assertTrue(h.exposeIsExpectedPoolType("BurnMintTokenPool 1.6.1"));
    }

    /// @notice The regression this fix closes: a CCIP patch bump must not revert a legitimate
    ///         pool and block the deploy.
    function test_AcceptsPatchBump() public view {
        assertTrue(h.exposeIsExpectedPoolType("BurnMintTokenPool 1.6.2"));
    }

    function test_AcceptsFutureMinorVersion() public view {
        assertTrue(h.exposeIsExpectedPoolType("BurnMintTokenPool 2.0.0"));
    }

    function test_RejectsLockReleasePool() public view {
        assertFalse(h.exposeIsExpectedPoolType("LockReleaseTokenPool 1.6.1"));
    }

    function test_RejectsEmptyString() public view {
        assertFalse(h.exposeIsExpectedPoolType(""));
    }

    /// @notice No trailing version ⇒ shorter than the "BurnMintTokenPool " prefix ⇒ rejected.
    function test_RejectsUnversionedBareName() public view {
        assertFalse(h.exposeIsExpectedPoolType("BurnMintTokenPool"));
    }

    /// @notice Shares the leading characters but breaks at the required space separator, so a
    ///         "BurnMintTokenPoolEvil ..." impostor is rejected.
    function test_RejectsImpostorWithoutSeparator() public view {
        assertFalse(h.exposeIsExpectedPoolType("BurnMintTokenPoolEvil 9.9.9"));
    }
}
