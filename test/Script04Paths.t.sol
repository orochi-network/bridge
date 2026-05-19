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
///      Note on msg.sender: when the harness invokes the production
///      `RegistryModuleOwnerCustom`, msg.sender into the module is the harness contract,
///      not the broadcaster. In production the script wraps the call in `vm.startBroadcast`
///      which forwards every external call from the deployer EOA. The successful-dispatch
///      tests below decouple this by swapping in `MockRecordingModule` (records which
///      function the script chose, with no msg.sender check) — so they test the
///      dispatch logic, not the module's permission checks. The production module's
///      msg.sender checks have their own `_RegistryAccepts_` / `_RegistryRejects_`
///      coverage further down.
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

contract GetCCIPAdminTokenConfigurable is ERC20 {
    address public immutable ADMIN;

    constructor(address admin_) ERC20("getCCIPAdmin", "GCA") {
        ADMIN = admin_;
    }

    function getCCIPAdmin() external view returns (address) {
        return ADMIN;
    }
}

/// @dev Records the last registration selector invoked, so dispatch tests can assert
///      script 04 reached the right branch. Has no permission checks — decouples
///      dispatch verification from the production module's msg.sender requirement.
contract MockRecordingModule {
    bytes32 public lastSelector;
    address public lastToken;

    function registerAdminViaGetCCIPAdmin(address token) external {
        lastSelector = keccak256("registerAdminViaGetCCIPAdmin");
        lastToken = token;
    }

    function registerAdminViaOwner(address token) external {
        lastSelector = keccak256("registerAdminViaOwner");
        lastToken = token;
    }

    function registerAccessControlDefaultAdmin(address token) external {
        lastSelector = keccak256("registerAccessControlDefaultAdmin");
        lastToken = token;
    }
}

/// @dev Mock module whose v1.6 entrypoint reverts with a structured error — used to
///      verify that script 04's inner try/catch propagates legitimate v1.6 reverts
///      rather than swallowing them under `CannotResolveCCIPAdmin`. Round-3 review [7].
contract MockRevertingModuleV16 {
    error V16Failed(string reason);

    function registerAccessControlDefaultAdmin(address) external pure {
        revert V16Failed("token already registered with different admin");
    }
}

/// @dev Mock module whose v1.6 entrypoint does a bare `revert();` with no reason data.
///      TEST-13: the script's path-3 inner try/catch uses `reason.length != 0` to
///      distinguish a missing-selector revert (an unexpectedly-v1.5 registry) from a
///      structured v1.6 revert that should propagate. A module that explicitly silent-
///      reverts looks identical to a missing selector at the call site — pin this
///      fall-through behaviour with a dedicated mock so an inversion of the
///      `reason.length != 0` branch (e.g. dropping the `!= 0` check) is caught.
contract MockSilentRevertModule {
    function registerAccessControlDefaultAdmin(address) external pure {
        assembly {
            revert(0, 0)
        }
    }
}

