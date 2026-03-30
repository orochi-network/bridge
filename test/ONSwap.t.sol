// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ONSwap} from "../src/ONSwap.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ONSwapTest is Test {
    ONSwap public swap;
    MockERC20 public oldToken;
    MockERC20 public newToken;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant SEED = 100_000_000 ether;

    function setUp() public {
        oldToken = new MockERC20("Old ON", "ON");
        newToken = new MockERC20("New ON", "ON");
        swap = new ONSwap(address(oldToken), address(newToken), owner);

        newToken.mint(address(swap), SEED);
        oldToken.mint(alice, 1_000_000 ether);
        oldToken.mint(bob, 500_000 ether);

        vm.prank(alice);
        oldToken.approve(address(swap), type(uint256).max);
        vm.prank(bob);
        oldToken.approve(address(swap), type(uint256).max);
    }

    // ========== Constructor ==========

    function test_constructor_setsImmutables() public view {
        assertEq(address(swap.OLD_TOKEN()), address(oldToken));
        assertEq(address(swap.NEW_TOKEN()), address(newToken));
        assertEq(swap.owner(), owner);
        assertEq(swap.DEAD(), DEAD);
    }

    function test_constructor_revert_zeroOldToken() public {
        vm.expectRevert(ONSwap.ZeroAddress.selector);
        new ONSwap(address(0), address(newToken), owner);
    }

    function test_constructor_revert_zeroNewToken() public {
        vm.expectRevert(ONSwap.ZeroAddress.selector);
        new ONSwap(address(oldToken), address(0), owner);
    }

    function test_constructor_revert_sameToken() public {
        vm.expectRevert(ONSwap.SameToken.selector);
        new ONSwap(address(oldToken), address(oldToken), owner);
    }

    function test_rejectEth() public {
        (bool ok,) = address(swap).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ========== Swap ==========

    function test_swap() public {
        vm.prank(alice);
        swap.swap(1000 ether);

        assertEq(newToken.balanceOf(alice), 1000 ether);
        assertEq(oldToken.balanceOf(alice), 1_000_000 ether - 1000 ether);
        assertEq(oldToken.balanceOf(DEAD), 1000 ether);
        assertEq(oldToken.balanceOf(address(swap)), 0);
        assertEq(newToken.balanceOf(address(swap)), SEED - 1000 ether);
        assertEq(swap.totalSwapped(), 1000 ether);
    }

    function test_swap_burnsOldToken() public {
        uint256 deadBefore = oldToken.balanceOf(DEAD);

        vm.prank(alice);
        swap.swap(5000 ether);

        assertEq(oldToken.balanceOf(DEAD), deadBefore + 5000 ether);
    }

    function test_swap_multipleUsers() public {
        vm.prank(alice);
        swap.swap(500_000 ether);
        vm.prank(bob);
        swap.swap(200_000 ether);

        assertEq(newToken.balanceOf(alice), 500_000 ether);
        assertEq(newToken.balanceOf(bob), 200_000 ether);
        assertEq(oldToken.balanceOf(DEAD), 700_000 ether);
        assertEq(swap.totalSwapped(), 700_000 ether);
    }

    function test_swap_sameUserMultipleTimes() public {
        vm.startPrank(alice);
        swap.swap(100 ether);
        swap.swap(200 ether);
        swap.swap(300 ether);
        vm.stopPrank();

        assertEq(newToken.balanceOf(alice), 600 ether);
        assertEq(oldToken.balanceOf(DEAD), 600 ether);
        assertEq(swap.totalSwapped(), 600 ether);
    }

    function test_swap_exactPoolBalance() public {
        oldToken.mint(alice, SEED);
        vm.prank(alice);
        swap.swap(SEED);

        assertEq(newToken.balanceOf(address(swap)), 0);
        assertEq(swap.totalSwapped(), SEED);
    }

    function test_swap_oneWei() public {
        vm.prank(alice);
        swap.swap(1);

        assertEq(newToken.balanceOf(alice), 1);
        assertEq(oldToken.balanceOf(DEAD), 1);
        assertEq(swap.totalSwapped(), 1);
    }

    function test_swap_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(swap));
        emit ONSwap.Swapped(alice, 1000 ether);
        vm.prank(alice);
        swap.swap(1000 ether);
    }

    // ========== Swap Reverts ==========

    function test_swap_revert_zeroAmount() public {
        vm.expectRevert(ONSwap.ZeroAmount.selector);
        vm.prank(alice);
        swap.swap(0);
    }

    function test_swap_revert_noApproval() public {
        address charlie = makeAddr("charlie");
        oldToken.mint(charlie, 100 ether);
        vm.expectRevert();
        vm.prank(charlie);
        swap.swap(100 ether);
    }

    function test_swap_revert_insufficientOldBalance() public {
        address charlie = makeAddr("charlie");
        oldToken.mint(charlie, 10 ether);
        vm.prank(charlie);
        oldToken.approve(address(swap), type(uint256).max);
        vm.expectRevert();
        vm.prank(charlie);
        swap.swap(100 ether);
    }

    function test_swap_revert_poolExhausted() public {
        oldToken.mint(alice, SEED);
        vm.prank(alice);
        swap.swap(SEED);

        oldToken.mint(bob, 1);
        vm.expectRevert();
        vm.prank(bob);
        swap.swap(1);
    }

    // ========== Recovery ==========

    function test_recover_newToken() public {
        vm.prank(owner);
        swap.recover(address(newToken), owner, 1000 ether);
        assertEq(newToken.balanceOf(owner), 1000 ether);
    }

    function test_recover_arbitraryToken() public {
        MockERC20 random = new MockERC20("Random", "RND");
        random.mint(address(swap), 500 ether);

        vm.prank(owner);
        swap.recover(address(random), owner, 500 ether);
        assertEq(random.balanceOf(owner), 500 ether);
    }

    function test_recover_emitsEvent() public {
        vm.expectEmit(true, true, false, true, address(swap));
        emit ONSwap.Recovered(address(newToken), owner, 1000 ether);
        vm.prank(owner);
        swap.recover(address(newToken), owner, 1000 ether);
    }

    function test_recover_revert_notOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        swap.recover(address(newToken), alice, 100 ether);
    }

    function test_recover_revert_zeroAddress() public {
        vm.expectRevert(ONSwap.ZeroAddress.selector);
        vm.prank(owner);
        swap.recover(address(newToken), address(0), 100 ether);
    }

    // ========== Emergency ==========

    function test_emergencyPause_byRecoveringNewToken() public {
        vm.prank(owner);
        swap.recover(address(newToken), owner, SEED);

        vm.expectRevert();
        vm.prank(alice);
        swap.swap(100 ether);
    }

    // ========== Fuzz ==========

    function testFuzz_swap(uint256 amount) public {
        amount = bound(amount, 1, SEED);
        oldToken.mint(alice, SEED);

        vm.prank(alice);
        swap.swap(amount);

        assertEq(newToken.balanceOf(alice), amount);
        assertEq(oldToken.balanceOf(DEAD), amount);
        assertEq(swap.totalSwapped(), amount);
    }

    // ========== Ownership ==========

    function test_renounceOwnership_reverts() public {
        vm.expectRevert("disabled");
        vm.prank(owner);
        swap.renounceOwnership();
    }

    // ========== Invariant ==========

    function test_invariant_noOldTokenInSwap() public {
        vm.prank(alice);
        swap.swap(300_000 ether);
        vm.prank(bob);
        swap.swap(200_000 ether);

        // Old tokens go to DEAD, not to the swap contract
        assertEq(oldToken.balanceOf(address(swap)), 0);
        assertEq(oldToken.balanceOf(DEAD), 500_000 ether);
        assertEq(swap.totalSwapped(), 500_000 ether);
    }
}
