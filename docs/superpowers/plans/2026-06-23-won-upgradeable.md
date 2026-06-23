# Upgradeable wON Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `WrappedON` upgradeable behind a UUPS proxy at a stable address, with upgrades gated by a 48h `TimelockController` and an emergency multisig pause on the value paths — preserving all existing wON behavior.

**Architecture:** `ERC1967Proxy` (registered address) → `WrappedON` UUPS implementation. `_authorizeUpgrade` is gated to `UPGRADER_ROLE` (held by the timelock); `PAUSER_ROLE` (multisig) can pause `mint`/`burn`/`deposit`/`withdraw`. Custom state moves to ERC-7201 namespaced storage; `constructor` → `initialize`.

**Tech Stack:** Foundry, Solidity 0.8.34 (evm_version cancun), OpenZeppelin 5.6.1 (contracts + contracts-upgradeable), Chainlink CCIP 1.6.1.

## Global Constraints

- Solidity `0.8.34`, optimizer 200, `evm_version = cancun`.
- OZ pins: `openzeppelin-contracts` AND `openzeppelin-contracts-upgradeable` both at **v5.6.1** (exact tag).
- UUPS proxy (`ERC1967Proxy` + `UUPSUpgradeable`); NOT transparent/beacon.
- Upgrade auth: `_authorizeUpgrade` `onlyRole(UPGRADER_ROLE)`; `UPGRADER_ROLE` granted to the `TimelockController` (minDelay 48h = `172800` seconds; proposers/cancellers/executor = ops multisig).
- `PAUSER_ROLE` (multisig) pauses ONLY `mint`, `burn(uint256)`, `burn(address,uint256)`, `burnFrom`, `deposit`, `withdraw`. ERC20 `transfer`/`transferFrom` are NOT paused.
- `ON` is stored (ERC-7201), set once in `initialize`, never settable again. NOT `immutable`.
- Preserve the existing public ABI: `ON()`, `ccipMintHeadroomUsed()`, `getCCIPAdmin()`, `pendingCCIPAdmin()`, `MINTER_ROLE()`, `BURNER_ROLE()`, `MAX_CCIP_MINTED()`, all events/errors, and the auto-unwrap / permissionless-deposit / CCIP-admin-two-step semantics — unchanged.
- Implementation `constructor()` calls `_disableInitializers()`.
- No Claude attribution in commits. Run `make fmt` before each commit; `make test` green at each task end.
- Rides the pending redeploy (clean, pre-launch — no state migration).

---

## File structure

- `lib/openzeppelin-contracts-upgradeable/` — new submodule (v5.6.1).
- `foundry.toml` — add the `@openzeppelin/contracts-upgradeable/` remapping.
- `src/WrappedON.sol` — rewritten as the UUPS implementation.
- `test/helpers/DeployWON.sol` — shared helper: deploy timelock + impl + proxy, return `WrappedON`.
- `test/WrappedON.t.sol`, `test/WrappedONInvariant.t.sol`, `test/PoolRoundtrip.t.sol`, `test/DeploymentE2E.t.sol`, `test/Script06Renounce.t.sol`, `test/Script08Verify.t.sol`, `test/fork/Fork_ETH.t.sol`, `test/fork/Fork_Bridge.t.sol` — migrate construction to the proxy helper.
- `test/WrappedONUpgrade.t.sol` — NEW: upgrade + initializer + `_authorizeUpgrade` tests.
- `test/WrappedONPause.t.sol` — NEW: pause behavior tests.
- `test/WrappedONTimelock.t.sol` — NEW: timelock-gated upgrade flow.
- `test/mocks/WrappedONV2Mock.sol` — NEW: a trivial V2 implementation for upgrade tests.
- `script/01_DeployWrappedON.s.sol` — deploy timelock + impl + proxy.
- `script/06_TransferOwnership.s.sol` — hand off timelock/pause authority.
- Docs: `CLAUDE.md`, `docs/ARCHITECTURE.md`, `README.md`, `RUNBOOK.md`, `SECURITY.md`, `STATE.md`.

---

## Task 1: Add the OZ-upgradeable dependency + remapping

**Files:** `.gitmodules`, `lib/openzeppelin-contracts-upgradeable/` (submodule), `foundry.toml`

- [ ] **Step 1: Add the submodule pinned to v5.6.1**

