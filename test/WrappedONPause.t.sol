// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {WrappedON} from "../src/WrappedON.sol";
import {DeployWON} from "./helpers/DeployWON.sol";

/// @dev Minimal mock of the canonical ON token (non-mintable ERC20). Mirrors the inline
///      MockON defined in test/WrappedON.t.sol — defined here to avoid cross-file imports
///      of non-library contracts.
contract MockON is ERC20 {
    constructor() ERC20("Orochi Network", "ON") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract WrappedONPauseTest is Test {
    MockON internal on;
    WrappedON internal won;
    address internal admin = makeAddr("admin");
    address internal pool = makeAddr("pool");
    address internal alice = makeAddr("alice");

    function setUp() public {
        on = new MockON();
        won = DeployWON.deploy(IERC20(address(on)), admin, admin);
        vm.startPrank(admin);
        won.grantRole(won.MINTER_ROLE(), pool);
        won.grantRole(won.BURNER_ROLE(), pool);
        vm.stopPrank();
        on.transfer(alice, 1000 ether);
    }

    /// @notice PAUSER_ROLE holder can toggle pause state; `paused()` reflects each transition.
    function test_PauserCanPauseAndUnpause() public {
        vm.prank(admin);
        won.pause();
        assertTrue(won.paused());
        vm.prank(admin);
        won.unpause();
        assertFalse(won.paused());
    }

    /// @notice Non-holder of PAUSER_ROLE reverts with the typed AccessControl error.
    ///         Cache the role bytes32 BEFORE vm.prank to avoid consuming the prank on the
    ///         view call.
    function test_NonPauserCannotPause() public {
        bytes32 pauserRole = won.PAUSER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, pauserRole)
        );
        won.pause();
    }

    /// @notice Paused state blocks both `deposit` and `mint` (the value paths).
    function test_PausedBlocksValuePaths() public {
        vm.prank(admin);
        won.pause();

        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        won.deposit(100 ether);
        vm.stopPrank();

        vm.prank(pool);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        won.mint(alice, 1 ether);
    }

    /// @notice Paused state blocks `withdraw`. Seed first (unpaused) so the account holds wON
    ///         and the reserve is funded — proving the revert is from the pause, not from an
    ///         empty reserve or zero balance.
    function test_PausedBlocksWithdraw() public {
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether); // alice now holds 100 wON; reserve = 100 ON
        vm.stopPrank();

        vm.prank(admin);
        won.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        won.withdraw(50 ether);
    }

    /// @notice Paused state blocks `burn(uint256)`. `whenNotPaused` fires before the
    ///         role/balance logic, so the BURNER_ROLE holder (`pool`) hits the pause guard
    ///         without any seeded balance.
    function test_PausedBlocksBurnSingleArg() public {
        vm.prank(admin);
        won.pause();

        vm.prank(pool);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        won.burn(1 ether);
    }

    /// @notice Paused state blocks the `burn(address,uint256)` overload — pause guard fires
    ///         before role/balance checks.
    function test_PausedBlocksBurnAddressOverload() public {
        vm.prank(admin);
        won.pause();

        vm.prank(pool);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        won.burn(alice, 1 ether);
    }

    /// @notice Paused state blocks `burnFrom(address,uint256)` — pause guard fires before the
    ///         allowance check, so no approve is needed.
    function test_PausedBlocksBurnFrom() public {
        vm.prank(admin);
        won.pause();

        vm.prank(pool);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        won.burnFrom(alice, 1 ether);
    }

    /// @notice Paused state does NOT block plain ERC20 `transfer` — transfers must stay live.
    function test_PausedAllowsTransfer() public {
        // Mint some wON first (reserve 0 so mint goes to wON path), then pause.
        vm.prank(pool);
        won.mint(alice, 50 ether);
        vm.prank(admin);
        won.pause();
        vm.prank(alice);
        won.transfer(makeAddr("bob"), 10 ether); // must NOT revert
        assertEq(won.balanceOf(makeAddr("bob")), 10 ether);
    }

    /// @notice After unpause, the value paths (mint) are restored.
    function test_UnpauseRestoresValuePaths() public {
        vm.prank(admin);
        won.pause();
        vm.prank(admin);
        won.unpause();
        vm.prank(pool);
        won.mint(alice, 5 ether);
        assertEq(won.balanceOf(alice), 5 ether);
    }

    /// @notice After unpause, 1:1 redemption (`withdraw`) is restored — the emergency redemption
    ///         halt (WON-21 / #56) is reversible, not a permanent freeze. Completes the
    ///         pause→unpause matrix alongside `test_UnpauseRestoresValuePaths` (mint).
    function test_UnpauseRestoresWithdraw() public {
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether); // alice holds 100 wON; reserve = 100 ON
        vm.stopPrank();

        vm.prank(admin);
        won.pause();
        // While paused, redemption is frozen (WON-21).
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        won.withdraw(40 ether);

        vm.prank(admin);
        won.unpause();

        uint256 onBefore = on.balanceOf(alice);
        vm.prank(alice);
        won.withdraw(40 ether); // must succeed once unpaused
        assertEq(won.balanceOf(alice), 60 ether, "wON burned on redemption");
        assertEq(on.balanceOf(alice) - onBefore, 40 ether, "native ON returned");
    }
}
