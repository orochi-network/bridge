// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {RenounceDeployerAdmin} from "../script/06_TransferOwnership.s.sol";
import {WrappedON} from "../src/WrappedON.sol";
import {DeployWON} from "./helpers/DeployWON.sol";

// ─── Fixtures ───────────────────────────────────────────────────────────────────

/// @dev Mirrors the canonical ON ERC20 (18 decimals, non-mintable from the wON ctor's POV).
contract MockON is ERC20 {
    constructor() ERC20("Orochi Network", "ON") {}
}

/// @dev Minimal Ownable surface — only `owner()`. The script's
///      `_assertReadyToRenounce` reads pool ownership via a raw staticcall to `owner()`,
///      so any contract with that selector works.
contract MockOwnedPool {
    address public owner;

    function setOwner(address o) external {
        owner = o;
    }
}

/// @dev Minimal TokenAdminRegistry surface — only `getTokenConfig(address)`.
///      The script reads `administrator` (offset 0 of the returned `TokenConfig` struct).
///      `pendingAdministrator` and `tokenPool` are also returned to match the real ABI
///      shape (96-byte static struct).
contract MockRegistry {
    struct TokenConfig {
        address administrator;
        address pendingAdministrator;
        address tokenPool;
    }

    mapping(address => TokenConfig) internal _configs;

    function setAdministrator(address token, address admin) external {
        _configs[token].administrator = admin;
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return _configs[token];
    }
}