```bash
git submodule add https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable lib/openzeppelin-contracts-upgradeable
cd lib/openzeppelin-contracts-upgradeable && git checkout v5.6.1 && cd ../..
git submodule update --init --recursive
```

- [ ] **Step 2: Add the remapping**

Find the remappings block in `foundry.toml` (it contains `"@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/"`). Add alongside it:
```
"@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/",
```

- [ ] **Step 3: Verify the needed contracts exist**

Run:
```bash
for f in token/ERC20/ERC20Upgradeable access/AccessControlUpgradeable utils/PausableUpgradeable \
  utils/ReentrancyGuardTransientUpgradeable proxy/utils/Initializable proxy/utils/UUPSUpgradeable; do
  ls lib/openzeppelin-contracts-upgradeable/contracts/$f.sol 2>/dev/null || echo "MISSING: $f"
done
```
Expected: all present. If `ReentrancyGuardTransientUpgradeable` is MISSING, note it — Task 2 will instead inherit the non-upgradeable `ReentrancyGuardTransient` (its guard uses a constant transient slot, no storage/init, so it is safe in an upgradeable contract) and skip its `__init`.

- [ ] **Step 4: Build (existing code unaffected)**

Run: `forge build`
Expected: compiles (no source changed yet). Then run `make patch-pragmas` (harmless; keeps the lib pragma convention).

- [ ] **Step 5: Commit**

```bash
git add .gitmodules lib/openzeppelin-contracts-upgradeable foundry.toml
git commit -m "build: add openzeppelin-contracts-upgradeable v5.6.1 + remapping"
```

---

## Task 2: Rewrite WrappedON as a UUPS implementation + migrate the test harness

This is the core task. It MUST end with `make test` green — the whole project compiles, so the contract rewrite and every `new WrappedON(...)` call site change together.

