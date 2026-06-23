// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {WrappedON} from "../src/WrappedON.sol";
import {WrappedONV2Mock} from "./mocks/WrappedONV2Mock.sol";
import {DeployWON} from "./helpers/DeployWON.sol";

/// @dev Minimal mock of the canonical ON token (non-mintable ERC20). Mirrors the inline
///      MockON defined in test/WrappedON.t.sol — defined here to avoid cross-file imports
///      of non-library contracts.
contract MockON is ERC20 {
    constructor() ERC20("Orochi Network", "ON") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract WrappedONUpgradeTest is Test {
    MockON internal on;
    WrappedON internal won;
    address internal admin = makeAddr("admin");
    address internal timelock = makeAddr("timelock");
    address internal pool = makeAddr("pool");

    function setUp() public {
        on = new MockON();
        won = DeployWON.deploy(IERC20(address(on)), admin, timelock);
        bytes32 minterRole = won.MINTER_ROLE();
        vm.prank(admin);
        won.grantRole(minterRole, pool);
    }

    /// @notice Upgrade replaces the implementation while all namespaced storage slots survive.
    function test_UpgradePreservesState() public {
        // Seed state: a CCIP mint increments ccipMintHeadroomUsed and mints wON to admin.
        // mint() auto-unwraps when reserve >= amount; reserve is 0 here, so it mints wON.
        vm.prank(pool);
        won.mint(admin, 1000 ether);
        assertEq(won.ccipMintHeadroomUsed(), 1000 ether);
        assertEq(won.balanceOf(admin), 1000 ether);

        WrappedONV2Mock v2 = new WrappedONV2Mock();
        vm.prank(timelock);
        won.upgradeToAndCall(address(v2), "");

        assertEq(WrappedONV2Mock(address(won)).version(), 2, "impl swapped");
        assertEq(won.ccipMintHeadroomUsed(), 1000 ether, "headroom preserved");
        assertEq(won.balanceOf(admin), 1000 ether, "balance preserved");
        assertEq(address(won.ON()), address(on), "ON preserved");
        assertEq(won.getCCIPAdmin(), admin, "ccipAdmin preserved");
    }

    /// @notice Accounts without UPGRADER_ROLE cannot call upgradeToAndCall.
    function test_UpgradeRevertsForNonUpgrader() public {
        WrappedONV2Mock v2 = new WrappedONV2Mock();
        // Cache role before prank — won.UPGRADER_ROLE() is an external call that would
        // consume the vm.prank if called inside the expectRevert block.
        bytes32 upgraderRole = won.UPGRADER_ROLE();
        // admin holds DEFAULT_ADMIN_ROLE + PAUSER_ROLE but NOT UPGRADER_ROLE.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, upgraderRole)
        );
        vm.prank(admin);
        won.upgradeToAndCall(address(v2), "");
    }

    /// @notice initialize cannot be called a second time on the proxy (re-init guard).
    function test_InitializeCannotBeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        won.initialize(IERC20(address(on)), admin, timelock);
    }

    /// @notice The bare implementation's initializers are disabled via _disableInitializers()
    ///         in the constructor, so it cannot be initialized directly.
    function test_ImplementationInitializersDisabled() public {
        WrappedON impl = new WrappedON();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(IERC20(address(on)), admin, timelock);
    }

    // ─── Post-upgrade functional behaviour ────────────────────────────────────
    // The tests above prove storage SURVIVES an upgrade; these prove the contract still
    // FUNCTIONS through the proxy after the implementation is swapped — value paths and
    // accounting must keep working and stay consistent with pre-upgrade state.

    /// @notice After a real upgrade, deposit/withdraw/auto-unwrap/CCIP-mint all still work
    ///         and the reserve, cap counter, and totalSupply stay consistent — integrating
    ///         pre-upgrade state (alice's CCIP-minted wON) with post-upgrade operations.
    function test_ValuePathsWorkAfterUpgrade() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        // Pre-upgrade: CCIP mint to alice (reserve 0 -> wON minted, cap consumed).
        vm.prank(pool);
        won.mint(alice, 1000 ether);
        assertEq(won.ccipMintHeadroomUsed(), 1000 ether);

        // Upgrade the implementation.
        WrappedONV2Mock v2 = new WrappedONV2Mock();
        vm.prank(timelock);
        won.upgradeToAndCall(address(v2), "");
        assertEq(WrappedONV2Mock(address(won)).version(), 2, "impl swapped");

        // Post-upgrade deposit (permissionless): bob wraps 200 ON.
        on.transfer(bob, 200 ether);
        vm.startPrank(bob);
        on.approve(address(won), 200 ether);
        won.deposit(200 ether);
        vm.stopPrank();
        assertEq(won.balanceOf(bob), 200 ether, "post-upgrade deposit mints wON");
        assertEq(on.balanceOf(address(won)), 200 ether, "reserve grew");

        // Post-upgrade withdraw: alice unwraps 150 against the reserve.
        vm.prank(alice);
        won.withdraw(150 ether);
        assertEq(won.balanceOf(alice), 850 ether, "post-upgrade withdraw burns wON");
        assertEq(on.balanceOf(alice), 150 ether, "alice received native ON");
        assertEq(on.balanceOf(address(won)), 50 ether, "reserve drained by withdraw");

        // Post-upgrade auto-unwrap: reserve (50) fully covers a 30 arrival -> native ON,
        // cap counter untouched.
        vm.prank(pool);
        won.mint(carol, 30 ether);
        assertEq(won.balanceOf(carol), 0, "auto-unwrap mints 0 wON post-upgrade");
        assertEq(on.balanceOf(carol), 30 ether, "carol got native ON post-upgrade");
        assertEq(won.ccipMintHeadroomUsed(), 1000 ether, "cap untouched by auto-unwrap");
        assertEq(on.balanceOf(address(won)), 20 ether, "reserve drained by auto-unwrap");

        // Post-upgrade CCIP mint (wON path): reserve (20) < 100 -> mints wON, cap grows.
        vm.prank(pool);
        won.mint(bob, 100 ether);
        assertEq(won.balanceOf(bob), 300 ether, "wON minted post-upgrade");
        assertEq(won.ccipMintHeadroomUsed(), 1100 ether, "cap consumed post-upgrade");

        // Supply: 1000 (alice) - 150 (withdraw) + 200 (bob deposit) + 100 (bob mint) = 1150.
        assertEq(won.totalSupply(), 1150 ether, "supply accounting consistent across upgrade");
    }

    /// @notice CCIP burn still decrements the cap counter and supply after an upgrade.
    function test_CcipBurnWorksAfterUpgrade() public {
        bytes32 burnerRole = won.BURNER_ROLE();
        vm.prank(admin);
        won.grantRole(burnerRole, pool);

        // Pre-upgrade mint to the pool so it holds wON to burn.
        vm.prank(pool);
        won.mint(pool, 500 ether);
        assertEq(won.ccipMintHeadroomUsed(), 500 ether);

        WrappedONV2Mock v2 = new WrappedONV2Mock();
        vm.prank(timelock);
        won.upgradeToAndCall(address(v2), "");

        // Post-upgrade burn decrements the cap counter and supply.
        vm.prank(pool);
        won.burn(200 ether);
        assertEq(won.ccipMintHeadroomUsed(), 300 ether, "burn decremented cap post-upgrade");
        assertEq(won.totalSupply(), 300 ether, "supply reduced post-upgrade");
    }

    /// @notice The emergency pause still halts the value paths after an upgrade.
    function test_PauseWorksAfterUpgrade() public {
        WrappedONV2Mock v2 = new WrappedONV2Mock();
        vm.prank(timelock);
        won.upgradeToAndCall(address(v2), "");

        vm.prank(admin); // admin holds PAUSER_ROLE
        won.pause();

        vm.prank(pool);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        won.mint(makeAddr("x"), 1 ether);
    }
}
