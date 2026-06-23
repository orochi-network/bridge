# Design — Upgradeable wON (UUPS + timelock + pause)

_Date: 2026-06-23_

## Summary

Make `WrappedON` upgradeable so a bug in the live token logic can be patched **without** a
redeploy + CCIP re-registration. The token moves behind a **UUPS proxy** at a stable
address; upgrades are authorized by a **`TimelockController`** (48h delay, ops-multisig
proposer) and an **emergency `PAUSER_ROLE`** (multisig, immediate) can halt the value paths
while a fix clears the timelock.

This is a deliberate reversal of the project's "non-upgradeable by design / keep it small /
minimize audit/trust surface" convention, taken for the bug-fix safety net.

## Decisions (locked in brainstorming)

- **Purpose:** bug-fix safety net for token logic post-launch (full implementation
  upgradeability) — not feature churn or param-only.
- **Pattern:** UUPS (`ERC1967Proxy` → `WrappedON` implementation). Chosen over Transparent
  for lower per-call overhead and as the modern OZ default; over Beacon (many-proxy) as
  overkill.
- **Upgrade authority:** `TimelockController` (minDelay 48h; proposers/cancellers = ops
  multisig; executor = ops multisig) holds `UPGRADER_ROLE`; `_authorizeUpgrade` is gated
  to it. Emergency `PAUSER_ROLE` = multisig, no timelock.
- **`ON` reference:** stored in (namespaced) proxy storage, set once in `initialize` — NOT
  `immutable` (avoids the per-upgrade "wrong ON in a new impl" footgun). Cost: one SLOAD per
  use.
- **Pause scope:** value-moving entrypoints only — `mint`, all `burn` overloads, `deposit`,
  `withdraw`. Plain ERC20 `transfer` is **not** paused (pausing it strands in-flight CCIP and
  breaks composability). Transfer-pause is intentionally out of scope.
- **Storage:** ERC-7201 namespaced storage for all custom state (collision-safe across
  upgrades).

## Constraints & context

- wON is a CCIP `BurnMintTokenPool` token on **Ethereum only**, registered in
  `TokenAdminRegistry` via `getCCIPAdmin` (two-step), with `MINTER_ROLE`/`BURNER_ROLE` → the
  stock pool and `DEFAULT_ADMIN_ROLE` → deployer→multisig.
- Pre-launch and clean (no holders/reserve). None of the recent wON changes are on-chain yet
  (live wON is still the original `0x98d6…606`), so this upgradeable version simply *is* the
  pending redeploy — no state migration.
- BSC side (stock `LockReleaseTokenPool` on canonical ON) is unchanged; only its ETH-lane
  remote-token wiring points at the new proxy address.
- Signing is keystore-only (`--account deployer`); handoff/renounce remain disabled until
  the bridge is operational.

## New dependencies

- `openzeppelin-contracts-upgradeable` pinned to **v5.6.1** (match the existing OZ pin) +
  remap `@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/`.
- `openzeppelin-foundry-upgrades` (dev/tooling) for storage-layout + initializer validation
  on each upgrade.
- `TimelockController` and `ERC1967Proxy` come from the already-present main
  `@openzeppelin/contracts` package.

## Architecture

```
ERC1967Proxy (stable wON address, registered in TokenAdminRegistry)
   └─ delegatecall → WrappedON implementation (UUPS)
        _authorizeUpgrade ── onlyRole(UPGRADER_ROLE) ── held by ──► TimelockController (48h)
                                                                       proposers/cancellers = multisig
        PAUSER_ROLE (multisig, immediate) ──► pause()/unpause()
        DEFAULT_ADMIN_ROLE ──► multisig (role admin of MINTER/BURNER/PAUSER — NOT UPGRADER)
        UPGRADER_ROLE self-administers (_setRoleAdmin → itself) so the multisig can't
            re-grant it and bypass the 48h timelock (PR #47 review; SECURITY UPG-1)
        MINTER_ROLE / BURNER_ROLE ──► stock BurnMintTokenPool
```

## Contract changes (`src/WrappedON.sol`)

- Inherit `Initializable, ERC20Upgradeable, AccessControlUpgradeable, PausableUpgradeable,
  ReentrancyGuardTransientUpgradeable, UUPSUpgradeable, IGetCCIPAdmin`. (Plan must verify
  `ReentrancyGuardTransientUpgradeable` exists in OZ-upgradeable v5.6.1; if not, the
  non-upgradeable `ReentrancyGuardTransient` is safe to inherit even here — its guard uses a
  constant transient slot with no storage to initialize.)
- `constructor()` → `_disableInitializers()` only. Logic moves to
  `initialize(IERC20 onToken, address admin, address timelock)` (one-time), calling
  `__ERC20_init("Wrapped Orochi Network","wON")`, `__AccessControl_init`, `__Pausable_init`,
  `__UUPSUpgradeable_init`, etc. Keep the existing zero/self/decimals-mismatch checks on
  `onToken`.
- All custom state (`ON`, `ccipMintHeadroomUsed`, `s_ccipAdmin`, `s_pendingCcipAdmin`) moves
  into an ERC-7201 namespaced storage struct.