**Files:**
- Modify: `src/WrappedON.sol`
- Create: `test/helpers/DeployWON.sol`
- Modify: all test files listed in File structure + `script/01` is handled in Task 6 (here, only make the contract+tests compile; script 01 still does `new WrappedON(...)` which will NOT compile — so ALSO update script 01's construction in this task minimally, OR temporarily; see Step 5).

**Interfaces:**
- Produces: `WrappedON.initialize(IERC20 onToken, address admin, address timelock)`; public getters `ON() returns (IERC20)`, `ccipMintHeadroomUsed() returns (uint256)`; roles `UPGRADER_ROLE`, `PAUSER_ROLE`; `pause()`/`unpause()`.
- Produces (test helper): `DeployWON.deployWON(IERC20 on, address admin) returns (WrappedON won, address timelock)` and `deployWON(IERC20 on, address admin, address timelock)`.

- [ ] **Step 1: Compute the ERC-7201 storage location constant**

Run:
```bash
cast index-erc7201 orochi.storage.WrappedON 2>/dev/null \
  || cast keccak "$(cast --to-uint256 $(cast keccak "orochi.storage.WrappedON") | ...)"  # fallback below
```
If `cast index-erc7201` is unavailable, compute it explicitly:
```bash
# slot = keccak256(abi.encode(uint256(keccak256("orochi.storage.WrappedON")) - 1)) & ~0xff
python3 - <<'PY'
from eth_utils import keccak
from eth_abi import encode
inner = int.from_bytes(keccak(text="orochi.storage.WrappedON"), "big") - 1
slot = keccak(encode(["uint256"], [inner]))
slot = bytes(a & b for a, b in zip(slot, (b"\xff"*31 + b"\x00")))
print("0x" + slot.hex())
PY
```
Record the printed `0x…` value; it becomes `_STORAGE_LOCATION` below.

- [ ] **Step 2: Rewrite `src/WrappedON.sol` — scaffolding**

Replace the imports (lines 4-14) and the contract declaration/state/constructor with the upgradeable form. Imports:
```solidity
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/interfaces/IGetCCIPAdmin.sol";
```
(If Task 1 Step 3 found `ReentrancyGuardTransientUpgradeable` missing, import `ReentrancyGuardTransient` from `@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol` instead and adjust the inheritance + skip its init below.)

Contract head, roles, constants, ERC-7201 storage, getters:
```solidity
contract WrappedON is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    UUPSUpgradeable,
    IGetCCIPAdmin
{
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant MAX_CCIP_MINTED = 100_000_000 ether;

    /// @custom:storage-location erc7201:orochi.storage.WrappedON
    struct WrappedONStorage {
        IERC20 on;
        uint256 ccipMintHeadroomUsed;
        address ccipAdmin;
        address pendingCcipAdmin;
    }

    // = keccak256(abi.encode(uint256(keccak256("orochi.storage.WrappedON")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_LOCATION = <0x… from Step 1>;

    function _s() private pure returns (WrappedONStorage storage $) {
        assembly { $.slot := _STORAGE_LOCATION }
    }

    /// @notice Canonical ON on this chain (set once at initialize).
    function ON() public view returns (IERC20) { return _s().on; }

    /// @notice CCIP mint-cap headroom consumed, bounded by MAX_CCIP_MINTED.
    function ccipMintHeadroomUsed() external view returns (uint256) { return _s().ccipMintHeadroomUsed; }
```
Keep ALL existing events and errors verbatim (lines 90-129 of the current file). Add nothing new except: `error TimelockZero();` is NOT needed — reuse `ZeroAddress()` for the timelock check.

Constructor + initializer (replaces the current constructor at lines 131-153):
```solidity
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-time init. `admin` gets DEFAULT_ADMIN_ROLE + PAUSER_ROLE and becomes the
    ///         initial CCIP admin; `timelock` gets UPGRADER_ROLE (gates _authorizeUpgrade).
    function initialize(IERC20 onToken, address admin, address timelock) external initializer {
        if (address(onToken) == address(0) || admin == address(0) || timelock == address(0)) {
            revert ZeroAddress();
        }
        if (address(onToken) == address(this)) {
            revert SelfReserve();
        }
        __ERC20_init("Wrapped Orochi Network", "wON");
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuardTransient_init();
        __UUPSUpgradeable_init();

        uint8 onDecimals = IERC20Metadata(address(onToken)).decimals();
        if (onDecimals != decimals()) {
            revert DecimalsMismatch(decimals(), onDecimals);
        }
        WrappedONStorage storage $ = _s();
        $.on = onToken;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, timelock);
        $.ccipAdmin = admin;
        emit CCIPAdminTransferred(address(0), admin);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /// @notice Emergency stop on the value paths (mint/burn/deposit/withdraw). Transfers stay live.
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
```
(If using the non-upgradeable `ReentrancyGuardTransient` fallback, drop it from the inheritance list's `*Upgradeable` form, inherit `ReentrancyGuardTransient`, and remove the `__ReentrancyGuardTransient_init()` line — that guard has no initializer.)

- [ ] **Step 3: Rewrite `src/WrappedON.sol` — function bodies (mechanical state-access migration + pause)**

Apply these mechanical transforms to the existing `deposit`, `withdraw`, `mint`, `burn` (all 3), `getCCIPAdmin`, `pendingCCIPAdmin`, `setCCIPAdmin`, `acceptCCIPAdmin`, `_decrementCcipMintHeadroom`, `_ccipBurn`, `supportsInterface`, keeping their logic identical:
  - Every read/write of the immutable/state `ON` → `_s().on` (or call `ON()` for reads).
  - Every `ccipMintHeadroomUsed` (the storage var) → `_s().ccipMintHeadroomUsed`.
  - Every `s_ccipAdmin` → `_s().ccipAdmin`; every `s_pendingCcipAdmin` → `_s().pendingCcipAdmin`.
  - Add `whenNotPaused` modifier to: `deposit`, `withdraw`, `mint`, `burn(uint256)`, `burn(address,uint256)`, `burnFrom`. (Order: e.g. `external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused`.) Do NOT add it to view functions or the CCIP-admin functions.
  - `supportsInterface` override list becomes `override(AccessControlUpgradeable)` and keep the same interface-id set (IERC20, IERC20Metadata, IBurnMintERC20, IGetCCIPAdmin, IAccessControl, IERC165).
  - `decimals()` is provided by ERC20Upgradeable (returns 18) — unchanged.

Verify `__ReentrancyGuardTransient_init` is the correct initializer name for the upgradeable variant (check the file from Task 1 Step 3); adjust if OZ named it differently.

- [ ] **Step 4: Create the test helper `test/helpers/DeployWON.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {WrappedON} from "../../src/WrappedON.sol";

library DeployWON {
    /// @dev Deploys impl + ERC1967Proxy initialized with (on, admin, timelock). Returns the
    ///      proxy typed as WrappedON. `timelock` here can be any address acting as upgrader.
    function deploy(IERC20 on, address admin, address timelock) internal returns (WrappedON) {
        WrappedON impl = new WrappedON();
        bytes memory data = abi.encodeCall(WrappedON.initialize, (on, admin, timelock));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        return WrappedON(address(proxy));
    }
}
```
Note for the implementer: most existing tests don't exercise upgrades, so they can pass `admin` as the `timelock` arg (the upgrader identity is irrelevant to non-upgrade tests). Tests that previously did `new WrappedON(on, admin)` become `DeployWON.deploy(on, admin, admin)`.

- [ ] **Step 5: Migrate every construction site**

Replace each `new WrappedON(<on>, <admin>)` with `DeployWON.deploy(<on>, <admin>, <admin>)` and add `import {DeployWON} from "<relative>/helpers/DeployWON.sol";` to each file. Sites (verify line numbers; they shift as you edit):
  - `test/WrappedON.t.sol`: `setUp` (was L146), the `nullWon` (L183), and the reverting-construction tests (L819, L824, L829, L839, L850, L875, L899). For the **revert tests** (zero ON, zero admin, self-reserve via predicted address, decimals mismatch, duplicate-admin), the revert now happens inside `initialize` during proxy construction — wrap the `DeployWON.deploy(...)` call with `vm.expectRevert(<same selector>)`. The selectors are unchanged (`ZeroAddress`, `SelfReserve`, `DecimalsMismatch`). The self-reserve predicted-address test must predict the PROXY address (not the impl) — compute it from the deployer nonce at proxy-deploy time; if that's brittle, replace with a direct `initialize` call on a deployed proxy using `address(proxy)` as the ON token to trigger `SelfReserve`. Keep the assertion meaning identical.
  - `test/PoolRoundtrip.t.sol` (L80), `test/DeploymentE2E.t.sol` (L107), `test/Script06Renounce.t.sol` (L91), `test/Script08Verify.t.sol` (L175, L251), `test/WrappedONInvariant.t.sol` (L302), `test/fork/Fork_ETH.t.sol` (L68), `test/fork/Fork_Bridge.t.sol` (L84): straightforward `DeployWON.deploy(on, admin, admin)` substitution.
  - Any test asserting `won.ON()` or `won.ccipMintHeadroomUsed()` keeps working (getters preserved).

- [ ] **Step 6: Build + full suite**

Run: `make fmt && forge build && make test`
Expected: compiles; all existing tests pass through the proxy (149 currently; count unchanged in this task). Investigate any failure — most likely a missed state-access transform or a revert-test that needs the `initialize`-revert wrapping.

- [ ] **Step 7: Commit**

```bash
git add src/WrappedON.sol test/ foundry.toml
git commit -m "feat(won): UUPS-upgradeable wON (initializer, ERC-7201 storage, pause hooks)"
```

---

## Task 3: Upgrade + initializer + authorization tests

**Files:** Create `test/mocks/WrappedONV2Mock.sol`, `test/WrappedONUpgrade.t.sol`

**Interfaces:** Consumes `DeployWON`, `WrappedON.initialize/_authorizeUpgrade/upgradeToAndCall`.

- [ ] **Step 1: Write the V2 mock implementation**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;
import {WrappedON} from "../../src/WrappedON.sol";

/// @dev Trivial V2: adds a new function + a reinitializer to prove upgrades work and state
///      survives. Reuses V1 storage (ERC-7201 namespace identical via inheritance).
contract WrappedONV2Mock is WrappedON {
    function version() external pure returns (uint256) { return 2; }
}
```

- [ ] **Step 2: Write the failing upgrade/initializer tests**

`test/WrappedONUpgrade.t.sol` (uses a mock ON token already in the suite — reuse `test/mocks` MockON; adapt the import to the existing mock path):
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WrappedON} from "../src/WrappedON.sol";
import {WrappedONV2Mock} from "./mocks/WrappedONV2Mock.sol";
import {DeployWON} from "./helpers/DeployWON.sol";
import {MockON} from "./mocks/MockON.sol"; // adjust to the actual mock used elsewhere

contract WrappedONUpgradeTest is Test {
    MockON internal on;
    WrappedON internal won;
    address internal admin = makeAddr("admin");
    address internal timelock = makeAddr("timelock");
    address internal pool = makeAddr("pool");

    function setUp() public {
        on = new MockON();
        won = DeployWON.deploy(IERC20(address(on)), admin, timelock);
        vm.prank(admin);
        won.grantRole(won.MINTER_ROLE(), pool);
    }

    function test_UpgradePreservesState() public {
        // seed state: a CCIP mint (reserve 0 -> wON minted, headroom used)
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

    function test_UpgradeRevertsForNonUpgrader() public {
        WrappedONV2Mock v2 = new WrappedONV2Mock();
        vm.prank(admin); // admin holds DEFAULT_ADMIN + PAUSER but NOT UPGRADER
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, won.UPGRADER_ROLE())
        );
        won.upgradeToAndCall(address(v2), "");
    }

    function test_InitializeCannotBeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        won.initialize(IERC20(address(on)), admin, timelock);
    }

    function test_ImplementationInitializersDisabled() public {
        WrappedON impl = new WrappedON();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(IERC20(address(on)), admin, timelock);
    }
}
```

- [ ] **Step 3: Run to verify failure, then pass**

Run: `forge test --match-path 'test/WrappedONUpgrade.t.sol' -vvv`
Expected: with Task 2 done, these should PASS. If `test_UpgradeRevertsForNonUpgrader` fails on the error shape, adjust to the actual revert (OZ `AccessControlUnauthorizedAccount`). If the contract isn't correct, fix `src/WrappedON.sol`.

- [ ] **Step 4: Commit**

```bash
git add test/WrappedONUpgrade.t.sol test/mocks/WrappedONV2Mock.sol
git commit -m "test(won): upgrade state-preservation, initializer, and upgrade-auth"
```

---

## Task 4: Pause behavior tests

**Files:** Create `test/WrappedONPause.t.sol`

- [ ] **Step 1: Write the failing pause tests**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {WrappedON} from "../src/WrappedON.sol";
import {DeployWON} from "./helpers/DeployWON.sol";
import {MockON} from "./mocks/MockON.sol"; // adjust import

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

    function test_PauserCanPauseAndUnpause() public {
        vm.prank(admin);
        won.pause();
        assertTrue(won.paused());
        vm.prank(admin);
        won.unpause();
        assertFalse(won.paused());
    }

    function test_NonPauserCannotPause() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, won.PAUSER_ROLE())
        );
        won.pause();
    }

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

    function test_PausedAllowsTransfer() public {
        // mint some wON first (reserve 0 so mint mints), then pause, then transfer must work
        vm.prank(pool);
        won.mint(alice, 50 ether);
        vm.prank(admin);
        won.pause();
        vm.prank(alice);
        won.transfer(makeAddr("bob"), 10 ether); // must NOT revert
        assertEq(won.balanceOf(makeAddr("bob")), 10 ether);
    }

    function test_UnpauseRestoresValuePaths() public {
        vm.prank(admin);
        won.pause();
        vm.prank(admin);
        won.unpause();
        vm.prank(pool);
        won.mint(alice, 5 ether);
        assertEq(won.balanceOf(alice), 5 ether);
    }
}
```

- [ ] **Step 2: Run, then commit**

Run: `forge test --match-path 'test/WrappedONPause.t.sol' -vvv` → PASS.
```bash
git add test/WrappedONPause.t.sol
git commit -m "test(won): pause halts value paths, leaves transfer live, role-gated"
```

---

## Task 5: Timelock-gated upgrade flow test

**Files:** Create `test/WrappedONTimelock.t.sol`

- [ ] **Step 1: Write the failing timelock test**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {WrappedON} from "../src/WrappedON.sol";
import {WrappedONV2Mock} from "./mocks/WrappedONV2Mock.sol";
import {MockON} from "./mocks/MockON.sol"; // adjust import

contract WrappedONTimelockTest is Test {
    MockON internal on;
    WrappedON internal won;
    TimelockController internal timelock;
    address internal multisig = makeAddr("multisig");
    uint256 internal constant DELAY = 172800; // 48h

    function setUp() public {
        on = new MockON();
        address[] memory ms = new address[](1);
        ms[0] = multisig;
        timelock = new TimelockController(DELAY, ms, ms, address(0)); // proposer+executor = multisig, no extra admin
        WrappedON impl = new WrappedON();
        bytes memory data = abi.encodeCall(WrappedON.initialize, (IERC20(address(on)), multisig, address(timelock)));
        won = WrappedON(address(new ERC1967Proxy(address(impl), data)));
    }

    function test_UpgradeViaTimelockHappyPath() public {
        WrappedONV2Mock v2 = new WrappedONV2Mock();
        bytes memory call = abi.encodeCall(WrappedON.upgradeToAndCall, (address(v2), ""));
        bytes32 salt = bytes32(0);

        vm.prank(multisig);
        timelock.schedule(address(won), 0, call, bytes32(0), salt, DELAY);

        // before delay: execute reverts
        vm.prank(multisig);
        vm.expectRevert(); // TimelockController: operation is not ready
        timelock.execute(address(won), 0, call, bytes32(0), salt);

        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(multisig);
        timelock.execute(address(won), 0, call, bytes32(0), salt);

        assertEq(WrappedONV2Mock(address(won)).version(), 2, "upgrade applied after delay");
    }

    function test_DirectUpgradeBypassingTimelockReverts() public {
        WrappedONV2Mock v2 = new WrappedONV2Mock();
        vm.prank(multisig); // multisig is NOT the UPGRADER (the timelock is)
        vm.expectRevert();
        won.upgradeToAndCall(address(v2), "");
    }
}
```

