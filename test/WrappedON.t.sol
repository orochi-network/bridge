// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/interfaces/IGetCCIPAdmin.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {DeployWON} from "./helpers/DeployWON.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal mock of the canonical ON token (non-mintable ERC20).
contract MockON is ERC20 {
    constructor() ERC20("Orochi Network", "ON") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @dev Bare contract used as a CCIP receiver in the #48 test — its only purpose is to have
///      non-empty `code` so the mint target is unambiguously a contract, not an EOA.
contract ContractReceiver {}

/// @dev Reentrancy probe — overrides `transferFrom` to call back into `WrappedON.deposit`.
///      A real ON-like ERC20 wouldn't do this, but if a future deployment reuses WrappedON
///      against a hook-bearing token the `nonReentrant` guard must hold. SECURITY: TEST-8.
/// @dev TEST-16: also seeds itself with a small balance so the inner reentry's
///      `safeTransferFrom(rOn, rWon, 1)` can succeed on token-side accounting — that way
///      the inner call's revert is provably from `nonReentrant`, not from the mock running
///      out of balance. The `require` then asserts the specific
///      `ReentrancyGuardReentrantCall` selector, so a removed `nonReentrant` modifier no
///      longer trivially passes via `ERC20InsufficientBalance`.
contract ReentrantMockON is ERC20 {
    address public target;
    bool internal reentered;

    constructor() ERC20("Reentrant Mock ON", "rON") {
        _mint(msg.sender, 1_000_000 ether);
        // TEST-16: pre-fund the mock so the inner reentry can satisfy ERC20 accounting.
        _mint(address(this), 100 ether);
    }

    function setTarget(address t) external {
        target = t;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (target != address(0) && !reentered) {
            reentered = true;
            // Approve the target to spend rON balance held by this mock, so the inner
            // deposit's safeTransferFrom doesn't fail on allowance accounting before the
            // reentrancy guard runs.
            _approve(address(this), target, type(uint256).max);
            // Attempt reentry into deposit; the wON contract's `nonReentrant` must reject.
            (bool success, bytes memory ret) = target.call(abi.encodeWithSignature("deposit(uint256)", 1));
            require(!success, "reentry succeeded - nonReentrant guard missing");
            // TEST-16: assert the specific selector so an inner revert from a *different*
            // cause (insufficient balance, allowance, etc.) doesn't masquerade as the
            // guard firing. Foundry surfaces the inner revert reason as a 4-byte selector.
            require(
                ret.length >= 4 && bytes4(ret) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
                "expected ReentrancyGuardReentrantCall"
            );
            reentered = false;
        }
        return ok;
    }
}

/// @dev TEST-8 (withdraw leg): mock whose `transfer` re-enters `WrappedON.withdraw`. The
///      withdraw exit path is `ON.safeTransfer(msg.sender, amount)`, so on a hook-bearing
///      ERC20 the `nonReentrant` guard on `withdraw` is the only thing between that hook and a
///      reentrant unwrap. Mirrors `ReentrantMockON` (which probes the deposit leg via
///      `transferFrom`). The current canonical ON is plain ERC20 with no hooks; this pins the
///      guard against future redeployments against tokens that do hook.
contract ReentrantWithdrawMockON is ERC20 {
    address public target;
    bool internal reentered;

    constructor() ERC20("Reentrant Withdraw Mock ON", "rwON") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function setTarget(address t) external {
        target = t;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (target != address(0) && !reentered) {
            reentered = true;
            // Attempt reentry into withdraw during the outer withdraw's safeTransfer; the
            // wON contract's `nonReentrant` must reject it. `nonReentrant` runs before any
            // body logic, so the inner call reverts regardless of balances/roles.
            (bool success, bytes memory ret) = target.call(abi.encodeWithSignature("withdraw(uint256)", 1));
            require(!success, "reentry succeeded - nonReentrant guard missing");
            // Assert the specific selector so an inner revert from a *different* cause doesn't
            // masquerade as the guard firing.
            require(
                ret.length >= 4 && bytes4(ret) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
                "expected ReentrancyGuardReentrantCall"
            );
            reentered = false;
        }
        return ok;
    }
}

/// @dev WON-14: mock whose `transferFrom` claims success without moving any balance.
///      Exercises the `received == 0` defensive guard in `deposit`.
contract NullTransferMockON is ERC20 {
    constructor() ERC20("Null Transfer Mock ON", "nON") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return true; // lies about success — balance never moves
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
        won = DeployWON.deploy(IERC20(address(on)), admin, admin);

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

    /// @notice WON-14: even when `amount > 0`, a `received == 0` outcome (e.g. a 100%-fee
    ///         or buggy ERC20 whose `transferFrom` returns `true` without moving anything)
    ///         must revert. Otherwise `deposit(N)` would mint zero wON and emit
    ///         `Wrapped(_, 0)`, polluting indexer accounting. Canonical ON is plain ERC20
    ///         and cannot hit this path; the test exercises the defensive guard against
    ///         non-canonical ON variants.
    function test_DepositRevertsOnReceivedZero() public {
        NullTransferMockON mock = new NullTransferMockON();
        WrappedON nullWon = DeployWON.deploy(IERC20(address(mock)), admin, admin);
        mock.mint(address(this), 100 ether);
        mock.approve(address(nullWon), 100 ether);

        vm.expectRevert(WrappedON.ZeroAmount.selector);
        nullWon.deposit(50 ether);
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

    /// @notice Issue 2: `deposit` is permissionless — any holder with ON + approval can wrap.
    function test_DepositPermissionlessForAnyCaller() public {
        vm.prank(alice);
        on.transfer(bob, 50 ether);
        vm.startPrank(bob);
        on.approve(address(won), 50 ether);
        won.deposit(50 ether);
        vm.stopPrank();
        assertEq(won.balanceOf(bob), 50 ether);
        assertEq(on.balanceOf(address(won)), 50 ether);
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
        // SECURITY: TEST-9 — assert the typed OZ error so a refactor that reverts via a
        // different path is caught.
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether);
        vm.stopPrank();

        // `bob` is the class-level address (declared in the state-variable block); he holds
        // zero wON, so the reserve check passes and `_burn` reverts.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1 ether));
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

        // CCIP-mint 50 to bob — always mints wON (no auto-unwrap), even though the reserve
        // (100) covers it. The reserve is untouched; the cap counter grows by 50.
        vm.prank(pool);
        won.mint(bob, 50 ether);

        // totalSupply = alice's deposit-backed wON (100) + bob's CCIP-minted wON (50).
        assertEq(won.totalSupply(), 150 ether, "totalSupply = deposit-backed + CCIP-minted wON");
        assertEq(won.balanceOf(bob), 50 ether, "bob holds CCIP-minted wON");
        assertEq(on.balanceOf(address(won)), 100 ether, "reserve untouched by mint");
        assertEq(on.balanceOf(bob), 0, "bob received no native ON");
        assertEq(won.ccipMintHeadroomUsed(), 50 ether, "cap counter incremented");
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
        // SECURITY: TEST-9 — assert the typed OZ error.
        vm.prank(pool);
        won.mint(alice, 10 ether);

        vm.prank(alice);
        won.approve(pool, 3 ether);

        vm.prank(pool);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, pool, 3 ether, 5 ether)
        );
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

    /// @notice TEST-10: a stale pending admin proposal must be invalidated by a subsequent
    ///         re-proposal to a DIFFERENT address. Once B is proposed, A's queued
    ///         `acceptCCIPAdmin` must revert with `OnlyPendingCCIPAdmin`. The
    ///         `CCIPAdminProposalCancelled(A)` event already pins the overwrite signal at
    ///         the writer side (`test_SetCCIPAdminEmitsCancellationWhenOverwritten`); this
    ///         test pins the accept-side behaviour, so a regression that failed to clear
    ///         the stale pending wouldn't silently honour A's tx.
    function test_AcceptAfterProposalOverwriteReverts() public {
        address first = makeAddr("firstProposed");
        address second = makeAddr("secondProposed");

        vm.prank(admin);
        won.setCCIPAdmin(first);
        vm.prank(admin);
        won.setCCIPAdmin(second);

        // First proposed address is now stale — accept must revert.
        vm.prank(first);
        vm.expectRevert(WrappedON.OnlyPendingCCIPAdmin.selector);
        won.acceptCCIPAdmin();

        // Second proposed address can still accept cleanly.
        vm.prank(second);
        won.acceptCCIPAdmin();
        assertEq(won.getCCIPAdmin(), second);
    }

    /// @notice TEST-11: a successful `acceptCCIPAdmin` clears the pending slot. A second
    ///         call from the same admin must revert `OnlyPendingCCIPAdmin` — confirming
    ///         the slot was actually cleared rather than the check just happening to pass.
    function test_AcceptCCIPAdminDoubleCallReverts() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        won.setCCIPAdmin(newAdmin);

        vm.prank(newAdmin);
        won.acceptCCIPAdmin();

        // Pending slot must now be zero; a second accept from the new admin reverts.
        assertEq(won.pendingCCIPAdmin(), address(0));
        vm.prank(newAdmin);
        vm.expectRevert(WrappedON.OnlyPendingCCIPAdmin.selector);
        won.acceptCCIPAdmin();
    }

    // ─── CCIP mint cap ────────────────────────────────────────────────────────

    /// @notice WON-1: `mint(0)` must revert (mirrors the deposit/withdraw zero guards).
    ///         Pool will never legitimately pass zero; the guard exists to suppress the
    ///         Transfer(pool, account, 0) event a misbehaving pool would otherwise emit.
    function test_MintRevertsOnZeroAmount() public {
        vm.prank(pool);
        vm.expectRevert(WrappedON.ZeroAmount.selector);
        won.mint(alice, 0);
    }

    /// @notice WON-4: `mint` emits the named `CCIPMinted(account, amount, ccipMintHeadroomUsed)`
    ///         event in addition to the inherited ERC20 `Transfer`, so indexers can
    ///         distinguish CCIP inbound from deposit-backed mints.
    function test_MintEmitsCCIPMinted() public {
        vm.expectEmit(true, false, false, true);
        emit WrappedON.CCIPMinted(alice, 5 ether, 5 ether);
        vm.prank(pool);
        won.mint(alice, 5 ether);
    }

    /// @notice WON-4: every burn entrypoint emits `CCIPBurned`.
    function test_BurnEmitsCCIPBurned_SingleArg() public {
        vm.prank(pool);
        won.mint(pool, 5 ether);

        vm.expectEmit(true, false, false, true);
        emit WrappedON.CCIPBurned(pool, 3 ether, 2 ether);
        vm.prank(pool);
        won.burn(3 ether);
    }

    function test_BurnEmitsCCIPBurned_AddressOverload() public {
        vm.prank(pool);
        won.mint(alice, 5 ether);

        vm.expectEmit(true, false, false, true);
        emit WrappedON.CCIPBurned(alice, 2 ether, 3 ether);
        vm.prank(pool);
        won.burn(alice, 2 ether);
    }

    function test_BurnEmitsCCIPBurned_BurnFrom() public {
        vm.prank(pool);
        won.mint(alice, 5 ether);
        vm.prank(alice);
        won.approve(pool, 2 ether);

        vm.expectEmit(true, false, false, true);
        emit WrappedON.CCIPBurned(alice, 2 ether, 3 ether);
        vm.prank(pool);
        won.burnFrom(alice, 2 ether);
    }

    /// @notice WON-5: overwriting an in-flight pending CCIP admin with a DIFFERENT address
    ///         emits `CCIPAdminProposalCancelled(prior)`.
    function test_SetCCIPAdminEmitsCancellationWhenOverwritten() public {
        address first = makeAddr("firstProposed");
        address second = makeAddr("secondProposed");

        vm.prank(admin);
        won.setCCIPAdmin(first);
        assertEq(won.pendingCCIPAdmin(), first);

        vm.expectEmit(true, false, false, false);
        emit WrappedON.CCIPAdminProposalCancelled(first);
        vm.prank(admin);
        won.setCCIPAdmin(second);
        assertEq(won.pendingCCIPAdmin(), second);
    }

    /// @notice WON-5: re-proposing the SAME pending admin must NOT emit a cancellation
    ///         (the slot ends up unchanged; suppressing the event keeps honest retries quiet).
    function test_SetCCIPAdminRePropose_DoesNotEmitCancellation() public {
        address proposed = makeAddr("proposed");

        vm.startPrank(admin);
        won.setCCIPAdmin(proposed);
        // Record logs only for the second call.
        vm.recordLogs();
        won.setCCIPAdmin(proposed);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 cancelTopic = keccak256("CCIPAdminProposalCancelled(address)");
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].topics[0] == cancelTopic, "must not emit cancellation on identical re-propose");
        }
    }

    /// @notice TEST-12: `mint(address(0), amount)` must revert and must NOT inflate
    ///         `ccipMintHeadroomUsed`. `_mintCapped` writes the counter BEFORE `_mint`; in OZ 5.x
    ///         `_mint(address(0), …)` reverts `ERC20InvalidReceiver`, which the EVM rolls
    ///         back along with the counter write — so the contract is safe today, but the
    ///         ordering is a load-bearing assumption worth pinning. A future refactor that
    ///         decoupled increment and mint could leave the counter permanently inflated.
    function test_MintToZeroAddressRevertsAndDoesNotInflate() public {
        uint256 before = won.ccipMintHeadroomUsed();
        vm.prank(pool);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        won.mint(address(0), 5 ether);
        assertEq(won.ccipMintHeadroomUsed(), before, "counter must not move on revert");
    }

    /// @notice TEST-12 (companion to mint-zero, per Chiro's review question): the
    ///         `burn(address, uint256)` overload against `address(0)` must revert with the
    ///         OZ `ERC20InvalidSender` and must NOT desync `ccipMintHeadroomUsed`. Unlike the
    ///         mint path, the burn entrypoints call `_decrementCcipMintHeadroom` BEFORE `_burn`;
    ///         the EVM rolls the counter change back when `_burn` reverts. Pin the
    ///         ordering with a test so a future refactor can't quietly desync the counter.
    function test_BurnAddressOverloadZeroAddressRevertsAndDoesNotDesync() public {
        // Seed `ccipMintHeadroomUsed` so a desync would be observable.
        vm.prank(pool);
        won.mint(alice, 50 ether);
        uint256 before = won.ccipMintHeadroomUsed();

        vm.prank(pool);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        won.burn(address(0), 10 ether);
        assertEq(won.ccipMintHeadroomUsed(), before, "counter must not move on revert");
    }

    function test_MintRevertsAtCCIPMintCap() public {
        uint256 cap = won.MAX_CCIP_MINTED();
        vm.prank(pool);
        won.mint(alice, cap);
        assertEq(won.ccipMintHeadroomUsed(), cap);
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
        assertEq(won.ccipMintHeadroomUsed(), cap);

        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether); // must NOT revert
        vm.stopPrank();

        assertEq(won.balanceOf(alice), 100 ether);
        assertEq(won.totalSupply(), cap + 100 ether);
        assertEq(won.ccipMintHeadroomUsed(), cap, "deposit must not move ccipMintHeadroomUsed");
    }

    /// @notice `withdraw()` must NEVER touch `ccipMintHeadroomUsed`. The counter approximates the
    ///         BSC-pool lock; withdraw only moves the ETH-side reserve and never triggers a BSC
    ///         release, so decrementing it here would free cap headroom without a matching BSC
    ///         release and desync the bridge (the exact safety property the cap protects). This
    ///         is the unwrap-side mirror of `test_DepositSucceedsWhenCCIPCapHit`; a refactor that
    ///         added a decrement to `withdraw` would otherwise pass the whole suite silently.
    function test_WithdrawDoesNotTouchCcipMintHeadroom() public {
        // Drive the counter to a non-zero value via a CCIP mint (the only path that moves it up).
        vm.prank(pool);
        won.mint(bob, 40 ether);
        assertEq(won.ccipMintHeadroomUsed(), 40 ether);

        // Alice does a pure reserve round-trip: deposit then withdraw.
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether);
        assertEq(won.ccipMintHeadroomUsed(), 40 ether, "deposit must not move ccipMintHeadroomUsed");
        won.withdraw(100 ether);
        vm.stopPrank();

        assertEq(won.ccipMintHeadroomUsed(), 40 ether, "withdraw must not move ccipMintHeadroomUsed");
        assertEq(on.balanceOf(address(won)), 0, "reserve fully withdrawn");
    }

    function test_BurnDecrementsCcipMintHeadroom() public {
        vm.prank(pool);
        won.mint(pool, 80 ether);
        assertEq(won.ccipMintHeadroomUsed(), 80 ether);

        vm.prank(pool);
        won.burn(30 ether);
        assertEq(won.ccipMintHeadroomUsed(), 50 ether, "burn frees cap headroom");

        // Cap should be re-mintable now.
        vm.prank(pool);
        won.mint(alice, 30 ether);
        assertEq(won.ccipMintHeadroomUsed(), 80 ether);
    }

    function test_BurnSaturatesCCIPMintedAtZero() public {
        // Wrap 100 (no CCIP mint yet).
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether);
        won.transfer(pool, 100 ether);
        vm.stopPrank();
        assertEq(won.ccipMintHeadroomUsed(), 0);

        // Pool burns its own 100 wON (via outbound CCIP send of deposit-backed wON).
        // ccipMintHeadroomUsed must NOT underflow — it stays at 0.
        vm.prank(pool);
        won.burn(100 ether);
        assertEq(won.ccipMintHeadroomUsed(), 0);
    }

    function test_BurnAddressOverloadDecrementsCCIPMinted() public {
        vm.prank(pool);
        won.mint(alice, 50 ether);
        vm.prank(pool);
        won.burn(alice, 20 ether);
        assertEq(won.ccipMintHeadroomUsed(), 30 ether);
    }

    function test_BurnFromDecrementsCCIPMinted() public {
        vm.prank(pool);
        won.mint(alice, 50 ether);

        vm.prank(alice);
        won.approve(pool, 25 ether);

        vm.prank(pool);
        won.burnFrom(alice, 25 ether);
        assertEq(won.ccipMintHeadroomUsed(), 25 ether);
    }

    /// @notice WON-11: every burn entrypoint rejects zero-amount calls (mirrors the
    ///         `mint`/`deposit`/`withdraw` zero-guards). Without these guards a misbehaving
    ///         pool could spam `CCIPBurned(_, 0, supply)` events and pollute indexer
    ///         accounting.
    function test_BurnRevertsOnZeroAmount_SingleArg() public {
        vm.prank(pool);
        vm.expectRevert(WrappedON.ZeroAmount.selector);
        won.burn(0);
    }

    function test_BurnRevertsOnZeroAmount_AddressOverload() public {
        vm.prank(pool);
        vm.expectRevert(WrappedON.ZeroAmount.selector);
        won.burn(alice, 0);
    }

    function test_BurnFromRevertsOnZeroAmount() public {
        vm.prank(pool);
        vm.expectRevert(WrappedON.ZeroAmount.selector);
        won.burnFrom(alice, 0);
    }

    // ─── Constructor guards ───────────────────────────────────────────────────

    function test_ConstructorEmitsCCIPAdminTransferred() public {
        // The event now fires inside `initialize` during proxy construction. `expectEmit`
        // with a 4-arg form does not check the emitter address (the proxy), only topics.
        // Deploy the impl first so the only event-bearing CREATE is the proxy.
        address newAdmin = makeAddr("newAdmin");
        WrappedON impl = new WrappedON();
        bytes memory data = abi.encodeCall(WrappedON.initialize, (IERC20(address(on)), newAdmin, newAdmin));
        vm.expectEmit(true, true, false, false);
        emit WrappedON.CCIPAdminTransferred(address(0), newAdmin);
        new ERC1967Proxy(address(impl), data);
    }

    function test_ConstructorRevertsOnZeroToken() public {
        // `initialize` reverts during proxy construction; the selector is unchanged. The impl
        // is deployed OUTSIDE `expectRevert` so the guard applies only to the proxy CREATE
        // (the call that delegatecalls into the reverting `initialize`).
        WrappedON impl = new WrappedON();
        bytes memory data = abi.encodeCall(WrappedON.initialize, (IERC20(address(0)), admin, admin));
        vm.expectRevert(WrappedON.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_ConstructorRevertsOnZeroAdmin() public {
        WrappedON impl = new WrappedON();
        bytes memory data = abi.encodeCall(WrappedON.initialize, (IERC20(address(on)), address(0), admin));
        vm.expectRevert(WrappedON.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_ConstructorRevertsOnZeroTimelock() public {
        WrappedON impl = new WrappedON();
        bytes memory data = abi.encodeCall(WrappedON.initialize, (IERC20(address(on)), admin, address(0)));
        vm.expectRevert(WrappedON.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    /// @dev Per PR #19 review (brng1151 #1, bao-ninh #5): init must reject the
    ///      `address(this)` self-reserve case (would make the reserve invariant circular).
    ///      Through the proxy, `address(this)` inside `initialize` is the PROXY address, so we
    ///      predict the proxy's CREATE address and pass it as the ON token.
    function test_ConstructorRevertsOnSelfReserve() public {
        // The impl is deployed first (nonce N), the proxy second (nonce N+1). Predict the
        // proxy address and feed it as the ON token to trip the SelfReserve guard.
        WrappedON impl = new WrappedON();
        address predictedProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes memory data = abi.encodeCall(WrappedON.initialize, (IERC20(predictedProxy), admin, admin));
        vm.expectRevert(WrappedON.SelfReserve.selector);
        new ERC1967Proxy(address(impl), data);
    }

    /// @dev Per PR #19 review (bao-ninh #5): constructor must reject ON tokens with
    ///      non-18 decimals (1:1 wrap accounting only holds at matching decimals).
    /// @notice SECURITY: TEST-8 — `nonReentrant` on `deposit` must reject a reentry
    ///         triggered by a hook-bearing ERC20's `transferFrom`. The current canonical
    ///         ON is plain ERC20 with no hooks; this test pins the behaviour against
    ///         future redeployments against tokens that do hook.
    function test_DepositReentrancyGuardFires() public {
        ReentrantMockON rOn = new ReentrantMockON();
        WrappedON rWon = DeployWON.deploy(IERC20(address(rOn)), admin, admin);
        rOn.setTarget(address(rWon));

        // Mock token mints supply to test contract; approve from here as the depositor.
        rOn.approve(address(rWon), 10 ether);

        // The mock's `transferFrom` will call back into `rWon.deposit(1)` mid-execution.
        // The nonReentrant guard must reject the inner call. The mock then `require(!success)`s,
        // which surfaces here as a revert from the outer deposit.
        // If the guard were removed, the inner call would succeed and the require would revert
        // with "reentry succeeded …"; if the guard is intact, the inner call reverts with
        // `ReentrancyGuardReentrantCall` and the mock's super.transferFrom completed fine —
        // so the OUTER deposit must complete normally.
        rWon.deposit(5 ether);
        assertEq(rWon.balanceOf(address(this)), 5 ether, "outer deposit must complete");
    }

    /// @notice SECURITY: TEST-8 (withdraw leg) — `nonReentrant` on `withdraw` must reject a
    ///         reentry triggered by a hook-bearing ERC20's `transfer` (the withdraw exit path).
    ///         The deposit leg is covered by `test_DepositReentrancyGuardFires`; this is its
    ///         unwrap-side sibling. The mock re-enters `withdraw(1)` from inside `transfer` and
    ///         asserts the inner call reverts `ReentrancyGuardReentrantCall`, so the OUTER
    ///         withdraw must still complete normally.
    function test_WithdrawReentrancyGuardFires() public {
        ReentrantWithdrawMockON rOn = new ReentrantWithdrawMockON();
        WrappedON rWon = DeployWON.deploy(IERC20(address(rOn)), admin, admin);

        // Fund alice with rON BEFORE arming the reentrancy so this transfer doesn't trip it.
        rOn.transfer(alice, 1000 ether);

        // Deposit uses `transferFrom` (not the armed `transfer` path), so the reserve fills cleanly.
        vm.startPrank(alice);
        rOn.approve(address(rWon), 100 ether);
        rWon.deposit(100 ether);
        vm.stopPrank();

        // Arm the reentrancy: the next rON.transfer (the withdraw exit) re-enters withdraw.
        rOn.setTarget(address(rWon));

        vm.prank(alice);
        rWon.withdraw(50 ether);

        assertEq(rWon.balanceOf(alice), 50 ether, "outer withdraw must complete");
        assertEq(rOn.balanceOf(address(rWon)), 50 ether, "reserve reduced by the withdrawn amount");
    }

    function test_ConstructorRevertsOnDecimalsMismatch() public {
        MockON6 on6 = new MockON6();
        WrappedON impl = new WrappedON();
        bytes memory data = abi.encodeCall(WrappedON.initialize, (IERC20(address(on6)), admin, admin));
        vm.expectRevert(abi.encodeWithSelector(WrappedON.DecimalsMismatch.selector, 18, 6));
        new ERC1967Proxy(address(impl), data);
    }

    // ─── Metadata ─────────────────────────────────────────────────────────────

    function test_SupportsInterfacePositiveAndNegative() public view {
        assertTrue(won.supportsInterface(type(IERC20).interfaceId));
        assertTrue(won.supportsInterface(type(IERC20Metadata).interfaceId), "WON-7: must advertise IERC20Metadata");
        assertTrue(won.supportsInterface(type(IBurnMintERC20).interfaceId));
        assertTrue(won.supportsInterface(type(IGetCCIPAdmin).interfaceId));
        assertTrue(won.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(won.supportsInterface(type(IERC165).interfaceId));
        assertFalse(won.supportsInterface(0xdeadbeef));
    }

    /// @notice Pins the CCIP-facing ABI to hard-coded literals matching the PRODUCTION
    ///         Chainlink 1.6.1 deployment (`BurnMintTokenPool` calls `mint`/`burn` by these
    ///         exact 4-byte selectors; `RegistryModuleOwnerCustom` calls `getCCIPAdmin()`).
    ///         These selectors/interface-ids are byte-identical across 1.5.x and 1.6.1 — the
    ///         signatures never changed — so the literals double as a cross-version anchor.
    ///         The sibling test above asserts against `type(I).interfaceId` of the VENDORED
    ///         submodule — which would silently follow a submodule re-pin. Deployed pool
    ///         bytecode is immutable, so these literals must never change; a failure here
    ///         means the token no longer matches what production CCIP actually calls.
    function test_ProductionSelectorsAndInterfaceIdsPinned() public {
        // Vendored interfaces still hash to the production constants (detects submodule drift).
        assertEq(type(IBurnMintERC20).interfaceId, bytes4(0xe6599b4d), "IBurnMintERC20 id drifted from production");
        assertEq(type(IGetCCIPAdmin).interfaceId, bytes4(0x8fd6a6ac), "IGetCCIPAdmin id drifted from production");
        // ERC-165 advertisement answers the raw production constants, not just the vendored ids.
        assertTrue(won.supportsInterface(bytes4(0xe6599b4d)));
        assertTrue(won.supportsInterface(bytes4(0x8fd6a6ac)));

        // Runtime dispatch on the exact selectors production pool bytecode emits.
        bool ok;
        bytes memory ret;

        // mint(address,uint256) = 0x40c10f19 — BurnMintTokenPoolAbstract.releaseOrMint.
        vm.prank(pool);
        (ok,) = address(won).call(abi.encodeWithSelector(bytes4(0x40c10f19), alice, uint256(3 ether)));
        assertTrue(ok, "mint selector 0x40c10f19 not dispatched");
        assertEq(won.balanceOf(alice), 3 ether);

        // burn(uint256) = 0x42966c68 — BurnMintTokenPool._burn (the deployed pool variant).
        vm.prank(pool);
        (ok,) = address(won).call(abi.encodeWithSelector(bytes4(0x40c10f19), pool, uint256(2 ether)));
        assertTrue(ok);
        vm.prank(pool);
        (ok,) = address(won).call(abi.encodeWithSelector(bytes4(0x42966c68), uint256(2 ether)));
        assertTrue(ok, "burn selector 0x42966c68 not dispatched");
        assertEq(won.balanceOf(pool), 0);

        // burn(address,uint256) = 0x9dc29fac — BurnWithFromMintTokenPool variant.
        vm.prank(pool);
        (ok,) = address(won).call(abi.encodeWithSelector(bytes4(0x9dc29fac), alice, uint256(1 ether)));
        assertTrue(ok, "burn selector 0x9dc29fac not dispatched");
        assertEq(won.balanceOf(alice), 2 ether);

        // burnFrom(address,uint256) = 0x79cc6790 — BurnFromMintTokenPool variant.
        vm.prank(alice);
        won.approve(pool, 1 ether);
        vm.prank(pool);
        (ok,) = address(won).call(abi.encodeWithSelector(bytes4(0x79cc6790), alice, uint256(1 ether)));
        assertTrue(ok, "burnFrom selector 0x79cc6790 not dispatched");
        assertEq(won.balanceOf(alice), 1 ether);

        // getCCIPAdmin() = 0x8fd6a6ac — RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin.
        (ok, ret) = address(won).staticcall(abi.encodeWithSelector(bytes4(0x8fd6a6ac)));
        assertTrue(ok, "getCCIPAdmin selector 0x8fd6a6ac not dispatched");
        assertEq(abi.decode(ret, (address)), admin);
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

    // ─── CCIP mint always delivers wON (Issue #48) ────────────────────────────
    // The CCIP `releaseOrMint` path mints wON unconditionally — it never reads the reserve
    // and never delivers native ON. This keeps the asset delivered to BSC→ETH receivers
    // deterministic (the registered token, wON), closing the front-runnable contract-receiver
    // footgun from #48. EOAs that want native ON call `withdraw` like any other holder.

    /// @notice #48: reserve fully covers the arrival, yet `mint` still mints wON — no native
    ///         ON is delivered, the reserve is untouched, and the cap counter grows.
    function test_MintMintsWonEvenWhenReserveCovers() public {
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether); // reserve = 100 ON, alice holds 100 wON
        vm.stopPrank();

        uint256 bobOnBefore = on.balanceOf(bob);
        uint256 supplyBefore = won.totalSupply();

        vm.expectEmit(true, false, false, true);
        emit WrappedON.CCIPMinted(bob, 40 ether, 40 ether);
        vm.prank(pool);
        won.mint(bob, 40 ether);

        assertEq(won.balanceOf(bob), 40 ether, "bob got wON, not native ON");
        assertEq(on.balanceOf(bob), bobOnBefore, "no native ON delivered");
        assertEq(won.totalSupply(), supplyBefore + 40 ether, "totalSupply grew by mint");
        assertEq(won.ccipMintHeadroomUsed(), 40 ether, "cap counter incremented");
        assertEq(on.balanceOf(address(won)), 100 ether, "reserve untouched");
    }

    /// @notice #48 boundary: reserve == amount still mints wON (the reserve is never read).
    function test_MintMintsWonAtExactReserve() public {
        vm.startPrank(alice);
        on.approve(address(won), 50 ether);
        won.deposit(50 ether);
        vm.stopPrank();

        vm.prank(pool);
        won.mint(bob, 50 ether);

        assertEq(won.balanceOf(bob), 50 ether, "wON minted at exact-reserve boundary");
        assertEq(on.balanceOf(bob), 0, "no native ON delivered");
        assertEq(won.totalSupply(), 100 ether, "alice's deposit-wON + bob's CCIP-wON");
        assertEq(won.ccipMintHeadroomUsed(), 50 ether, "cap incremented");
        assertEq(on.balanceOf(address(won)), 50 ether, "reserve untouched");
    }

    /// @notice Reserve below the arrival also mints wON — same path, no branch on reserve.
    function test_MintMintsWonWhenReserveInsufficient() public {
        vm.startPrank(alice);
        on.approve(address(won), 30 ether);
        won.deposit(30 ether);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true);
        emit WrappedON.CCIPMinted(bob, 100 ether, 100 ether);
        vm.prank(pool);
        won.mint(bob, 100 ether);

        assertEq(won.balanceOf(bob), 100 ether, "wON minted");
        assertEq(on.balanceOf(bob), 0, "no ON delivered");
        assertEq(on.balanceOf(address(won)), 30 ether, "reserve untouched");
        assertEq(won.ccipMintHeadroomUsed(), 100 ether, "cap counter incremented");
    }

    /// @notice #48: the reserve level NEVER changes what `mint` delivers — it always mints
    ///         wON and never moves native ON, across any reserve/amount combination. Fuzzed
    ///         over both so a reintroduced reserve-read branch is caught at every boundary.
    function testFuzz_MintAlwaysMintsWonRegardlessOfReserve(uint96 reserveRaw, uint96 amountRaw) public {
        uint256 reserve = bound(uint256(reserveRaw), 0, 1_000_000 ether);
        uint256 amount = bound(uint256(amountRaw), 1, 1_000_000 ether);

        // Seed an arbitrary reserve via a permissionless deposit (alice holds the wON).
        if (reserve > 0) {
            vm.startPrank(alice);
            on.approve(address(won), reserve);
            won.deposit(reserve);
            vm.stopPrank();
        }

        uint256 bobOnBefore = on.balanceOf(bob);
        uint256 supplyBefore = won.totalSupply();

        vm.prank(pool);
        won.mint(bob, amount);

        assertEq(won.balanceOf(bob), amount, "bob always receives wON");
        assertEq(on.balanceOf(bob), bobOnBefore, "bob never receives native ON");
        assertEq(on.balanceOf(address(won)), reserve, "reserve never touched by mint");
        assertEq(won.totalSupply(), supplyBefore + amount, "supply grew by the full amount");
        assertEq(won.ccipMintHeadroomUsed(), amount, "cap counter incremented by the full amount");
    }

    /// @notice #48 core scenario: a CONTRACT receiver gets wON even when the reserve fully
    ///         covers the arrival. This is the case the auto-unwrap removal protects — a
    ///         programmatic CCIP receiver that expects wON must never observe native ON
    ///         instead (a front-runnable swap under the old auto-unwrap branch).
    function test_MintToContractReceiverMintsWon() public {
        // Seed a covering reserve.
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether);
        vm.stopPrank();

        address contractReceiver = address(new ContractReceiver());
        assertGt(contractReceiver.code.length, 0, "receiver is a contract");

        vm.prank(pool);
        won.mint(contractReceiver, 40 ether);

        assertEq(won.balanceOf(contractReceiver), 40 ether, "contract receiver got wON");
        assertEq(on.balanceOf(contractReceiver), 0, "contract receiver got no native ON");
        assertEq(on.balanceOf(address(won)), 100 ether, "reserve untouched");
        assertEq(won.ccipMintHeadroomUsed(), 40 ether, "cap counter incremented");
    }

    /// @notice CCIP mint up to the cap succeeds; one wei over reverts. Boundary fuzz around
    ///         `MAX_CCIP_MINTED` to catch off-by-one regressions.
    function testFuzz_CcipMintCapBoundary(uint128 underBy) public {
        uint256 cap = won.MAX_CCIP_MINTED();
        underBy = uint128(bound(uint256(underBy), 1, 1_000_000 ether));
        uint256 firstMint = cap - underBy;

        vm.prank(pool);
        won.mint(alice, firstMint);
        assertEq(won.ccipMintHeadroomUsed(), firstMint);

        // Filling exactly to the cap must succeed.
        vm.prank(pool);
        won.mint(alice, underBy);
        assertEq(won.ccipMintHeadroomUsed(), cap);

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
        assertEq(won.ccipMintHeadroomUsed(), amount);

        vm.prank(pool);
        won.burn(amount);
        assertEq(won.ccipMintHeadroomUsed(), 0, "burn frees cap");

        // Cap is now fully re-mintable.
        vm.prank(pool);
        won.mint(alice, cap);
        assertEq(won.ccipMintHeadroomUsed(), cap);
    }

    // ─── Wrap volume does NOT consume CCIP cap headroom ───────────────────────

    /// @notice Regression guard: even a 100M deposit (= MAX_CCIP_MINTED) via the permissionless
    ///         wrap leaves `ccipMintHeadroomUsed` at 0, so a subsequent BSC→ETH arrival (the
    ///         pool calls `mint`) still succeeds. `deposit` only moves the reserve + supply; it
    ///         never touches the CCIP counter, so heavy wrapping cannot starve inbound CCIP.
    function test_DepositDoesNotConsumeCcipMintCap() public {
        uint256 cap = won.MAX_CCIP_MINTED(); // 100M

        // Adversary wraps 100M ON_eth -> 100M wON (permissionless, uncapped deposit).
        address adversary = makeAddr("adversary");
        deal(address(on), adversary, cap);
        vm.startPrank(adversary);
        on.approve(address(won), cap);
        won.deposit(cap);
        vm.stopPrank();

        emit log_named_uint("ccipMintHeadroomUsed after 100M deposit", won.ccipMintHeadroomUsed());
        emit log_named_uint("totalSupply after 100M deposit          ", won.totalSupply());

        // Legitimate user bridges BSC->ETH: the pool mints wON to them.
        address user = makeAddr("user");
        vm.prank(pool);
        won.mint(user, 1 ether);

        assertEq(won.balanceOf(user), 1 ether, "user received bridged wON");
    }
}