- `_authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE)`.
- New roles: `UPGRADER_ROLE` (granted to the timelock), `PAUSER_ROLE` (granted to the
  multisig). `DEFAULT_ADMIN_ROLE` is the role admin of `PAUSER_ROLE` (and
  `MINTER_ROLE`/`BURNER_ROLE`). `UPGRADER_ROLE` is made **self-administered** via
  `_setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE)` so `DEFAULT_ADMIN_ROLE` (the multisig
  post-handoff) cannot grant itself upgrade authority and bypass the timelock — the 48h delay
  is then genuinely enforced (PR #47 review; SECURITY UPG-1).
- Add `whenNotPaused` to `mint`, `burn(uint256)`, `burn(address,uint256)`, `burnFrom`,
  `deposit`, `withdraw`. `pause()`/`unpause()` gated to `PAUSER_ROLE`.
- The existing auto-unwrap, permissionless-deposit, cap-counter, and CCIP-admin two-step
  logic is preserved exactly — only the init/storage/proxy scaffolding changes around it.

## Deploy & registration

ETH deploy (script 01 reworked), deployer-in-control, keystore-signed:
1. Deploy `TimelockController` (48h; proposers/cancellers = multisig; executor = multisig).
2. Deploy the `WrappedON` implementation (ctor disables initializers).
3. Deploy `ERC1967Proxy(impl, abi.encodeCall(WrappedON.initialize, (ON, deployerAdmin, timelock)))`.
   The **proxy address is the wON address**.
4. Scripts 02–05 run unchanged against the proxy: pool bound to the proxy, roles granted on
   the proxy, admin registered via `getCCIPAdmin` (works through delegatecall), BSC remote
   wired.

**Future bug fix (the payoff):** deploy new impl → multisig `schedule`s upgrade on the
timelock → wait 48h → `execute` → proxy repoints. No re-registration, no BSC re-wire, address
unchanged.

**Handoff (extends script 06):** deployer bootstraps, then hands timelock proposer/executor
roles + wON `DEFAULT_ADMIN_ROLE` + `PAUSER_ROLE` to the multisig and renounces its own.

## Security / trust record (`SECURITY.md`)

- Upgrade authority (timelock + multisig) is custody-grade: a malicious implementation could
  mint/redirect/drain all wON value. Mitigations: 48h timelock (reaction window), emergency
  pause, two-step role handoffs. Explicitly a reversal of the immutable design.
- Pause = liveness control only (halt mint/burn/deposit/withdraw; cannot steal). Document the
  availability/griefing risk if the pauser key is compromised, bounded to "halt, not theft."
- UUPS/initializer hygiene: `_disableInitializers()` on the impl, `_authorizeUpgrade` gated to
  the timelock, storage-layout validation on every upgrade.

## Docs

- `CLAUDE.md`: reverse "No upgrades"; add `UPGRADER_ROLE`/`PAUSER_ROLE`; note the proxy and
  the deliberate exception to "keep it small."
- `docs/ARCHITECTURE.md`: proxy topology, timelock, pause, upgrade flow, roles table.
- `README.md` / `RUNBOOK.md`: new deploy sequence (timelock → impl → proxy); the upgrade
  runbook (deploy impl → `schedule` → wait 48h → `execute`); pause/unpause runbook; handoff
  covering timelock + pause.
- `STATE.md`: proxy / implementation / timelock addresses post-deploy.

## Tests

- **Harness change:** every test that does `new WrappedON(...)` must deploy proxy +
  `initialize` via a shared helper. Touches `WrappedON.t.sol`, `WrappedONInvariant.t.sol`,
  `PoolRoundtrip.t.sol`, `DeploymentE2E.t.sol`, the script tests, and the fork tests.
- New tests: V1→V2 upgrade preserves state (`ccipMintHeadroomUsed`, reserve, balances,
  `s_ccipAdmin`); `initialize` cannot be re-run and is disabled on the impl; only the timelock
  can `_authorizeUpgrade` (others revert); timelock schedule/wait/execute (execute-before-delay
  reverts; cancel works); pause halts the value paths but not `transfer`; storage-layout
  validation via the upgrades plugin.
- Re-run the full existing suite against the proxy (all current behavior preserved).

## Honest tradeoffs (recorded)

- **Runtime gas:** the proxy adds a `delegatecall` (~2.1–2.6k) to every call plus a
  `whenNotPaused` SLOAD on the paused paths — roughly cancels the ~2k/`mint` saved by the
  transient guard. Upgradeability is not free at runtime.
- **Surface:** roughly doubles the contract's moving parts (proxy, initializer, timelock,
  pause, namespaced storage, upgrade auth) + two new dependencies — the largest single change
  to the bridge so far, and a reversal of the minimize-surface convention.

## Out of scope

- Transfer-pause (only value paths are pausable).
- Making the BSC `LockReleaseTokenPool` or any stock CCIP contract upgradeable.
- Param-only mutability / setters (full logic upgradeability chosen instead).
- Re-enabling handoff/renounce (separate, still-disabled decision).