- [ ] **Step 2: Run, then commit**

Run: `forge test --match-path 'test/WrappedONTimelock.t.sol' -vvv` → PASS. (If the `TimelockController` constructor arity differs in OZ 5.6.1, adjust — it is `(uint256 minDelay, address[] proposers, address[] executors, address admin)`.)
```bash
git add test/WrappedONTimelock.t.sol
git commit -m "test(won): timelock-gated upgrade (delay enforced, direct upgrade blocked)"
```

---

## Task 6: Deploy scripts + script tests

**Files:** Modify `script/01_DeployWrappedON.s.sol`, `script/06_TransferOwnership.s.sol`, `test/Script06Renounce.t.sol`, `test/Script08Verify.t.sol`

- [ ] **Step 1: Rework script 01 to deploy timelock + impl + proxy**

Replace the `new WrappedON(...)` broadcast block. Read `MULTISIG` from env for the timelock proposer/executor if set, else use the deployer (pre-handoff). Deploy order:
```solidity
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
// ...
uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(172800)); // 48h default
address[] memory props = new address[](1);
props[0] = admin; // pre-handoff: deployer; script 06 hands timelock roles to multisig
vm.startBroadcast();
TimelockController timelock = new TimelockController(delay, props, props, address(0));
WrappedON impl = new WrappedON();
ERC1967Proxy proxy = new ERC1967Proxy(
    address(impl), abi.encodeCall(WrappedON.initialize, (IERC20(cfg.onToken), admin, address(timelock)))
);
won = WrappedON(address(proxy));
vm.stopBroadcast();
Deployments.writeAddress(block.chainid, "wrappedON", address(won));
Deployments.writeAddress(block.chainid, "wrappedONImpl", address(impl));
Deployments.writeAddress(block.chainid, "wrappedONTimelock", address(timelock));
Deployments.writeAddress(block.chainid, "deployer", admin);
```
Keep the idempotency guard (existing `wrappedON` entry → skip) and the `DeploymentsJsonCorrupt` check.

