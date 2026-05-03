# Security

This document captures the security posture of the ON cross-chain bridge: the
trust assumptions the system relies on, the attack surface it deliberately
exposes, the audit findings raised so far, and the operator obligations that
hold the design together off-chain.

The bridge is a LayerZero V2 OFT mesh between BSC and Ethereum, described in
`CLAUDE.md`. Read that first if you have not.

## Reporting a vulnerability

Please email **chiro@orochi.network** with a description, reproduction steps,
and the commit hash you reviewed. Do not open a public issue for unpublished
vulnerabilities. We will acknowledge receipt within 72 hours.

## Trust assumptions

The bridge inherits the following assumptions; violating any of them breaks
the conservation invariant.

| Assumption | Why it matters | Verified |
|------------|----------------|----------|
| BSC ON token (`0x0e4F...1D48`) is lossless: `transferFrom(amount)` moves exactly `amount`. | `ONOFTAdapter` reports `amountSentLD` to LayerZero; ETH side credits the full amount. A silent FoT/rebase ⇒ unbacked wON. | Per-call delta guard in `_debit` (see Fix #1). Forked-mainnet dry-run also asserts losslessness today. |
| BSC ON has 18 decimals. | OFT shared-decimals math expects 18 LD. | Forked dry-run (`DryRun.t.sol`) and `WrappedON.constructor` both check 18. |
| ETH ON token (`0x33f6...B59d`) has 18 decimals. | wON is 18-decimal; 1:1 swap requires the reserve token to match. | Constructor `DecimalsMismatch` revert. |
| ETH ON token does not silently re-enter `WrappedON` from inside `safeTransfer`. | `_credit` and `unwrap` use checks-effects-interactions but do not gate with `ReentrancyGuard`. | Manual analysis: ON is a vanilla ERC20 (no ERC777-style hooks). Documented assumption. |
| Both DVNs (`LayerZero Labs`, `Google Cloud`) act independently. | Compromise of either DVN halts the bridge but does not steal funds. Compromise of both ⇒ arbitrary message forgery. | Operational obligation (DVN diversity). |
| The deployer EOA is fully handed off to a multisig before going live. | Until handoff, the EOA can rewire peers and mint unbounded wON. | Tracked by the post-deploy checklist; automated by `tasks/handoff.ts` (Fix #6). |

## Audit findings

The findings below come from the multi-agent audit on commit `04b16f6`. Each
fix references the commit that lands it.

### HIGH

#### H1 — Asymmetric fee-on-transfer protection
- **Where:** `ONOFTAdapter._debit` (inherited from upstream `OFTAdapter`) does
  not balance-delta-check the `transferFrom` it issues. `WrappedON._credit`
  auto-unwrap path does not balance-delta-check the `safeTransfer` it issues.
- **Why it matters:** if either ON token ever ships fee-on-transfer or
  rebasing semantics, the bridge silently leaks the fee while accounting for
  the full pre-fee amount on the other side, breaking conservation.
- **Fix (this branch):**
  - `ONOFTAdapter._debit` overridden with a balance-delta guard
    (`UnexpectedTransferAmount`).
  - `WrappedON._credit` auto-unwrap branch falls back to mint when the actual
    delivered amount differs from the requested amount, preserving message
    liveness while alerting via `UnwrapFallbackToMint`.

#### H2 — Manual ownership / delegate handoff
- **Where:** `deploy/ONOFTAdapter.ts` and `deploy/WrappedON.ts` leave the
  deployer EOA as both `owner` and `delegate`. The post-deploy checklist
  required two manual `transferOwnership` and `setDelegate` calls per chain.
  A forgotten command leaves a hot key with full peer/DVN authority.
- **Fix (this branch):** `tasks/handoff.ts` performs `setDelegate(multisig)`
  and `transferOwnership(multisig)` on a single network, ordered correctly,
  reading the multisig address from `OWNER_BSC` / `OWNER_ETH` env vars. The
  deploy/wire/handoff sequence should be performed in a single operator
  session.

#### H3 — BSC→ETH confirmations policy (operator decision)
- **Where:** `layerzero.config.ts` sets BSC→ETH = 20 confirmations.
- **Status:** Open. 20 BSC blocks is *fast finality* per BNB Chain
  documentation but historical reorgs deeper than 20 blocks exist. The team
  must sign off on whether 20 is acceptable for the maximum per-message size
  the bridge will permit, or raise the BSC-side confirmations.

### MEDIUM

#### M1 — `_lzReceive` composed branch duplicates upstream logic
- **Where:** `WrappedON._lzReceive` re-implemented the composed path inline,
  emitted `UnwrapFallbackToMint` on every composed message (false positive
  for any monitor watching that event), and was vulnerable to silent drift
  if upstream `OFTCore.lzReceive` ever changes.
- **Fix (this branch):** transient `_isComposed` flag set in `_lzReceive`,
  then `super._lzReceive` is called and the composed path is implemented
  inside `_credit`. Single source of truth, no duplicated event emission.

#### M2 — Enforced executor gas was symmetric (250k both directions)
- **Where:** `layerzero.config.ts` applied 250k to both legs. Composed
  inbound on ETH (`_mint` + `endpoint.sendCompose` + LZ plumbing) realistically
  consumes ~200–220k, leaving only ~30k slack.
- **Fix (this branch):** options are split: BSC leg keeps 250k (plain
  unlock), ETH leg raised to 300k for the composed-inbound headroom.

#### M3 — DVN config 2-required + 0-optional (operator decision)
- **Where:** `layerzero.config.ts` declares `requiredDVNs = [LayerZero Labs,
  Google Cloud]`, `optionalDVNs = []`.
- **Status:** Open. 2-of-2-required means either DVN going down halts the
  bridge entirely. A 2-required + 1-optional model with a third independent
  DVN provides identical security at materially better liveness for one
  extra DVN fee per message.

#### M4 — `_credit` self-recipient and zero-recipient handling
- **Where:** `_credit` only redirected `address(0)` to `0xdead`; a recipient
  of `address(this)` was reachable as a free `seedReserve`, and the
  redirected zero-address case in the auto-unwrap branch burned real reserve
  to `0xdead` permanently.
- **Fix (this branch):** both `_to == address(0)` and `_to == address(this)`
  are routed to `0xdead`, and when redirected the path mints wON instead of
  burning real reserve. Real reserve is never sent to a dead recipient.

### LOW / cleanup

- Caret pragma in `contracts/mocks/ONOFTAdapterMock.sol` replaced with the
  exact pin `0.8.34` to match the project policy.
- `deploy/MyERC20Mock.ts` gated with `network.live` so a stray
  `--tags MyERC20Mock` cannot deploy a useless mock to mainnet.

### Outstanding (not auto-fixed; require operator decisions)

- **H3** confirmation depth policy.
- **M3** DVN topology (2-of-2 vs 2-required + 1-optional).
- Pre-deploy verification that Google Cloud DVN is live on both BSC and
  Ethereum mainnet.
- Bytecode diff between Foundry and Hardhat in CI.
- Migration plan if the ETH ON token ever upgrades to a fee-on-transfer or
  pausable behaviour.

## Acknowledged design trade-offs (not bugs)

The following are documented in `CLAUDE.md` and remain by design.

- **Front-running grief vector.** A wON holder can drain the reserve via
  `unwrap` while another user's BSC→ETH bridge is in flight, forcing them
  onto the wON fallback. Auto-unwrap is best-effort; integrators should not
  treat it as a guarantee.
- **`seedReserve` is one-way.** Donors receive no wON in return.
- **ON token pause / blacklist may stall a message.** If the ON token is
  paused or blacklists the recipient, the auto-unwrap branch reverts inside
  `_credit`, leaving the message retryable but undelivered until the lock
  lifts. There is an indirect recovery path: any wON holder can drain the
  reserve below the message amount, at which point the fallback-to-mint
  branch fires on retry.
- **Compose handler reverts strand wON at the handler address.** Standard
  OFT compose semantics: the mint is committed in `_lzReceive`; the compose
  call is dispatched separately by the executor. If the handler reverts,
  wON is held by the handler contract. Recovery is the handler's
  responsibility.

## Operator obligations

- Run `npm run test:dryrun` against archive RPCs before every mainnet
  deploy.
- Compress deploy → `lz:oapp:wire` → `tasks/handoff.ts` into a single
  operator session. Do not leave the deployer EOA as owner overnight.
- Monitor `WrappedON.reserve()` against a daily-flow threshold; refill via
  `wrap` (recoverable) or `seedReserve` (one-way subsidy) as needed.
- Subscribe to alerts on `UnwrapFallbackToMint` events: the false-positive
  case from M1 is gone, so every emission now indicates either a depleted
  reserve or a fee-on-transfer mismatch in the auto-unwrap path.
- Coordinate with the ON token issuer on both chains before any pause /
  upgrade / blacklist change.