/// @dev Minimal stand-in for `RegistryModuleOwnerCustom` v1.6 — implements the
///      `registerAccessControlDefaultAdmin` selector that's missing in the v1.5 vendored
///      module. Verifies AccessControl on the token, then proposes the caller as
///      administrator through the registry. Mirrors the production v1.6 contract closely
///      enough to lock the call shape script 04 depends on.
interface IAccessControlRead {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface ITokenAdminRegistryProposer {
    function proposeAdministrator(address localToken, address administrator) external;
}

contract MockRegistryModuleV16 {
    error CanOnlySelfRegister(address actual, address expected);

    address public immutable REGISTRY;

    constructor(address registry_) {
        REGISTRY = registry_;
    }

    function registerAccessControlDefaultAdmin(address token) external {
        if (!IAccessControlRead(token).hasRole(0x00, msg.sender)) {
            revert CanOnlySelfRegister(msg.sender, address(0));
        }
        ITokenAdminRegistryProposer(REGISTRY).proposeAdministrator(token, msg.sender);
    }
}

/// @notice Coverage for `script/04_RegisterAdminAndPool.s.sol` admin-discovery dispatch.
///         Exercises the neither-path revert plus the `registerAdminViaOwner` /
///         `registerAccessControlDefaultAdmin` paths.
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
    ///         SECURITY: TEST-3 — typed selector check (full payload tested in the
    ///         NeitherPath sibling).
    function test_RegisterAdmin_GetCCIPAdminMismatchFallsThrough() public {
        AlwaysOtherCCIPAdmin token = new AlwaysOtherCCIPAdmin();

        vm.prank(broadcaster);
        vm.expectPartialRevert(RegisterAdminAndPool.CannotResolveCCIPAdmin.selector);
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

    /// @notice The success path for AccessControl-based registration, simulated against
    ///         a v1.6-shaped module (`MockRegistryModuleV16`). Mirrors what happens on
    ///         ETH/BSC mainnet against the deployed v1.6 RegistryModuleOwnerCustom.
    ///         Locks the call shape the script depends on (`hasRole(0x00, broadcaster)`
    ///         then `registerAccessControlDefaultAdmin(token)` invoked from the broadcaster
    ///         EOA).
    function test_RegistryAccepts_RegisterAccessControlDefaultAdmin() public {
        // Set up a separate registry that recognises a v1.6-shaped module, so we can
        // call `proposeAdministrator` from the module legally.
        TokenAdminRegistry registry16 = new TokenAdminRegistry();
        MockRegistryModuleV16 mockModule = new MockRegistryModuleV16(address(registry16));
        registry16.addRegistryModule(address(mockModule));

        AccessControlOnlyToken token = new AccessControlOnlyToken(broadcaster);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), broadcaster));

        // Direct call from broadcaster — same shape the production script issues against
        // the live v1.6 registry. msg.sender = broadcaster, and broadcaster holds the
        // DEFAULT_ADMIN_ROLE on `token`.
        vm.prank(broadcaster);
        mockModule.registerAccessControlDefaultAdmin(address(token));

        // Registry now lists broadcaster as the pending administrator.
        assertEq(registry16.getTokenConfig(address(token)).pendingAdministrator, broadcaster);
    }

    /// @notice `registerAccessControlDefaultAdmin` reverts when caller doesn't hold
    ///         `DEFAULT_ADMIN_ROLE` on the token. Mirrors the v1.6 access guard.
    function test_RegistryRejects_RegisterAccessControlDefaultAdmin_NotAdmin() public {
        TokenAdminRegistry registry16 = new TokenAdminRegistry();
        MockRegistryModuleV16 mockModule = new MockRegistryModuleV16(address(registry16));
        registry16.addRegistryModule(address(mockModule));

        address otherAdmin = makeAddr("otherAdmin");
        AccessControlOnlyToken token = new AccessControlOnlyToken(otherAdmin);

        vm.prank(broadcaster);
        vm.expectRevert(); // CanOnlySelfRegister
        mockModule.registerAccessControlDefaultAdmin(address(token));
    }

    // ─── Round-3 review [4]: dispatch tests through the harness ─────────────────
    // These tests verify which selector script 04's `_registerAdmin` calls on the
    // module for each path's success branch. They use `MockRecordingModule` so
    // there is no msg.sender check standing between the dispatch and the
    // observation. The production module's msg.sender requirements are tested
    // separately by the `_RegistryAccepts_` / `_RegistryRejects_` tests above.

    /// @notice Path 1 success: token exposes `getCCIPAdmin()` returning broadcaster.
    ///         Script must call `registerAdminViaGetCCIPAdmin(token)`.
    function test_Dispatch_Path1_GetCCIPAdmin_CallsRegisterAdminViaGetCCIPAdmin() public {
        GetCCIPAdminTokenConfigurable token = new GetCCIPAdminTokenConfigurable(broadcaster);
        MockRecordingModule mockModule = new MockRecordingModule();

        harness.exposeRegisterAdmin(address(token), address(mockModule), broadcaster);

        assertEq(mockModule.lastSelector(), keccak256("registerAdminViaGetCCIPAdmin"), "wrong selector dispatched");
        assertEq(mockModule.lastToken(), address(token), "wrong token passed");
    }

    /// @notice Path 2 success: token exposes `Ownable.owner()` returning broadcaster
    ///         (no `getCCIPAdmin()`). Script must call `registerAdminViaOwner(token)`.
    function test_Dispatch_Path2_Ownable_CallsRegisterAdminViaOwner() public {
        OwnableOnlyToken token = new OwnableOnlyToken(broadcaster);
        MockRecordingModule mockModule = new MockRecordingModule();

        harness.exposeRegisterAdmin(address(token), address(mockModule), broadcaster);

        assertEq(mockModule.lastSelector(), keccak256("registerAdminViaOwner"), "wrong selector dispatched");
        assertEq(mockModule.lastToken(), address(token), "wrong token passed");
    }

    /// @notice Path 3 success: token exposes `AccessControl.hasRole(0x00, broadcaster)`
    ///         (no `getCCIPAdmin`, no `Ownable.owner`). Script must call the v1.6
    ///         `registerAccessControlDefaultAdmin(token)` selector.
    function test_Dispatch_Path3_AccessControl_CallsRegisterAccessControlDefaultAdmin() public {
        AccessControlOnlyToken token = new AccessControlOnlyToken(broadcaster);
        MockRecordingModule mockModule = new MockRecordingModule();

        harness.exposeRegisterAdmin(address(token), address(mockModule), broadcaster);

        assertEq(mockModule.lastSelector(), keccak256("registerAccessControlDefaultAdmin"), "wrong selector dispatched");
        assertEq(mockModule.lastToken(), address(token), "wrong token passed");
    }

    /// @notice Path 3 with a structured-revert from the v1.6 entrypoint: script 04 must
    ///         PROPAGATE the revert rather than swallow it under `CannotResolveCCIPAdmin`.
    ///         Round-3 review [7] — the inner `catch (bytes memory reason) { … }` only
    ///         falls through when `reason.length == 0` (the empty-revert signature of a
    ///         missing selector on a v1.5 registry); any structured revert (token already
    ///         registered, paused, AccessControl re-check failure) surfaces with its
    ///         original reason so operators see the real cause.
    function test_Dispatch_Path3_StructuredRevertPropagates() public {
        AccessControlOnlyToken token = new AccessControlOnlyToken(broadcaster);
        MockRevertingModuleV16 mockModule = new MockRevertingModuleV16();

        vm.expectRevert(
            abi.encodeWithSelector(
                MockRevertingModuleV16.V16Failed.selector, "token already registered with different admin"
            )
        );
        harness.exposeRegisterAdmin(address(token), address(mockModule), broadcaster);
    }

    /// @notice TEST-13: a module that bare-`revert();`s from `registerAccessControlDefaultAdmin`
    ///         is indistinguishable at the call site from a missing-selector revert against an
    ///         unexpectedly-v1.5 registry — both return empty reason data. The script's path-3
    ///         try/catch must fall through to the path-4 `CannotResolveCCIPAdmin` diagnostic
    ///         rather than propagate (because there is no structured reason to surface).
    ///         Inverting the `reason.length != 0` check in script 04 would also fall through
    ///         silently on a real structured revert — `test_Dispatch_Path3_StructuredRevertPropagates`
    ///         and this test together box that branch on both sides.
    function test_Dispatch_Path3_SilentRevertFallsThrough() public {
        AccessControlOnlyToken token = new AccessControlOnlyToken(broadcaster);
        MockSilentRevertModule mockModule = new MockSilentRevertModule();

        vm.expectPartialRevert(RegisterAdminAndPool.CannotResolveCCIPAdmin.selector);
        harness.exposeRegisterAdmin(address(token), address(mockModule), broadcaster);
    }
}