- [ ] **Step 2: Extend script 06 handoff**

In `_handoff` (grants to multisig): after the `DEFAULT_ADMIN_ROLE` grant, also grant `PAUSER_ROLE` to the multisig, and grant the timelock's proposer/executor/canceller roles to the multisig (read the timelock address from `Deployments`). In `RenounceDeployerAdmin`: renounce the deployer's `PAUSER_ROLE` and its timelock roles in addition to `DEFAULT_ADMIN_ROLE`. Mirror the existing `hasRole`/`grantRole`/`renounceRole` patterns. `UPGRADER_ROLE` already sits on the timelock (set at initialize) — do not move it.

- [ ] **Step 3: Update script tests**

`test/Script06Renounce.t.sol` and `test/Script08Verify.t.sol` already build wON via `DeployWON.deploy` (Task 2). Update their role-handoff setup/assertions to include `PAUSER_ROLE` where they assert the DEFAULT_ADMIN handoff/renounce. Keep assertions meaningful.

- [ ] **Step 4: Run + commit**

Run: `make test` → green.
```bash
git add script/ test/
git commit -m "feat(deploy): script 01 deploys timelock+impl+proxy; 06 hands off pause/timelock"
```

---

## Task 7: Docs + security record

**Files:** `CLAUDE.md`, `docs/ARCHITECTURE.md`, `README.md`, `RUNBOOK.md`, `SECURITY.md`, `STATE.md`

