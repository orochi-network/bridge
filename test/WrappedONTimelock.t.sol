// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {WrappedON} from "../src/WrappedON.sol";
import {WrappedONV2Mock} from "./mocks/WrappedONV2Mock.sol";

/// @dev Minimal mock of the canonical ON token (non-mintable ERC20). Defined inline per
///      project convention — no standalone MockON file exists.
contract MockON is ERC20 {
    constructor() ERC20("Orochi Network", "ON") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract WrappedONTimelockTest is Test {
    MockON internal on;
    WrappedON internal won;
    TimelockController internal timelock;
    address internal multisig = makeAddr("multisig");
    uint256 internal constant DELAY = 172_800; // 48h

    function setUp() public {
        on = new MockON();
        address[] memory ms = new address[](1);
        ms[0] = multisig;
        // proposer+executor = multisig, no extra admin (admin = address(0) means no admin
        // after construction — the timelock self-administers via its own roles).
        timelock = new TimelockController(DELAY, ms, ms, address(0));
        WrappedON impl = new WrappedON();
        bytes memory data = abi.encodeCall(WrappedON.initialize, (IERC20(address(on)), multisig, address(timelock)));
        won = WrappedON(address(new ERC1967Proxy(address(impl), data)));
    }

    /// @notice An upgrade scheduled through the timelock goes through only after the delay.
    ///
    ///   1. multisig schedules upgradeToAndCall on the proxy.
    ///   2. Executing before the delay passes reverts.
    ///   3. After warping 48h + 1s the execute succeeds and version() returns 2.
    function test_UpgradeViaTimelockHappyPath() public {
        WrappedONV2Mock v2 = new WrappedONV2Mock();
        bytes memory call = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(v2), ""));
        bytes32 salt = bytes32(0);

        vm.prank(multisig);
        timelock.schedule(address(won), 0, call, bytes32(0), salt, DELAY);

        // Before the delay has elapsed: execute must revert.
        vm.prank(multisig);
        vm.expectRevert(); // TimelockController: operation is not ready
        timelock.execute(address(won), 0, call, bytes32(0), salt);

        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(multisig);
        timelock.execute(address(won), 0, call, bytes32(0), salt);

        assertEq(WrappedONV2Mock(address(won)).version(), 2, "upgrade applied after delay");
    }

    /// @notice Calling upgradeToAndCall directly from the multisig (which does NOT hold
    ///         UPGRADER_ROLE — the timelock does) must revert.
    function test_DirectUpgradeBypassingTimelockReverts() public {
        WrappedONV2Mock v2 = new WrappedONV2Mock();
        // Cache role before prank — won.UPGRADER_ROLE() is an external call that would
        // consume the vm.prank if called inside the expectRevert block.
        won.UPGRADER_ROLE();
        vm.prank(multisig); // multisig is NOT the UPGRADER — the timelock is
        vm.expectRevert();
        won.upgradeToAndCall(address(v2), "");
    }
}
