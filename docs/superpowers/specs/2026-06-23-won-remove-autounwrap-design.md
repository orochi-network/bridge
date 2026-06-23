# Design — Remove auto-unwrap from `WrappedON.mint` (resolves #48)

_Date: 2026-06-23 · Rides PR #47 (`feat/won-upgradeable`)._

## Problem (issue #48)

`WrappedON.mint` (the CCIP `releaseOrMint` entrypoint) added in #45 auto-unwraps on
covered BSC→ETH arrivals: when `ON.balanceOf(wON) >= amount` it delivers **native ON** to
the receiver and mints **0 wON** (all-or-nothing). This silently changes the asset delivered
to **contract receivers** in CCIP *programmatic* token transfers (token + data). A receiver
coded to expect `amount` of **wON** instead observes 0 new wON and an unexpected native-ON
balance — its wON-based accounting fails or the value sits unhandled.

The trigger is **nondeterministic and front-runnable**: `deposit`/`withdraw` are
permissionless, so anyone can move `ON.balanceOf(wON)` across the `>= amount` boundary in
the same block, flipping the branch. A BSC→ETH sender cannot predict which asset their
receiver gets.

- Severity: Medium (integration footgun; the protocol invariant
  `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` is never violated).
- Affected: any contract receiver on the BSC→ETH lane that assumes it receives wON.

## Decision

**Remove auto-unwrap entirely.** `mint` always mints wON on CCIP arrivals (cap-checked),
regardless of reserve. The `CCIPAutoUnwrapped` event is deleted.

Chosen over (a) EOA-gating the auto-unwrap (`account.code.length == 0`) and (b)
documentation-only. The team's product call is that the CCIP lane should deliver exactly one,
predictable asset — the registered token, wON — to every receiver. EOAs that want native ON
call `withdraw` like any other holder. This removes the footgun at the source rather than
warning about it, and it shrinks the contract's trust surface (see below).

## Resulting behavior

`mint(account, amount)` (MINTER_ROLE only):

1. revert `ZeroAmount` if `amount == 0`;
2. `wouldBe = ccipMintHeadroomUsed + amount`; revert `CCIPMintCapExceeded` if `wouldBe > MAX_CCIP_MINTED`;
3. `ccipMintHeadroomUsed = wouldBe`;
4. `_mint(account, amount)`;
5. `emit CCIPMinted(account, amount, wouldBe)`.

No reserve read, no `safeTransfer`, no `CCIPAutoUnwrapped`. Every BSC→ETH arrival delivers
`amount` wON to `account`, EOA or contract, deterministically.

## Net effects

- **Security — strictly safer.** The `mint` path can no longer move ON out of the reserve, so
  the SECURITY.md "Residual risk note B — auto-unwrap reserve drain" vector disappears: a
  compromised `MINTER_ROLE` pool can mint wON up to `MAX_CCIP_MINTED` but can no longer drain
  the native-ON reserve. The reserve now exits only via `withdraw` (caller burns their own
  wON). Note B is retired; a new `WON-` finding records #48's resolution.
- **Invariant — simpler.** Reserve accounting becomes `reserve == totalDeposited − totalWithdrawn`
  (no auto-unwrap term). The safety invariant `lockedON_BSC + reserveON_ETH >= totalSupply(wON)`
  still holds: every CCIP mint pairs a BSC lock; burns reverse both sides.
- **Cap counter — simpler.** `mint` always increments `ccipMintHeadroomUsed`; the "untouched on
  the unwrap path" caveat is gone.

## Surface of edits

- **Contract** — `src/WrappedON.sol`: `mint` body; remove `CCIPAutoUnwrapped` event; rewrite the
  `mint` NatSpec and the contract-header "two mint paths" / CAP-REPLENISHMENT notes that
  reference auto-unwrap.
- **Tests** — flip assertions from "native ON delivered" to "wON minted":
  `WrappedON.t.sol` (the 3 auto-unwrap unit tests + the ~L318 mixed-path block),
  `PoolRoundtrip.t.sol` (`test_BscToEth_AutoUnwrapWhenReserveCovers`),
  `WrappedONInvariant.t.sol` (drop the `totalAutoUnwrapped` ghost + handler branch; reserve
  invariant becomes deposits − withdrawals), `WrappedONUpgrade.t.sol` (post-upgrade block),
  `fork/Fork_ETH.t.sol` (`test_Fork_ETH_BscToEth_AutoUnwrap`). **Add** a test asserting a
  *contract* receiver gets wON even when the reserve fully covers — the exact #48 scenario.
- **Canonical docs** — `CLAUDE.md`, `README.md`, `RUNBOOK.md`, `SECURITY.md`, `STATE.md`,
  `docs/ARCHITECTURE.md`.

## Out of scope (unchanged)

Permissionless `deposit`/`withdraw`; `MAX_CCIP_MINTED` cap and counter mechanics; UUPS proxy,
`TimelockController`, and pause. The historical `docs/superpowers/{plans,specs}/*autounwrap*`
files are left as a record of what #45 shipped; this doc supersedes them.

## Alternatives rejected

- **EOA-gate the auto-unwrap** (`reserve >= amount && account.code.length == 0`): deterministic
  for contracts and keeps the EOA UX, but retains two delivery assets on one lane and an
  EIP-7702-delegated-EOA edge. The team preferred a single predictable asset.
- **Documentation-only**: leaves the front-runnable footgun live.