- [ ] **Step 1: Reverse the non-upgradeable convention + document the model**
  - `CLAUDE.md`: change "No upgrades: contracts are non-upgradeable by design…" to state wON is now UUPS-upgradeable behind a 48h timelock + emergency pause; note this is a deliberate exception to "keep it small / minimize surface." Add `UPGRADER_ROLE` (timelock) and `PAUSER_ROLE` (multisig) to the roles list; note the proxy address is the registered token.
  - `docs/ARCHITECTURE.md`: add the proxy topology (ERC1967Proxy → impl), timelock, pause, the upgrade flow, and the roles table rows.
  - `README.md` / `RUNBOOK.md`: new deploy sequence (timelock → impl → proxy); an **upgrade runbook** (deploy new impl → multisig `timelock.schedule(proxy,0,upgradeToAndCall(newImpl,""),0,salt,delay)` → wait 48h → `timelock.execute(...)`); a **pause/unpause runbook** (`won.pause()` / `unpause()` from the multisig); extend the handoff section to cover PAUSER + timelock roles.
  - `SECURITY.md`: new entry — upgrade authority is custody-grade (malicious impl can drain); mitigations = 48h timelock + emergency pause + two-step handoffs. Pause = liveness-only (halt, not theft) with the compromised-pauser griefing note. UUPS/initializer hygiene (`_disableInitializers`, gated `_authorizeUpgrade`, ERC-7201 storage). Mark the prior "non-upgradeable by design" stance as superseded (keep as history).
  - `STATE.md`: add rows for proxy / implementation / timelock addresses (PENDING until deploy).

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md docs/ARCHITECTURE.md README.md RUNBOOK.md SECURITY.md STATE.md
git commit -m "docs(won): upgradeable model — proxy, timelock, pause, upgrade runbook"
```

---

## Task 8: Final verification gate

- [ ] **Step 1: Full suite + format + build**

Run: `make fmt-check && forge build && make test`
Expected: `make test` green (≈149 migrated + new upgrade/pause/timelock tests). `forge build` exit 0.

- [ ] **Step 2: Storage-layout sanity**

Run: `forge inspect src/WrappedON.sol:WrappedON storage-layout` and confirm the contract's own state lives only in the ERC-7201 namespaced struct (no stray top-level slots besides what OZ bases declare in their own namespaces). Note in the commit/PR that ERC-7201 namespacing is the layout-safety mechanism (the optional `openzeppelin-foundry-upgrades` FFI plugin can be added later for automated diff validation but is not wired into forge-only CI).

- [ ] **Step 3: Confirm interface preserved**

Run: `forge inspect src/WrappedON.sol:WrappedON methods` and confirm `ON()`, `ccipMintHeadroomUsed()`, `getCCIPAdmin()`, `pendingCCIPAdmin()`, `MINTER_ROLE()`, `BURNER_ROLE()`, `MAX_CCIP_MINTED()`, `pause()`, `unpause()`, `UPGRADER_ROLE()`, `PAUSER_ROLE()`, `upgradeToAndCall(address,bytes)`, `initialize(address,address,address)` are present.

---

## Self-review notes

- **Spec coverage:** deps+remap (Task 1); UUPS rewrite + ERC-7201 + initializer + pause + ON-in-storage + harness sweep (Task 2); upgrade/initializer/auth tests (Task 3 — the user's explicit "more test cases"); pause tests (Task 4); timelock flow (Task 5); deploy/handoff scripts (Task 6); docs/security/STATE (Task 7); final gate incl. storage-layout + interface checks (Task 8). All spec sections mapped.
- **Build-green coupling:** the contract rewrite and the whole-project construction-site sweep land together in Task 2 so the project always compiles.
- **ABI preservation:** explicit `ON()` and `ccipMintHeadroomUsed()` getters replace the removed public immutable/var so tests and scripts keep working.
- **Verification flags:** `ReentrancyGuardTransientUpgradeable` existence + its `__init` name (Task 1/2), `TimelockController` ctor arity (Task 5), and the ERC-7201 storage-location constant computation (Task 2 Step 1) are called out for the implementer to confirm against the pinned OZ source.
- **Type consistency:** `DeployWON.deploy(IERC20,address,address)`, `initialize(IERC20,address,address)`, `UPGRADER_ROLE`/`PAUSER_ROLE`, and the V2 mock `version()` are referenced consistently across Tasks 2–6.
