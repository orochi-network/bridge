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

    function test_AcceptCCIPAdminRevertsForNonPending() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        won.setCCIPAdmin(newAdmin);

        vm.prank(alice);
        vm.expectRevert(WrappedON.OnlyPendingCCIPAdmin.selector);
        won.acceptCCIPAdmin();
    }

    // ─── Supply cap ───────────────────────────────────────────────────────────

    function test_MintRevertsAtSupplyCap() public {
        uint256 cap = won.MAX_SUPPLY();
        vm.prank(pool);
        won.mint(alice, cap);
        assertEq(won.totalSupply(), cap);

        vm.prank(pool);
        vm.expectRevert(abi.encodeWithSelector(WrappedON.SupplyCapExceeded.selector, cap, cap + 1));
        won.mint(alice, 1);
    }

    function test_DepositRevertsAtSupplyCap() public {
        // Move all 1M mock ON to the cap test: alice holds 1M ON; cap is 100M wON.
        // To verify the deposit-path cap, pre-mint up to cap via the pool then attempt to deposit 1.
        uint256 cap = won.MAX_SUPPLY();
        vm.prank(pool);
        won.mint(bob, cap);

        vm.startPrank(alice);
        on.approve(address(won), 1);
        vm.expectRevert(abi.encodeWithSelector(WrappedON.SupplyCapExceeded.selector, cap, cap + 1));
        won.deposit(1);
        vm.stopPrank();
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
}
