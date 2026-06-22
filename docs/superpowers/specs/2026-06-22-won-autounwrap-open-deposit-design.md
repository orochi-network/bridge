# Design — wON auto-unwrap on BSC→ETH + permissionless deposit

_Date: 2026-06-22_

## Summary

Two product changes to the ON bridge, both landing in a single new `WrappedON.sol`
(the contract is non-upgradeable, so they ship together via one redeploy):

1. **Auto-unwrap on BSC→ETH** — when a CCIP transfer arrives on Ethereum and the wON
   wrap-reserve fully covers it, deliver native ON to the receiver instead of minting wON.
2. **Permissionless `deposit`** — anyone can wrap native ON into wON; remove the
   `LIQUIDITY_MANAGER_ROLE` gate (and the now-dead role).

## Context & constraints

- Current `WrappedON.sol` is the only custom contract. CCIP pools are stock
  (`BurnMintTokenPool` on ETH, `LockReleaseTokenPool` on BSC), per `CLAUDE.md` ("do NOT
  subclass").
- The BSC→ETH path ends with the stock `BurnMintTokenPool` calling `wON.mint(receiver, amount)`.
- wON is already deployed on ETH mainnet (`0x98d6…606`) with both pools wired, but the
  bridge is **clean**: never went operational, no live bridge test, **no wON holders and no
  ON reserve to migrate**. So this is a fresh redeploy, not a migration.
- Contracts are non-upgradeable; the migration path is redeploy + re-register.
- Signing is keystore-only (`--account deployer`); handoff/renounce remain disabled
  (decision 2026-06-19) — the redeploy happens with the deployer EOA in control.

## Decisions (locked during brainstorming)

- **Deploy state:** clean redeploy, no holder/reserve migration.
- **Auto-unwrap mode:** all-or-nothing. If reserve `R >= amount N`, deliver `N` native ON;
  otherwise mint all `N` as wON (no partial unwrap).
- **Placement:** inside `wON.mint` (keeps one custom contract + stock pool).
- **Cap counter:** an auto-unwrap mints 0 wON, so it does **not** touch
  `ccipMintHeadroomUsed`.
- **Role:** remove `LIQUIDITY_MANAGER_ROLE` entirely (its only use was gating `deposit`).

## Contract changes — `WrappedON.sol`

### A. Permissionless `deposit`

- Remove `onlyRole(LIQUIDITY_MANAGER_ROLE)` from `deposit`. Keep received-amount accounting,
  `ZeroAmount` / `received == 0` guards, and `nonReentrant`.
- Remove the `LIQUIDITY_MANAGER_ROLE` constant and its constructor grant. `withdraw` is
  already permissionless, so wrap/unwrap become a symmetric public pair.

### B. Auto-unwrap inside `mint` (all-or-nothing)

```solidity
function mint(address account, uint256 amount) external onlyRole(MINTER_ROLE) nonReentrant {
    if (amount == 0) revert ZeroAmount();

    // Auto-unwrap: if the wrap reserve fully covers this CCIP arrival, deliver native ON
    // and mint 0 wON. Cap counter untouched (nothing minted); invariant preserved because
    // BSC lock += amount and reserve -= amount net out.
    uint256 reserve = ON.balanceOf(address(this));
    if (reserve >= amount) {
        ON.safeTransfer(account, amount);
        emit CCIPAutoUnwrapped(account, amount);
        return;
    }

    uint256 wouldBe = ccipMintHeadroomUsed + amount;   // unchanged fallback path
    if (wouldBe > MAX_CCIP_MINTED) revert CCIPMintCapExceeded(MAX_CCIP_MINTED, wouldBe);
    ccipMintHeadroomUsed = wouldBe;
    _mint(account, amount);
    emit CCIPMinted(account, amount, wouldBe);
}
```

- New event: `event CCIPAutoUnwrapped(address indexed account, uint256 amount);` — lets
  indexers distinguish native-ON deliveries from wON mints.
- `mint` is callable only by `MINTER_ROLE` (the pool), so auto-unwrap triggers only on CCIP
  inbound, never from `deposit`.

### Invariants & accounting (verified)

- Safety invariant `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` holds on the
  auto-unwrap branch: BSC lock `+N`, reserve `−N`, supply unchanged.
- `ccipMintHeadroomUsed` is already documented as a BSC-balance approximation, not ground
  truth; leaving it untouched on auto-unwrap avoids headroom leakage (modeling auto-unwrap
  as mint+withdraw would consume headroom that never gets decremented).

### Dependency to verify in implementation

- Confirm the vendored CCIP 1.6.1 `BurnMintTokenPool`/`BurnMintTokenPoolAbstract`
  `releaseOrMint` calls `IBurnMintERC20(token).mint(receiver, amount)` and does **not** read
  the receiver's wON balance afterward (so delivering ON instead of minting wON is safe).
  CCIP rate limiting operates on `amount` regardless.

## Security record (`SECURITY.md`)

Accepted consequences of the requested behavior:

1. **M3/#25 reversed by product decision.** Permissionless `deposit` means wON supply (and
   ETH→BSC redemption pressure) is no longer bounded by a role — only by ETH-side ON supply
   and the CCIP pool rate limits. Mark M3 as reversed/superseded.
