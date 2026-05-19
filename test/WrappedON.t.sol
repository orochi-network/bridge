// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IBurnMintERC20} from "@chainlink/contracts-ccip/shared/token/ERC20/IBurnMintERC20.sol";
import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/ccip/interfaces/IGetCCIPAdmin.sol";

import {WrappedON} from "../src/WrappedON.sol";

/// @dev Minimal mock of the canonical ON token (non-mintable ERC20).
contract MockON is ERC20 {
    constructor() ERC20("Orochi Network", "ON") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @dev 6-decimal ERC20 used to assert the constructor's decimals guard.
contract MockON6 is ERC20 {
    constructor() ERC20("Mock ON 6", "MON6") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract WrappedONTest is Test {
    WrappedON internal won;
    MockON internal on;

    address internal admin = makeAddr("admin");
    address internal pool = makeAddr("pool");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        on = new MockON();
        won = new WrappedON(IERC20(address(on)), admin);

        // Move all the mock supply to alice for clean accounting.
        on.transfer(alice, on.balanceOf(address(this)));

        // Wire the CCIP pool roles to the mock pool address.
        vm.startPrank(admin);
        won.grantRole(won.MINTER_ROLE(), pool);
        won.grantRole(won.BURNER_ROLE(), pool);
        vm.stopPrank();
    }

    // ─── Deposit / Withdraw ───────────────────────────────────────────────────

    function test_DepositEmitsWrapped() public {
        vm.startPrank(alice);
        on.approve(address(won), 50 ether);
        vm.expectEmit(true, false, false, true);
        emit WrappedON.Wrapped(alice, 50 ether);
        won.deposit(50 ether);
        vm.stopPrank();
    }

    function test_DepositZeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(WrappedON.ZeroAmount.selector);
        won.deposit(0);
    }

    function test_DepositMintsOneToOne() public {
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether);
        vm.stopPrank();

        assertEq(won.balanceOf(alice), 100 ether);
        assertEq(on.balanceOf(address(won)), 100 ether);
        assertEq(won.totalSupply(), 100 ether);
    }

    function test_WithdrawEmitsUnwrapped() public {
        vm.startPrank(alice);
        on.approve(address(won), 50 ether);
        won.deposit(50 ether);
        vm.expectEmit(true, false, false, true);
        emit WrappedON.Unwrapped(alice, 30 ether);
        won.withdraw(30 ether);
        vm.stopPrank();
    }

    function test_WithdrawBurnsAndReturnsON() public {
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether);

        uint256 aliceONBefore = on.balanceOf(alice);
        won.withdraw(40 ether);
        vm.stopPrank();

        assertEq(won.balanceOf(alice), 60 ether);
        assertEq(on.balanceOf(alice), aliceONBefore + 40 ether);
        assertEq(on.balanceOf(address(won)), 60 ether);
        assertEq(won.totalSupply(), 60 ether);
    }

    function test_WithdrawRevertsWhenReserveInsufficient() public {
        // CCIP-mint inflates wON supply without depositing native ON.
        vm.prank(pool);
        won.mint(alice, 50 ether);

        // Alice has 50 wON but the contract holds 0 native ON.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WrappedON.InsufficientReserve.selector, 50 ether, 0));
        won.withdraw(50 ether);
    }

    function test_WithdrawRevertsOnInsufficientWonBalance() public {
        // Reserve is non-zero (alice deposited), but bob holds zero wON.
        // The reserve check passes; _burn reverts with ERC20InsufficientBalance.
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether);
        vm.stopPrank();

        address bob = makeAddr("bob");
        vm.prank(bob);
        vm.expectRevert(); // OZ ERC20InsufficientBalance — bob has 0 wON
        won.withdraw(1 ether);
    }

    function test_WithdrawDrainsReserveToZeroThenReverts() public {
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether);
        won.withdraw(100 ether); // empties reserve
        assertEq(on.balanceOf(address(won)), 0);

        vm.expectRevert(abi.encodeWithSelector(WrappedON.InsufficientReserve.selector, 1, 0));
        won.withdraw(1);
        vm.stopPrank();
    }

    /// @notice `withdraw(0)` must revert (mirrors `deposit(0)`). Without this guard a zero
    ///         call would emit `Unwrapped(_, 0)` plus two zero-value ERC20 `Transfer`
    ///         events and otherwise no-op — polluting indexers and breaking symmetry with
    ///         the deposit path. Round-6 review (R-57).
    function test_WithdrawRevertsOnZero() public {
        vm.startPrank(alice);
        on.approve(address(won), 10 ether);
        won.deposit(10 ether);
        vm.expectRevert(WrappedON.ZeroAmount.selector);
        won.withdraw(0);
        vm.stopPrank();
    }

    function test_WithdrawRevertsOnPartialReserve() public {
        // Wrap 30 native ON → reserve = 30, wrap-backed supply = 30.
        vm.startPrank(alice);
        on.approve(address(won), 30 ether);
        won.deposit(30 ether);
        vm.stopPrank();

        // Pool mints 70 more wON (CCIP-backed; not reserve-backed).
        vm.prank(pool);
        won.mint(alice, 70 ether);

        // totalSupply = 100, reserve = 30. Withdrawing 31 must revert.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WrappedON.InsufficientReserve.selector, 31 ether, 30 ether));
        won.withdraw(31 ether);
    }

    function test_ReserveAccountingMixedSources() public {
        // wrap 100
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether);
        vm.stopPrank();

        // CCIP-mint 50
        vm.prank(pool);
        won.mint(bob, 50 ether);

        assertEq(won.totalSupply(), 150 ether, "totalSupply = wrap + ccip");
        assertEq(on.balanceOf(address(won)), 100 ether, "reserve only tracks wrap deposits");
    }

    // ─── Role gating ──────────────────────────────────────────────────────────

    function test_OnlyMinterCanMint() public {
        bytes32 minterRole = won.MINTER_ROLE();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, minterRole)
        );
        won.mint(alice, 1 ether);

        vm.prank(pool);
        won.mint(alice, 1 ether);
        assertEq(won.balanceOf(alice), 1 ether);
    }

    function test_OnlyBurnerCanBurn() public {
        bytes32 burnerRole = won.BURNER_ROLE();

        // Mint some wON to the pool so it can `burn(amount)` from its own balance.
        vm.prank(pool);
        won.mint(pool, 10 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, burnerRole)
        );
        won.burn(1 ether);

        vm.prank(pool);
        won.burn(10 ether);
        assertEq(won.balanceOf(pool), 0);
    }

    function test_BurnFromRevertsOnInsufficientAllowance() public {
        vm.prank(pool);
        won.mint(alice, 10 ether);

        vm.prank(alice);
        won.approve(pool, 3 ether);

        vm.prank(pool);
        vm.expectRevert(); // OZ ERC20InsufficientAllowance
        won.burnFrom(alice, 5 ether);
    }

    function test_BurnFromRequiresAllowance() public {
        vm.prank(pool);
        won.mint(alice, 10 ether);

        // Pool needs allowance from alice to burnFrom.
        vm.prank(alice);
        won.approve(pool, 4 ether);

        vm.prank(pool);
        won.burnFrom(alice, 4 ether);

        assertEq(won.balanceOf(alice), 6 ether);
        assertEq(won.allowance(alice, pool), 0);
    }

    function test_BurnAddressOverloadRevertsForNonBurner() public {
        vm.prank(pool);
        won.mint(alice, 5 ether);

        // Cache the role constant before vm.prank; calling won.BURNER_ROLE() after vm.prank would
        // consume the prank on the view call and leave msg.sender as the test contract.
        bytes32 burnerRole = won.BURNER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, burnerRole)
        );
        won.burn(alice, 5 ether);
    }

    function test_BurnAddressOverloadIgnoresAllowance() public {
        // The IBurnMintERC20 `burn(address,uint256)` overload bypasses allowance — it's the
        // privileged path used by some pool variants. BURNER_ROLE is the only gate.
        vm.prank(pool);
        won.mint(alice, 10 ether);

        vm.prank(pool);
        won.burn(alice, 7 ether);
        assertEq(won.balanceOf(alice), 3 ether);
    }

    function test_RoleRevoke() public {
        bytes32 minterRole = won.MINTER_ROLE();

        vm.prank(admin);
        won.revokeRole(minterRole, pool);

        vm.prank(pool);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pool, minterRole)
        );
        won.mint(alice, 1 ether);
    }

    // ─── CCIP admin ───────────────────────────────────────────────────────────

    function test_GetCCIPAdmin() public view {
        assertEq(won.getCCIPAdmin(), admin);
    }

    function test_SetCCIPAdminTwoStep() public {
        address newAdmin = makeAddr("newAdmin");

        // Step 1 — current admin proposes; getCCIPAdmin unchanged until accept.
        vm.prank(admin);
        won.setCCIPAdmin(newAdmin);
        assertEq(won.pendingCCIPAdmin(), newAdmin);
        assertEq(won.getCCIPAdmin(), admin, "admin must not change until accept");

        // Step 2 — proposed acceptor takes the role.
        vm.prank(newAdmin);
        won.acceptCCIPAdmin();
        assertEq(won.getCCIPAdmin(), newAdmin);
        assertEq(won.pendingCCIPAdmin(), address(0));
    }

    function test_SetCCIPAdminEmitsProposedThenTransferred() public {
        address newAdmin = makeAddr("newAdmin");

        vm.expectEmit(true, true, false, false);
        emit WrappedON.CCIPAdminTransferProposed(admin, newAdmin);
        vm.prank(admin);
        won.setCCIPAdmin(newAdmin);

        vm.expectEmit(true, true, false, false);
        emit WrappedON.CCIPAdminTransferred(admin, newAdmin);
        vm.prank(newAdmin);
        won.acceptCCIPAdmin();
    }

    function test_SetCCIPAdminRevertsForNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(WrappedON.OnlyCCIPAdmin.selector);
        won.setCCIPAdmin(alice);
    }

    function test_SetCCIPAdminRevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(WrappedON.ZeroAddress.selector);
        won.setCCIPAdmin(address(0));
    }

    /// @notice Self-proposal would emit `Proposed(admin, admin)` and silently clobber any
    ///         in-flight pending proposal, forcing an extra recovery transaction. Round-6
    ///         review (R-56). The guard fires before the pending slot is written.
    function test_SetCCIPAdminRevertsOnSelfProposal() public {
        vm.prank(admin);
        vm.expectRevert(WrappedON.InvalidCCIPAdmin.selector);
        won.setCCIPAdmin(admin);
    }

    /// @notice Proposing the contract itself would write an unreachable address into
    ///         `s_pendingCcipAdmin` (no external caller can be `address(this)`),
    ///         soft-locking the role until the current admin overwrites. Round-6 review
    ///         (R-56).
    function test_SetCCIPAdminRevertsOnContractSelf() public {
        vm.prank(admin);
        vm.expectRevert(WrappedON.InvalidCCIPAdmin.selector);
        won.setCCIPAdmin(address(won));
    }

    /// @notice Pending-proposal idempotency: re-proposing the same pending admin from the
    ///         current admin is allowed (different from self-proposal); it overwrites the
    ///         pending slot with the same value — harmless and consistent with the existing
    ///         "current admin may overwrite pending" semantics.
    function test_SetCCIPAdminMayReProposePending() public {
        address newAdmin = makeAddr("newAdmin");
        vm.startPrank(admin);
        won.setCCIPAdmin(newAdmin);
        won.setCCIPAdmin(newAdmin); // must not revert
        vm.stopPrank();
        assertEq(won.pendingCCIPAdmin(), newAdmin);
    }

    function test_AcceptCCIPAdminRevertsForNonPending() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        won.setCCIPAdmin(newAdmin);

        vm.prank(alice);
        vm.expectRevert(WrappedON.OnlyPendingCCIPAdmin.selector);
        won.acceptCCIPAdmin();
    }

    // ─── CCIP mint cap ────────────────────────────────────────────────────────

    function test_MintRevertsAtCCIPMintCap() public {
        uint256 cap = won.MAX_CCIP_MINTED();
        vm.prank(pool);
        won.mint(alice, cap);
        assertEq(won.ccipMintedSupply(), cap);
        assertEq(won.totalSupply(), cap);

        vm.prank(pool);
        vm.expectRevert(abi.encodeWithSelector(WrappedON.CCIPMintCapExceeded.selector, cap, cap + 1));
        won.mint(alice, 1);
    }

    /// @dev Per PR #19 review (bao-ninh #1), `deposit()` is intentionally NOT subject to the
    ///      CCIP cap: a fully utilised wrap path must not starve inbound bridge messages.
    function test_DepositSucceedsWhenCCIPCapHit() public {
        uint256 cap = won.MAX_CCIP_MINTED();
        vm.prank(pool);
        won.mint(bob, cap);
        assertEq(won.ccipMintedSupply(), cap);

        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether); // must NOT revert
        vm.stopPrank();

        assertEq(won.balanceOf(alice), 100 ether);
        assertEq(won.totalSupply(), cap + 100 ether);
        assertEq(won.ccipMintedSupply(), cap, "deposit must not move ccipMintedSupply");
    }

    function test_BurnDecrementsCCIPMintedSupply() public {
        vm.prank(pool);
        won.mint(pool, 80 ether);
        assertEq(won.ccipMintedSupply(), 80 ether);

        vm.prank(pool);
        won.burn(30 ether);
        assertEq(won.ccipMintedSupply(), 50 ether, "burn frees cap headroom");

        // Cap should be re-mintable now.
        vm.prank(pool);
        won.mint(alice, 30 ether);
        assertEq(won.ccipMintedSupply(), 80 ether);
    }

    function test_BurnSaturatesCCIPMintedAtZero() public {
        // Wrap 100 (no CCIP mint yet).
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether);
        won.transfer(pool, 100 ether);
        vm.stopPrank();
        assertEq(won.ccipMintedSupply(), 0);

        // Pool burns its own 100 wON (via outbound CCIP send of deposit-backed wON).
        // ccipMintedSupply must NOT underflow — it stays at 0.
        vm.prank(pool);
        won.burn(100 ether);
        assertEq(won.ccipMintedSupply(), 0);
    }

    function test_BurnAddressOverloadDecrementsCCIPMinted() public {
        vm.prank(pool);
        won.mint(alice, 50 ether);
        vm.prank(pool);
        won.burn(alice, 20 ether);
        assertEq(won.ccipMintedSupply(), 30 ether);
    }

    function test_BurnFromDecrementsCCIPMinted() public {
        vm.prank(pool);
        won.mint(alice, 50 ether);

        vm.prank(alice);
        won.approve(pool, 25 ether);

        vm.prank(pool);
        won.burnFrom(alice, 25 ether);
        assertEq(won.ccipMintedSupply(), 25 ether);
    }

    // ─── Constructor guards ───────────────────────────────────────────────────

    function test_ConstructorEmitsCCIPAdminTransferred() public {
        address newAdmin = makeAddr("newAdmin");
        vm.expectEmit(true, true, false, false);
        emit WrappedON.CCIPAdminTransferred(address(0), newAdmin);
        new WrappedON(IERC20(address(on)), newAdmin);
    }

    function test_ConstructorRevertsOnZeroToken() public {
        vm.expectRevert(WrappedON.ZeroAddress.selector);
        new WrappedON(IERC20(address(0)), admin);
    }

    function test_ConstructorRevertsOnZeroAdmin() public {
        vm.expectRevert(WrappedON.ZeroAddress.selector);
        new WrappedON(IERC20(address(on)), address(0));
    }

    /// @dev Per PR #19 review (brng1151 #1, bao-ninh #5): constructor must reject the
    ///      `address(this)` self-reserve case (would make the reserve invariant circular).
    function test_ConstructorRevertsOnSelfReserve() public {
        // Compute the next CREATE address — that's where the wON about to be deployed
        // will live. Pass it as the ON token to trigger the SelfReserve guard.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(WrappedON.SelfReserve.selector);
        new WrappedON(IERC20(predicted), admin);
    }

    /// @dev Per PR #19 review (bao-ninh #5): constructor must reject ON tokens with
    ///      non-18 decimals (1:1 wrap accounting only holds at matching decimals).
    function test_ConstructorRevertsOnDecimalsMismatch() public {
        MockON6 on6 = new MockON6();
        vm.expectRevert(abi.encodeWithSelector(WrappedON.DecimalsMismatch.selector, 18, 6));
        new WrappedON(IERC20(address(on6)), admin);
    }

    // ─── Metadata ─────────────────────────────────────────────────────────────

    function test_SupportsInterfacePositiveAndNegative() public view {
        assertTrue(won.supportsInterface(type(IERC20).interfaceId));
        assertTrue(won.supportsInterface(type(IBurnMintERC20).interfaceId));
        assertTrue(won.supportsInterface(type(IGetCCIPAdmin).interfaceId));
        assertTrue(won.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(won.supportsInterface(type(IERC165).interfaceId));
        assertFalse(won.supportsInterface(0xdeadbeef));
    }

    function test_Decimals18() public view {
        assertEq(won.decimals(), 18);
    }

    function test_NameAndSymbol() public view {
        assertEq(won.name(), "Wrapped Orochi Network");
        assertEq(won.symbol(), "wON");
    }

    // ─── Fuzz tests ───────────────────────────────────────────────────────────

    /// @notice Deposit-then-withdraw must round-trip exactly. Catches any 1:1 accounting
    ///         drift in the deposit/withdraw pair (e.g. if a fee or rounding crept into
    ///         the received-amount accounting).
    function testFuzz_DepositWithdrawRoundtrip(uint128 amount) public {
        vm.assume(amount > 0);
        // Bound to MockON supply so the test stays meaningful.
        amount = uint128(bound(uint256(amount), 1, on.balanceOf(alice)));

        uint256 aliceONBefore = on.balanceOf(alice);
        uint256 reserveBefore = on.balanceOf(address(won));

        vm.startPrank(alice);
        on.approve(address(won), amount);
        won.deposit(amount);
        assertEq(won.balanceOf(alice), amount, "deposit mints 1:1");
        assertEq(on.balanceOf(address(won)) - reserveBefore, amount, "reserve grows by amount");

        won.withdraw(amount);
        vm.stopPrank();

        // After roundtrip: every balance is exactly where it started.
        assertEq(won.balanceOf(alice), 0, "wON burned");
        assertEq(on.balanceOf(address(won)), reserveBefore, "reserve back to baseline");
        assertEq(on.balanceOf(alice), aliceONBefore, "alice ON balance restored");
        assertEq(won.totalSupply(), 0);
    }

    /// @notice CCIP mint up to the cap succeeds; one wei over reverts. Boundary fuzz around
    ///         `MAX_CCIP_MINTED` to catch off-by-one regressions.
    function testFuzz_CcipMintCapBoundary(uint128 underBy) public {
        uint256 cap = won.MAX_CCIP_MINTED();
        underBy = uint128(bound(uint256(underBy), 1, 1_000_000 ether));
        uint256 firstMint = cap - underBy;

        vm.prank(pool);
        won.mint(alice, firstMint);
        assertEq(won.ccipMintedSupply(), firstMint);

        // Filling exactly to the cap must succeed.
        vm.prank(pool);
        won.mint(alice, underBy);
        assertEq(won.ccipMintedSupply(), cap);

        // One wei over must revert.
        vm.prank(pool);
        vm.expectRevert(abi.encodeWithSelector(WrappedON.CCIPMintCapExceeded.selector, cap, cap + 1));
        won.mint(alice, 1);
    }

    /// @notice CCIP mint→burn→mint roundtrip frees cap headroom. Saturating decrement
    ///         must allow re-using the cap after each ETH→BSC bridge.
    function testFuzz_CcipMintBurnRoundtripReusesCap(uint128 amount) public {
        uint256 cap = won.MAX_CCIP_MINTED();
        amount = uint128(bound(uint256(amount), 1, cap));

        vm.prank(pool);
        won.mint(pool, amount);
        assertEq(won.ccipMintedSupply(), amount);

        vm.prank(pool);
        won.burn(amount);
        assertEq(won.ccipMintedSupply(), 0, "burn frees cap");

        // Cap is now fully re-mintable.
        vm.prank(pool);
        won.mint(alice, cap);
        assertEq(won.ccipMintedSupply(), cap);
    }
}