/// @dev Public test wrapper that exposes the script's internal `_assertReadyToRenounce`.
contract RenounceDeployerAdminHarness is RenounceDeployerAdmin {
    function exposeAssertReadyToRenounce(
        WrappedON won,
        address multisig,
        address deployer,
        address pool,
        address registry,
        address timelock
    ) external view {
        _assertReadyToRenounce(won, multisig, deployer, pool, registry, timelock);
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────────

/// @notice Locks every branch of `RenounceDeployerAdmin._assertReadyToRenounce` — the
///         pre-broadcast safety checks added in R-34 (and refactored out of `run()` in
///         round-4 review [1] for test access). A regression dropping any of these
///         `require`s would silently land — `test_E2E_OwnershipHandoff` bypasses the
///         script entirely (it calls `won.renounceRole(...)` directly via `vm.prank`).
///
///         The harness lets tests drive each branch without spinning up a full
///         `deployments/<chainId>.json` fixture, since the dependencies are now passed
///         in rather than looked up.
contract Script06RenounceTest is Test {
    RenounceDeployerAdminHarness internal harness;
    WrappedON internal won;
    MockON internal onToken;
    MockOwnedPool internal pool;
    MockRegistry internal registry;
    TimelockController internal timelock;

    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");

    function setUp() public {
        harness = new RenounceDeployerAdminHarness();
        onToken = new MockON();

        // Deploy wON with the deployer as admin so DEFAULT_ADMIN_ROLE + ccipAdmin start with deployer.
        won = DeployWON.deploy(IERC20(address(onToken)), deployer, deployer);

        pool = new MockOwnedPool();
        registry = new MockRegistry();

        // Timelock mirroring fixed script 01 (DEP-24): the deployer is the SETUP admin
        // (`admin = deployer`) AND the initial proposer/executor/canceller. It can hand the
        // operational roles to the multisig below precisely because it holds the timelock's
        // DEFAULT_ADMIN_ROLE — the bug this fix closes was script 01 passing `address(0)`,
        // which left the deployer unable to grant anything.
        address[] memory props = new address[](1);
        props[0] = deployer;
        timelock = new TimelockController(0, props, props, deployer);

        // Default state for the happy path: full handoff complete.
        // wON: multisig has DEFAULT_ADMIN_ROLE + PAUSER_ROLE; multisig is the ccipAdmin.
        // Timelock: multisig holds all three handed-off roles. All granted by the deployer
        // (the setup admin), exactly as script 06 `_handoff` does.
        vm.startPrank(deployer);
        won.grantRole(won.DEFAULT_ADMIN_ROLE(), multisig);
        won.grantRole(won.PAUSER_ROLE(), multisig);
        won.setCCIPAdmin(multisig); // proposes
        timelock.grantRole(timelock.PROPOSER_ROLE(), multisig);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), multisig);
        timelock.grantRole(timelock.CANCELLER_ROLE(), multisig);
        vm.stopPrank();
        vm.prank(multisig);
        won.acceptCCIPAdmin();

        // Pool ownership: multisig.
        pool.setOwner(multisig);

        // Registry administrator: multisig.
        registry.setAdministrator(address(won), multisig);
    }

    function _call() internal view {
        harness.exposeAssertReadyToRenounce(
            won, multisig, deployer, address(pool), address(registry), address(timelock)
        );
    }

    // ─── Happy path ─────────────────────────────────────────────────────────────

    function test_PassesWhenHandoffComplete() public view {
        _call();
    }

    // ─── wON role / ccipAdmin failures ──────────────────────────────────────────

    function test_RevertsWhenDeployerLacksAdminRole() public {
        // Renounce on the deployer first so `hasRole(adminRole, deployer)` is false.
        // Pre-read the role constant so the `vm.prank` is consumed by the next state
        // change (`renounceRole`) rather than by an intervening view call.
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
        vm.prank(deployer);
        won.renounceRole(adminRole, deployer);

        vm.expectRevert(bytes("deployer does not hold admin role"));
        _call();
    }

    function test_RevertsWhenMultisigLacksAdminRole() public {
        // Revoke the multisig grant set up in setUp.
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
        vm.prank(deployer);
        won.revokeRole(adminRole, multisig);

        vm.expectRevert(bytes("multisig does NOT hold admin role yet"));
        _call();
    }

    function test_RevertsWhenCcipAdminNotAccepted() public {
        // Re-propose ccipAdmin to a different address so getCCIPAdmin() != multisig.
        address newProposed = makeAddr("newProposed");
        vm.prank(multisig);
        won.setCCIPAdmin(newProposed); // multisig still ccipAdmin, but pending is now newProposed
        vm.prank(newProposed);
        won.acceptCCIPAdmin();

        vm.expectRevert(bytes("wON ccipAdmin not yet accepted by multisig"));
        _call();
    }

    function test_RevertsWhenMultisigLacksPauserRole() public {
        // Revoke the PAUSER_ROLE grant set up in setUp.
        bytes32 pauserRole = won.PAUSER_ROLE();
        vm.prank(deployer);
        won.revokeRole(pauserRole, multisig);

        vm.expectRevert(bytes("multisig does NOT hold PAUSER_ROLE yet"));
        _call();
    }

    // ─── Timelock-role lockout guard ─────────────────────────────────────────────

    /// @notice LOCKOUT GUARD: once the deployer renounces its setup-admin (DEP-24), the
    ///         timelock is self-administered and can only gain proposer/executor via a
    ///         timelocked proposal. If the deployer renounces its roles while the multisig
    ///         lacks them, the upgrade path is PERMANENTLY locked. `_assertReadyToRenounce`
    ///         must block this. Revoking the multisig's PROPOSER_ROLE (set up in setUp) must
    ///         surface the typed message rather than letting the renounce proceed.
    function test_RevertsWhenMultisigLacksTimelockRoles() public {
        // Revoke the multisig's PROPOSER_ROLE. Granted/revoked by the deployer (setup admin).
        // Cache the role constant first so the external `PROPOSER_ROLE()` view doesn't consume
        // the `vm.prank`.
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.prank(deployer);
        timelock.revokeRole(proposerRole, multisig);

        vm.expectRevert(bytes("multisig does NOT hold timelock PROPOSER_ROLE yet (re-run TransferOwnership)"));
        _call();
    }

    /// @notice The lockout guard is skipped when no timelock address is supplied (mirrors
    ///         the script's `timelock != address(0)` guard). Even with the multisig lacking
    ///         every timelock role, passing `address(0)` must let the wON-only checks pass.
    function test_PassesWhenTimelockAddressZero() public {
        vm.startPrank(deployer);
        timelock.revokeRole(timelock.PROPOSER_ROLE(), multisig);
        timelock.revokeRole(timelock.EXECUTOR_ROLE(), multisig);
        timelock.revokeRole(timelock.CANCELLER_ROLE(), multisig);
        vm.stopPrank();

        // Passing address(0) for the timelock skips the lockout guard entirely.
        harness.exposeAssertReadyToRenounce(won, multisig, deployer, address(pool), address(registry), address(0));
    }

    // ─── Pool ownership failures ────────────────────────────────────────────────

    function test_RevertsWhenPoolAddressMissing() public {
        vm.expectRevert(bytes("pool address not recorded in deployments JSON"));
        harness.exposeAssertReadyToRenounce(won, multisig, deployer, address(0), address(registry), address(timelock));
    }

    function test_RevertsWhenPoolOwnerNotMultisig() public {
        pool.setOwner(deployer);

        vm.expectRevert(bytes("pool ownership NOT accepted by multisig (call acceptOwnership first)"));
        _call();
    }

    // ─── Registry admin failures ────────────────────────────────────────────────

    function test_RevertsWhenRegistryAdminNotMultisig() public {
        registry.setAdministrator(address(won), deployer);

        vm.expectRevert(bytes("registry adminRole NOT accepted by multisig (call acceptAdminRole first)"));
        _call();
    }
}

