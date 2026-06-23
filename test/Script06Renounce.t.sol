// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        address registry
    ) external view {
        _assertReadyToRenounce(won, multisig, deployer, pool, registry);
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

    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");

    function setUp() public {
        harness = new RenounceDeployerAdminHarness();
        onToken = new MockON();

        // Deploy wON with the deployer as admin so DEFAULT_ADMIN_ROLE + ccipAdmin start with deployer.
        won = DeployWON.deploy(IERC20(address(onToken)), deployer, deployer);

        pool = new MockOwnedPool();
        registry = new MockRegistry();

        // Default state for the happy path: full handoff complete.
        // wON: multisig has DEFAULT_ADMIN_ROLE; multisig is the ccipAdmin.
        vm.startPrank(deployer);
        won.grantRole(won.DEFAULT_ADMIN_ROLE(), multisig);
        won.setCCIPAdmin(multisig); // proposes
        vm.stopPrank();
        vm.prank(multisig);
        won.acceptCCIPAdmin();

        // Pool ownership: multisig.
        pool.setOwner(multisig);

        // Registry administrator: multisig.
        registry.setAdministrator(address(won), multisig);
    }

    function _call() internal view {
        harness.exposeAssertReadyToRenounce(won, multisig, deployer, address(pool), address(registry));
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

    // ─── Pool ownership failures ────────────────────────────────────────────────

    function test_RevertsWhenPoolAddressMissing() public {
        vm.expectRevert(bytes("pool address not recorded in deployments JSON"));
        harness.exposeAssertReadyToRenounce(won, multisig, deployer, address(0), address(registry));
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