2. **Auto-unwrap reserve-drain blast radius.** Auto-unwrap lets the trusted `MINTER_ROLE`
   pool move native ON out of the reserve. A *compromised* pool could now drain the ON
   reserve in addition to minting wON — same trust assumption as `mint` today, larger blast
   radius. Document as accepted under the trusted-pool model.
3. **Arbitrage-layer reality intensifies.** Auto-unwrap actively depletes the reserve for
   inbound users, so depositors' `withdraw` availability depends even more on continued
   wrapping / operator rebalancing. Not a guaranteed redemption.

## Redeploy & re-registration

Fresh ETH-side deploy + re-wire of the unchanged BSC side. Deployer EOA in control,
keystore-signed.

**ETH side (new contracts):**
1. Deploy new wON (both changes) → new address.
2. Deploy new `BurnMintTokenPool` bound to new wON (old pool is immutably bound to old token).
3. Grant `MINTER_ROLE`/`BURNER_ROLE` on new wON to new pool (script 03).
4. Register new wON CCIP admin in `TokenAdminRegistry` + `setPool(newWON → newPool)`
   (script 04, `getCCIPAdmin` path).
5. Wire BSC remote + rate limits on the new ETH pool (script 05).

**BSC side (no new contract, no re-registration):**
- `LockReleaseTokenPool` (token = canonical ON, unchanged) keeps its ON admin/pool
  registration. Only re-wire its ETH lane: remove the old ETH-lane config and add the new
  one pointing at the new ETH pool (`remotePoolAddresses`) + new wON (`remoteTokenAddress`),
  same rate limits (script 05 re-run). This avoids re-touching BSC script 04, so the
  path-4 Chainlink-admin blocker never re-enters.

**Cleanup / bookkeeping:**
- Old ETH wON `TokenAdminRegistry` entry becomes orphaned — optionally
  `setPool(oldWON, address(0))` to deregister; harmless if left.
- Update `deployments/1.json` (+ `56.json` lane data), `STATE.md` deployed-contracts table,
  and address references in docs.
- Handoff/renounce remain disabled.

**Open ops choice (decided in the implementation plan, not blocking):** testnet dry-run
first vs. straight to mainnet (last redeploy went straight to mainnet).

## Scripts

- `03_GrantRoles` / `06_TransferOwnership` — drop the `LIQUIDITY_MANAGER_ROLE` grant /
  handoff / renounce steps.
- `01_DeployWrappedON` — ctor signature `(onToken, admin)` unchanged.

## Tests

- `WrappedON.t.sol` — remove deposit role-gating tests; assert `deposit` works from any
  caller. Add auto-unwrap unit tests: reserve ≥ amount → receiver gets native ON,
  `totalSupply` unchanged, `ccipMintHeadroomUsed` untouched, `CCIPAutoUnwrapped` emitted;
  reserve < amount → mints wON exactly as today (cap path intact); boundary `reserve == amount`.
- `WrappedONInvariant.t.sol` — add auto-unwrap to the mint handler; confirm the safety
  invariant holds across mixed deposit/mint/withdraw/auto-unwrap sequences.
- `PoolRoundtrip.t.sol` + fork tests (`Fork_ETH` / `Fork_Bridge`) — update releaseOrMint
  expectations so a covered arrival yields native ON, not wON.
- `DeploymentE2E.t.sol`, `Script06*` — remove role grant/renounce assertions.

## Docs

- `CLAUDE.md` — rewrite "Roles on wON" and "Reserve invariant (wON)": `deposit`
  permissionless, role removed, auto-unwrap behavior in `mint`.
- `README.md` / `RUNBOOK.md` / `docs/ARCHITECTURE.md` — document auto-unwrap on BSC→ETH and
  open deposit in the flow descriptions.
- `STATE.md` — new addresses post-redeploy.

## Out of scope

- Partial auto-unwrap (chose all-or-nothing).
- Any change to the BSC `LockReleaseTokenPool` contract or BSC ON admin registration.
- Re-enabling handoff/renounce (separate, still-disabled decision).
- Migration tooling (clean deploy, nothing to migrate).
