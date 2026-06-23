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
        // The CCIP `mint` path always mints wON (it never reads the reserve — #48).
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

    /// @notice After a real upgrade, deposit/withdraw/CCIP-mint all still work and the reserve,
    ///         cap counter, and totalSupply stay consistent — integrating pre-upgrade state
    ///         (alice's CCIP-minted wON) with post-upgrade operations.
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

        // Post-upgrade CCIP mint with a covering reserve (50 >= 30): still mints wON (#48) —
        // never native ON. Reserve untouched, cap counter grows.
        vm.prank(pool);
        won.mint(carol, 30 ether);
        assertEq(won.balanceOf(carol), 30 ether, "carol got wON post-upgrade");
        assertEq(on.balanceOf(carol), 0, "carol got no native ON post-upgrade");
        assertEq(won.ccipMintHeadroomUsed(), 1030 ether, "cap consumed by mint");
        assertEq(on.balanceOf(address(won)), 50 ether, "reserve untouched by mint");

        // Post-upgrade CCIP mint again: reserve is irrelevant -> mints wON, cap grows.
        vm.prank(pool);
        won.mint(bob, 100 ether);
        assertEq(won.balanceOf(bob), 300 ether, "wON minted post-upgrade");
        assertEq(won.ccipMintHeadroomUsed(), 1130 ether, "cap consumed post-upgrade");

        // Supply: 1000 (alice) - 150 (withdraw) + 200 (bob deposit) + 30 (carol mint)
        //         + 100 (bob mint) = 1180.
        assertEq(won.totalSupply(), 1180 ether, "supply accounting consistent across upgrade");
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

    // ─── Raw storage-slot stability across upgrade ────────────────────────────
    // ERC-7201 namespacing makes the custom storage layout collision-proof by construction;
    // this test PROVES it by reading the raw slots with vm.load before and after a real
    // upgrade and asserting they are byte-identical — while the ERC1967 implementation slot
    // (which SHOULD move) confirms the upgrade actually happened.

    // Must equal `_STORAGE_LOCATION` in src/WrappedON.sol (cast index-erc7201 orochi.storage.WrappedON).
    bytes32 internal constant WON_STORAGE_BASE = 0xc9356e8aa19da270b9a132fda93e9af24668c8487450db15f9b9e8baeb751900;
    // ERC-1967 implementation slot = keccak256("eip1967.proxy.implementation") - 1.
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice Every custom (ERC-7201) storage slot is unchanged after an upgrade; only the
    ///         implementation pointer moves. Fields are laid out sequentially from the base:
    ///         [0]=ON, [1]=ccipMintHeadroomUsed, [2]=ccipAdmin, [3]=pendingCcipAdmin.
    function test_StorageSlotsUnchangedAfterUpgrade() public {
        // Populate every custom field with a non-zero value so the slot reads are meaningful.
        address alice = makeAddr("alice");
        address pendingAdmin = makeAddr("pendingAdmin");
        vm.prank(pool);
        won.mint(alice, 1234 ether); // ccipMintHeadroomUsed = 1234e18, ERC20 balance/supply set
        vm.prank(admin);
        won.setCCIPAdmin(pendingAdmin); // pendingCcipAdmin = pendingAdmin (ccipAdmin already = admin)

        bytes32 s0 = vm.load(address(won), WON_STORAGE_BASE);
        bytes32 s1 = vm.load(address(won), bytes32(uint256(WON_STORAGE_BASE) + 1));
        bytes32 s2 = vm.load(address(won), bytes32(uint256(WON_STORAGE_BASE) + 2));
        bytes32 s3 = vm.load(address(won), bytes32(uint256(WON_STORAGE_BASE) + 3));
        bytes32 implBefore = vm.load(address(won), ERC1967_IMPL_SLOT);

        // Guard against reading the wrong/empty slots (would make the equality checks vacuous).
        assertTrue(s0 != 0 && s1 != 0 && s2 != 0 && s3 != 0, "custom slots must be populated");
        assertTrue(implBefore != 0, "impl slot populated");

        WrappedONV2Mock v2 = new WrappedONV2Mock();
        vm.prank(timelock);
        won.upgradeToAndCall(address(v2), "");

        // Every custom storage slot is byte-identical after the upgrade.
        assertEq(vm.load(address(won), WON_STORAGE_BASE), s0, "ON slot moved");
        assertEq(vm.load(address(won), bytes32(uint256(WON_STORAGE_BASE) + 1)), s1, "headroom slot moved");
        assertEq(vm.load(address(won), bytes32(uint256(WON_STORAGE_BASE) + 2)), s2, "ccipAdmin slot moved");
        assertEq(vm.load(address(won), bytes32(uint256(WON_STORAGE_BASE) + 3)), s3, "pendingCcipAdmin slot moved");

        // Cross-check the namespaced getters still resolve to the same data.
        assertEq(address(won.ON()), address(on), "ON value preserved");
        assertEq(won.ccipMintHeadroomUsed(), 1234 ether, "headroom value preserved");
        assertEq(won.getCCIPAdmin(), admin, "ccipAdmin value preserved");
        assertEq(won.pendingCCIPAdmin(), pendingAdmin, "pendingCcipAdmin value preserved");

        // The implementation slot DID change — proves a real upgrade, not a no-op.
        bytes32 implAfter = vm.load(address(won), ERC1967_IMPL_SLOT);
        assertTrue(implBefore != implAfter, "impl slot must change on upgrade");
        assertEq(address(uint160(uint256(implAfter))), address(v2), "impl slot points to V2");
    }
}
