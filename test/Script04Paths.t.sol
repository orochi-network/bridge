// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {TokenAdminRegistry} from "@chainlink/contracts-ccip/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {
    RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";

import {RegisterAdminAndPool} from "../script/04_RegisterAdminAndPool.s.sol";

// ─── Harness ────────────────────────────────────────────────────────────────────

/// @dev Public test wrapper that exposes the script's internal `_registerAdmin`.
///
///      Note: when the harness invokes `module.registerAdminViaOwner`, the registry sees
///      msg.sender == harness, NOT broadcaster — so the SUCCESSFUL branches of
///      `_registerAdmin` cannot be observed through this exposer; the registry rejects
///      with `CanOnlySelfRegister`. In production the script uses `vm.startBroadcast`
///      which makes every external call originate from the deployer EOA directly. The
///      successful paths are tested in this file by calling the registry module directly
///      with `vm.prank(broadcaster)`; the harness is used only to exercise the failure-
///      mode dispatch (no admin path matches → `CannotResolveCCIPAdmin` revert).
contract RegisterAdminAndPoolHarness is RegisterAdminAndPool {
    function exposeRegisterAdmin(address token, address moduleAddr, address broadcaster) external {
        _registerAdmin(token, moduleAddr, broadcaster);
    }
}

// ─── Mock tokens covering each admin-discovery path ─────────────────────────────

contract OwnableOnlyToken is ERC20, Ownable {
    constructor(address owner_) ERC20("Ownable Only", "OWN") Ownable(owner_) {}
}

contract AccessControlOnlyToken is ERC20, AccessControl {
    constructor(address admin) ERC20("AccessControl Only", "ACO") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }
}

contract NoAdminPathToken is ERC20 {
    constructor() ERC20("No Path", "NOP") {}
}

contract AlwaysOtherCCIPAdmin {
    function getCCIPAdmin() external pure returns (address) {
        return address(0xDEAD);
    }
}