/// @notice DEP-24 regression: the timelock-role HANDOFF itself must work. Fixed script 01
///         deploys the `TimelockController` with `admin = deployer`, so the deployer can grant
///         PROPOSER/EXECUTOR/CANCELLER to the multisig (script 06 `_handoff`) and then renounce
///         all its own roles incl. the setup-admin (RenounceDeployerAdmin). The previous code
///         deployed it self-administered (`admin = address(0)`), under which the deployer holds
///         PROPOSER but NOT DEFAULT_ADMIN, so the grant REVERTS `AccessControlUnauthorizedAccount`
///         — a deployment-blocking bug that the `_assertReadyToRenounce` fixtures masked by using
///         `admin = address(this)`. These tests exercise the exact OZ calls in script-01/06 order.
contract Script06TimelockHandoffTest is Test {
    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");

    /// @notice Fixed model: the deployer hands off the operational roles and fully retires.
    function test_HandoffAndRenounceSucceeds() public {
        address[] memory props = new address[](1);
        props[0] = deployer;
        vm.prank(deployer);
        TimelockController tl = new TimelockController(172_800, props, props, deployer); // admin = deployer

        bytes32 prop = tl.PROPOSER_ROLE();
        bytes32 exec = tl.EXECUTOR_ROLE();
        bytes32 canc = tl.CANCELLER_ROLE();
        bytes32 admin = tl.DEFAULT_ADMIN_ROLE();

        vm.startPrank(deployer);
        // script 06 _handoff: deployer grants the operational roles to the multisig.
        tl.grantRole(prop, multisig);
        tl.grantRole(exec, multisig);
        tl.grantRole(canc, multisig);
        // RenounceDeployerAdmin: deployer renounces all its roles incl. the setup-admin.
        tl.renounceRole(prop, deployer);
        tl.renounceRole(exec, deployer);
        tl.renounceRole(canc, deployer);
        tl.renounceRole(admin, deployer);
        vm.stopPrank();

        // End state: multisig holds the operational roles; deployer holds nothing; the
        // timelock self-administers (only it retains DEFAULT_ADMIN_ROLE).
        assertTrue(tl.hasRole(prop, multisig) && tl.hasRole(exec, multisig) && tl.hasRole(canc, multisig));
        assertFalse(tl.hasRole(prop, deployer) || tl.hasRole(exec, deployer) || tl.hasRole(canc, deployer));
        assertFalse(tl.hasRole(admin, deployer), "deployer renounced setup-admin");
        assertTrue(tl.hasRole(admin, address(tl)), "timelock self-administers");
    }

    /// @notice The bug, locked in: under the OLD self-administered deploy (`admin = address(0)`)
    ///         the deployer cannot grant the timelock roles — the handoff reverts.
    function test_OldSelfAdministeredDeploy_HandoffReverts() public {
        address[] memory props = new address[](1);
        props[0] = deployer;
        TimelockController tl = new TimelockController(172_800, props, props, address(0)); // OLD model
        // Cache the role so the external view doesn't consume the prank/expectRevert.
        bytes32 proposerRole = tl.PROPOSER_ROLE();

        vm.prank(deployer);
        vm.expectRevert(); // AccessControlUnauthorizedAccount(deployer, DEFAULT_ADMIN_ROLE)
        tl.grantRole(proposerRole, multisig);
    }
}
