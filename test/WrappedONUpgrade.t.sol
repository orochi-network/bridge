// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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
}