/// @notice Coverage for `script/04_RegisterAdminAndPool.s.sol` admin-discovery dispatch.
///         Closes SECURITY.md test coverage gaps [4] (neither-path revert) and [8]
///         (`registerAdminViaOwner` / `registerAccessControlDefaultAdmin` path coverage).
contract Script04PathsTest is Test {
    RegisterAdminAndPoolHarness internal harness;
    TokenAdminRegistry internal registry;
    RegistryModuleOwnerCustom internal module;
    address internal broadcaster = makeAddr("broadcaster");

    function setUp() public {
        harness = new RegisterAdminAndPoolHarness();
        registry = new TokenAdminRegistry();
        module = new RegistryModuleOwnerCustom(address(registry));
        registry.addRegistryModule(address(module));
    }

    // ─── Gap [4]: failure-mode dispatch ─────────────────────────────────────────

    /// @notice Bare ERC20 has no admin discovery surface — script must reach the final
    ///         revert path with `CannotResolveCCIPAdmin`.
    function test_RegisterAdmin_NeitherPathReverts() public {
        NoAdminPathToken token = new NoAdminPathToken();

        vm.prank(broadcaster);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegisterAdminAndPool.CannotResolveCCIPAdmin.selector,
                address(token),
                "broadcaster is neither getCCIPAdmin() nor Ownable.owner() nor AccessControl admin of token. Recovery: have the token's Ownable.owner call RegistryModuleOwnerCustom.registerAdminViaOwner(token) (permissionless for the owner), or coordinate with Chainlink to register the admin via the registry. proposeAdministrator on TokenAdminRegistry is NOT operator-callable - it is gated to registered registry modules / Chainlink."
            )
        );
        harness.exposeRegisterAdmin(address(token), address(module), broadcaster);
    }

    /// @notice `getCCIPAdmin()` is exposed but returns a non-broadcaster address — path 1
    ///         is entered but its `ccipAdmin == broadcaster` guard fails. With no Ownable
    ///         or AccessControl fallback, the script falls through to the final revert.
    ///         Exercises that the try/catch dispatch CHECKS each branch's condition rather
    ///         than just falling through on revert.
    function test_RegisterAdmin_GetCCIPAdminMismatchFallsThrough() public {
        AlwaysOtherCCIPAdmin token = new AlwaysOtherCCIPAdmin();

        vm.prank(broadcaster);
        vm.expectRevert(); // CannotResolveCCIPAdmin
        harness.exposeRegisterAdmin(address(token), address(module), broadcaster);
    }

    // ─── Gap [8] part 1: registerAdminViaOwner success path ──────────────────────

    /// @notice Drives `RegistryModuleOwnerCustom.registerAdminViaOwner` directly with
    ///         broadcaster as the token's `Ownable.owner` — the production path 2 of
    ///         `script 04` when the canonical BSC ON exposes `Ownable.owner` matching
    ///         the deployer EOA.
    function test_RegistryAccepts_RegisterAdminViaOwner() public {
        OwnableOnlyToken token = new OwnableOnlyToken(broadcaster);
        assertEq(token.owner(), broadcaster);

        vm.prank(broadcaster);
        module.registerAdminViaOwner(address(token));

        // Registry now lists broadcaster as the pending administrator for `token`.
        // The next step in script 04 (`acceptAdminRole`) is owner-callable; this test
        // exercises just the registration selector.
        assertEq(registry.getTokenConfig(address(token)).pendingAdministrator, broadcaster);
    }

    /// @notice `registerAdminViaOwner` reverts when caller isn't the token's owner.
    function test_RegistryRejects_RegisterAdminViaOwner_NotOwner() public {
        address otherOwner = makeAddr("otherOwner");
        OwnableOnlyToken token = new OwnableOnlyToken(otherOwner);

        vm.prank(broadcaster);
        vm.expectRevert(); // RegistryModuleOwnerCustom.CanOnlySelfRegister
        module.registerAdminViaOwner(address(token));
    }

    // ─── Gap [8] part 2: AccessControl path (registry v1.6 selector) ────────────

    /// @notice The vendored `RegistryModuleOwnerCustom` is v1.5.0 (matching the rest of
    ///         the pinned `lib/ccip @ v2.17.0-ccip1.5.16` codebase). The deployed registry
    ///         on ETH + BSC mainnet is v1.6.0 and exposes `registerAccessControlDefaultAdmin`;
    ///         script 04 invokes that selector via a local `IRegistryModuleOwnerCustom16`
    ///         interface, which the v1.5 vendored module does NOT recognise.
    ///
    ///         The script wraps the v1.6 selector call in its own try/catch so an operator
    ///         running against an unexpectedly v1.5 registry sees the clear path-4
    ///         `CannotResolveCCIPAdmin` revert rather than a bare empty revert from the
    ///         missing selector. This test pins that fall-through behaviour.
    ///
    ///         Successful path-3 execution against the live v1.6 registry is OUT OF SCOPE
    ///         of this unit test (would require either vendoring the v1.6 module or a
    ///         mock that implements `registerAccessControlDefaultAdmin`). Production fork
    ///         tests against ETH / BSC mainnet exercise that branch end-to-end.
    function test_RegisterAdmin_AccessControlPath_FallsThroughAgainstV15Module() public {
        AccessControlOnlyToken token = new AccessControlOnlyToken(broadcaster);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), broadcaster), "broadcaster holds DEFAULT_ADMIN_ROLE");

        vm.prank(broadcaster);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegisterAdminAndPool.CannotResolveCCIPAdmin.selector,
                address(token),
                "broadcaster is neither getCCIPAdmin() nor Ownable.owner() nor AccessControl admin of token. Recovery: have the token's Ownable.owner call RegistryModuleOwnerCustom.registerAdminViaOwner(token) (permissionless for the owner), or coordinate with Chainlink to register the admin via the registry. proposeAdministrator on TokenAdminRegistry is NOT operator-callable - it is gated to registered registry modules / Chainlink."
            )
        );
        harness.exposeRegisterAdmin(address(token), address(module), broadcaster);
    }
}
