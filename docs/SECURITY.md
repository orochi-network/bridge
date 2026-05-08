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
| BSC ON token (`0x0e4F...1D48`) is lossless: `transferFrom(amount)` moves exactly `amount`. | `ONOFTAdapter` reports `amountSentLD` to LayerZero; ETH side credits the full amount. A silent FoT/rebase ⇒ unbacked wON. | Per-call delta guard in `_debit` (see Fix H1). Forked-mainnet dry-run also asserts losslessness today. |
| BSC ON has 18 decimals. | OFT shared-decimals math expects 18 LD. | Forked dry-run (`DryRun.t.sol`) and `WrappedON.constructor` both check 18. |
| ETH ON token (`0x33f6...B59d`) has 18 decimals. | wON is 18-decimal; 1:1 swap requires the reserve token to match. | Constructor `DecimalsMismatch` revert. |
| ETH ON token does not silently re-enter `WrappedON` from inside `safeTransfer`. | `_credit` and `unwrap` use checks-effects-interactions but do not gate with `ReentrancyGuard`. | Manual analysis: ON is a vanilla ERC20 (no ERC777-style hooks). Documented assumption. |
| Both DVNs (`LayerZero Labs`, `Google` — the DVN run by Google Cloud) act independently. | Compromise of either DVN halts the bridge but does not steal funds. Compromise of both ⇒ arbitrary message forgery. | Operational obligation (DVN diversity). Liveness probe: `yarn check:dvn`. |
| The deployer EOA is fully handed off to a multisig before going live. | Until handoff, the EOA can rewire peers and mint unbounded wON. | Tracked by the post-deploy checklist; automated by the `lz:oapp:handoff` task (Fix H2). |

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
- **Fix (this branch):** the `lz:oapp:handoff` Hardhat task (in
  `tasks/handoff.ts`) performs `setDelegate(multisig)` and
  `transferOwnership(multisig)` on a single network, ordered correctly,
  reading the multisig address from `OWNER_BSC` / `OWNER_ETH` env vars. The
  deploy/wire/handoff sequence should be performed in a single operator
  session.

#### H3 — BSC→ETH confirmations policy
- **Where:** `layerzero.config.ts` previously set BSC→ETH = 20 confirmations.
- **Why it matters:** 20 BSC blocks is *fast finality* per BNB Chain
  documentation but historical reorgs deeper than 20 blocks exist; a deeper
  reorg can re-order or drop a send the destination has already accepted.
- **Fix (this branch):** `BSC_TO_ETH_CONFIRMATIONS` raised from 20 to 30
  (~90s on BSC's ~3s blocks). The extra ~30s of latency is acceptable for
  the bridge's expected message profile and clears all historical reorg
  depths we have observed. ETH→BSC remains 15 (~3 min on ETH's 12s blocks).

### MEDIUM

#### M1 — `_lzReceive` composed branch duplicates upstream logic
- **Where:** `WrappedON._lzReceive` re-implemented the composed path inline,
  emitted `UnwrapFallbackToMint` on every composed message (false positive
  for any monitor watching that event), and was vulnerable to silent drift
  if upstream `OFTCore.lzReceive` ever changes.
- **Fix (this branch):** transient `_composedFlag` set in `_lzReceive`,
  then `super._lzReceive` is called and the composed path is implemented
  inside `_credit`. Single source of truth, no duplicated event emission.

#### M2 — Enforced executor gas was symmetric and missing for composed sends
- **Where:** `layerzero.config.ts` applied 250k to both legs and only
  configured `msgType: 1` (SEND). Composed inbound on ETH (`_mint` +
  `endpoint.sendCompose` + LZ plumbing) realistically consumes ~200–220k,
  leaving only ~30k slack on the symmetric budget. Worse, `msgType: 2`
  (SEND_AND_CALL) had no enforced `LZ_RECEIVE` gas at all — the very budget
  the 300k figure was sized for never applied to the path that needed it.
- **Fix (this branch):** options are split per leg AND per msgType. BSC leg
  is 250k (plain unlock); ETH leg is 300k for the composed-inbound headroom.
  Both `msgType: 1` and `msgType: 2` are enforced. `lzCompose` gas is
  intentionally left unenforced (application-specific).

#### M3 — DVN config 2-required + 0-optional
- **Where:** `layerzero.config.ts` declares
  `requiredDVNs = ['LayerZero Labs', 'Google']`, `optionalDVNs = []`.
- **Decision (this branch):** keep 2-of-2 required, no optionals. Either
  DVN going down halts the bridge entirely, but the simpler topology is the
  intended security posture: a delivery failure must be visible and
  triaged, not silently routed around. A third DVN would be added only if
  the operational cost of liveness incidents exceeded the cost of an extra
  DVN fee per message — which is not the case at the bridge's current
  message profile. Liveness is verified pre-deploy by `yarn check:dvn`.

#### M4 — `_credit` self-recipient and zero-recipient handling on both sides
- **Where:** Asymmetric on both contracts. `WrappedON._credit` only
  redirected `address(0)` to `0xdead`; a recipient of `address(this)` was
  reachable as a free `seedReserve` paid by the BSC sender, and the
  redirected zero-address case in the auto-unwrap branch burned real
  reserve to `0xdead` permanently. `ONOFTAdapter._credit` (inherited)
  guarded neither: a `_to == address(0)` recipient made the LZ message
  permanently undeliverable (OZ ERC20 rejects zero-address `safeTransfer`),
  and a `_to == address(adapter)` recipient was a self-transfer no-op that
  silently burned the user's funds while the LZ message was marked
  delivered (wON burned on ETH, ON still locked on BSC — conservation
  break).
- **Fix (this branch):** both contracts now redirect `address(0)` and
  `address(this)` to `address(0xdead)`. On `WrappedON._credit` the
  redirected path forces the mint branch so real reserve is never sent to
  a dead recipient. On `ONOFTAdapter._credit` the inner ON is transferred
  to `0xdead`, which is visible on-chain as a burn rather than a stuck or
  silently-lost message.

#### M5 — No throttle on outbound flow per EID

- **Where:** `ONOFTAdapter._debit` and `WrappedON._debit` (inherited from
  upstream OFT) accept arbitrarily large per-window outbound flow. A
  compromised hot key on a user account, or a contract-level exploit that
  drains an integrator, can move the entire bucket in a single block with
  no on-chain ceiling.
- **Why it matters:** the canonical reserve on BSC and the unwrap reserve
  on ETH are bounded resources. An unbounded drain is more destructive
  than a metered one — operators have no time-window to react before the
  reserve is gone.
- **Fix (this branch):** both contracts inherit the LayerZero
  `RateLimiter` extension and call the `_outflowOrSkip(dstEid, amountSentLD)`
  wrapper in `_debit` after the lossless-transfer guard. The wrapper
  delegates to upstream `_outflow` when the EID is configured and skips
  it for the all-zero `(limit=0, window=0)` sentinel — fail-open — so a
  freshly-deployed contract is usable before the multisig dials in
  production limits. `setRateLimits` rejects the silent-disable shape
  `(limit>0, window=0)` with `InvalidRateLimitConfig` to prevent a
  fat-finger from silently disabling enforcement (upstream's div-by-zero
  guard substitutes `window=1`, which would refill the bucket every
  block). Owner-only setters (`setRateLimits` / `resetRateLimits`) are
  exposed for the multisig.
- **Known limitation (acknowledged trade-off):** `(0, 0)` is the
  canonical "unconfigured / fail-open" sentinel and is
  indistinguishable from "operator wrote back to zero." Writing
  `setRateLimits([(eid, 0, 0)])` therefore RETURNS the EID to the
  unenforced state; it does NOT pause it. To halt outbound flow on an
  EID, write a deny-all config (`limit=1, window=type(uint64).max`) —
  documented in the README "Pausing an EID" section and called out
  inline on `_outflowOrSkip` in both contracts. We accepted this
  trade-off rather than introduce a separate `configured` storage flag
  (one extra SLOAD per `_debit` + one first-time SSTORE per EID): the
  deny-all idiom gives the operator a literal pause with the existing
  surface, and the README + NatSpec warn against the `(0, 0)`
  footgun.
  Inbound (`_credit`) is intentionally NOT rate-limited: an arrived
  message has already been debited on the source chain, so throttling it
  can only brick LayerZero delivery (the message becomes permanently
  stuck when the cap is hit) without recovering any tokens. Unconfigured
  EIDs (`limit==0 && window==0`) bypass the check so a freshly-deployed
  contract is usable before the multisig dials in production limits.
  Sizing guidance and the failure mode (`RateLimitExceeded`) are
  documented in the README "Rate limiting" section. Note: rate limiting
  bounds a *single-window* drain, not a sustained one — operators must
  still monitor cumulative outbound flow off-chain and tighten or reset
  if the protocol comes under attack across multiple windows.

### LOW / cleanup

- Caret pragma in `contracts/mocks/ONOFTAdapterMock.sol` replaced with the
  exact pin `0.8.34` to match the project policy.
- `deploy/MyERC20Mock.ts` gated with `network.live` so a stray
  `--tags MyERC20Mock` cannot deploy a useless mock to mainnet.
- Required DVN canonical name corrected from `'Google Cloud'` to `'Google'`
  in `layerzero.config.ts`. The LayerZero metadata registry's
  `canonicalName` for the DVN run by Google Cloud is `Google` (its `id` is
  `google-cloud`). `metadata-tools` does an exact (`===`) `canonicalName`
  match at `lz:oapp:wire` time — the same exact-match rule applies to
  executor names — and the previous string would have failed wire with
  `Can't find DVN: "Google Cloud" on chainKey: "bsc"`.
- Pre-deploy DVN liveness probe added (`scripts/check-dvn.js`, exposed as
  `yarn check:dvn`). Fetches the LZ metadata registry, resolves each
  required DVN canonical name to a per-chain address, then verifies the
  contract has bytecode and responds to `quorum()` on each mainnet.
- Bytecode-diff CI added (`.github/workflows/bytecode-diff.yml` +
  `scripts/check-bytecode.js`, exposed as `yarn check:bytecode`).
  Compares Hardhat and Foundry `deployedBytecode` for every production
  contract after stripping the CBOR metadata trailer (which embeds an IPFS
  hash that legitimately differs between toolchains because of source-path
  resolution). Asserts byte-identical runtime code on every PR touching
  `contracts/` or compiler settings. Stripped runtime is currently
  identical for both `ONOFTAdapter` (15,827 bytes) and `WrappedON`
  (20,685 bytes); rerun `yarn check:bytecode` to refresh after any
  contract or compiler-setting change.

### Resolved (no further action)

- **Migration plan if the ETH ON token ever upgrades.** Both ON tokens are
  immutable on their deployed addresses: BSC ON
  (`0x0e4F...1D48`) and ETH ON (`0x33f6...B59d`) have no owner-controlled
  upgrade path, no proxy, and the issuer has confirmed they will not be
  changed. There is no fee-on-transfer; protocol fees that may apply to
  the token live outside the ERC20 transfer path and do not affect the
  amount delivered by `transferFrom`. The losslessness invariant is
  re-asserted on every BSC-side send by the `_debit` balance-delta guard
  and on every ETH-side `wrap` / `seedReserve` by the
  `UnexpectedTransferAmount` guard, so any future deviation would surface
  as an explicit revert rather than silent loss.

### Outstanding (operator action items, not code changes)

- Run `yarn check:dvn` against archive RPCs immediately before every
  mainnet deploy, in addition to the existing `yarn test:dryrun`.
- After `lz:oapp:handoff`, the multisig must call `setRateLimits` on both
  contracts to apply production caps for the BSC↔ETH pathway. Until this
  runs, both EIDs are unconfigured and unlimited (the `(0, 0)` storage
  default is fail-open by design — see Fix M5 above and the README
  "Rate limiting" section).

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

## Rate-limiter operations

Both bridge contracts (`ONOFTAdapter` on BSC, `WrappedON` on Ethereum)
inherit the LayerZero `RateLimiter` mixin and expose two owner-only
mutators:

- `setRateLimits(RateLimitConfig[] calldata)` — set per-EID `(limit, window)`.
- `resetRateLimits(uint32[] calldata)` — zero `amountInFlight` for given EIDs.

`RateLimitConfig` is `(uint32 dstEid, uint192 limit, uint64 window)`. The
public mapping `rateLimits(dstEid)` returns the live state
`(amountInFlight, lastUpdated, limit, window)`.

### Capping outbound flow at 100,000 ON / hour

After the post-deploy handoff (CLAUDE.md post-deploy checklist Step 5;
README Step 12), the multisig calls `setRateLimits` on each contract.
To cap BSC→ETH outbound at 100,000 ON per hour:

```ts
// On BSC, multisig calls ONOFTAdapter.setRateLimits:
const cfg = [{
  dstEid: 30101,                       // Ethereum mainnet EID
  limit:  100_000n * 10n ** 18n,       // 100,000 ON, 18-decimal wei
  window: 3600,                        // 1 hour, in seconds
}]
await adapter.connect(multisig).setRateLimits(cfg)
```

Mirror on Ethereum to cap ETH→BSC outbound:

```ts
// On Ethereum, multisig calls WrappedON.setRateLimits:
const cfgEth = [{ dstEid: 30102, limit: 100_000n * 10n ** 18n, window: 3600 }]
await wON.connect(multisig).setRateLimits(cfgEth)
```

Buckets are independent per direction; capping only one side leaves the
other free to drain.

### Adjusting an existing limit

Calling `setRateLimits` with the same `dstEid` and a new `(limit, window)`
**preserves the running window's `amountInFlight`** — upstream
`_setRateLimits` checkpoints decay at the old rate before the new rate
kicks in, so a tightening cannot retroactively wipe accounting.

To explicitly clear `amountInFlight` (e.g. after a confirmed incident
response) without changing the limit, use `resetRateLimits`:

```ts
await adapter.connect(multisig).resetRateLimits([30101])
```

This zeros only the in-flight counter; `(limit, window)` are untouched.

### Emergency stop

`(0, 0)` is **fail-open**, not pause. To halt outbound flow on an EID,
write a deny-all config:

```ts
const denyAll = [{
  dstEid: 30101,
  limit:  1n,                                  // smallest legal value: validator
                                                // rejects (limit>0, window=0), so
                                                // limit must be ≥1 alongside max window
  window: 18_446_744_073_709_551_615n,         // type(uint64).max
}]
await adapter.connect(multisig).setRateLimits(denyAll)
```

The decay rate is `1 / type(uint64).max ≈ 0`, so the bucket effectively
never refills. Any non-zero outbound reverts with `RateLimitExceeded` on
the source-chain `send()` **before** any LayerZero plumbing engages —
users keep their funds. `setRateLimits` also preserves `amountInFlight`
across the deny-all transition (upstream `_setRateLimits` does NOT reset
`amountInFlight` / `lastUpdated` — see `RateLimiter.sol:183`), so the
running window does not bleed during the pause and a subsequent un-pause
inherits exactly the in-flight state at the moment the deny-all landed.

To resume, the multisig has two paths:

1. **Carry-over** — write the production config back via `setRateLimits`.
   `amountInFlight` is preserved, so the bucket immediately reflects any
   accounting accumulated up to the pause. Use this when the pause was
   precautionary and you want continuity with the prior window.
2. **Clean-bucket** — call `resetRateLimits([dstEid])` first to zero
   `amountInFlight`, then `setRateLimits` to write the production config.
   Use this after a confirmed incident response, when the pre-pause
   window's accounting is no longer trusted.

The `setRateLimits` validator additionally rejects the silent-disable
shape `(limit>0, window=0)` with `InvalidRateLimitConfig` (upstream
`_amountCanBeSent` substitutes `window = 1` to avoid div-by-zero, which
would refill the bucket every block while reporting a healthy
"configured" state).

### Verifying state

Before and after every change, signers should read the live state on
both chains:

```sh
cast call $ADAPTER_BSC \
  "rateLimits(uint32)(uint192,uint64,uint192,uint64)" 30101 \
  --rpc-url $RPC_URL_BSC
# Returns: (amountInFlight, lastUpdated, limit, window)
```

The upstream `RateLimiter` mixin emits two security-sensitive events
that an off-chain audit trail must index together:

- `RateLimitsChanged(RateLimitConfig[] rateLimitConfigs)` — every
  successful `setRateLimits` call (initial config, tightening, loosening,
  deny-all, and resume).
- `RateLimitsReset(uint32[] eids)` — every successful `resetRateLimits`
  call. This zeros `amountInFlight` and is the security-relevant signal
  for "incident response cleared the running window's accounting".

Indexing only `RateLimitsChanged` will miss the reset events; indexing
both gives a complete record of every cap change and every accounting
clear, with which signer proposed each, when it landed, and on which
contract.

Cross-references: full sizing guidance and the operator workflow live in
[README.md "Rate limiting"](../README.md#rate-limiting); the high-level
model is in [CLAUDE.md "Rate limiting"](../CLAUDE.md#rate-limiting).

## Operator obligations

- Run `yarn test:dryrun` against archive RPCs before every mainnet
  deploy.
- Run `yarn check:dvn` immediately before `lz:oapp:wire` to confirm
  both required DVNs are reachable on BSC and Ethereum mainnet.
- Compress deploy → `lz:oapp:wire` → `lz:oapp:handoff` into a single
  operator session. Do not leave the deployer EOA as owner overnight.
- Monitor `WrappedON.reserve()` against a daily-flow threshold; refill via
  `wrap` (recoverable) or `seedReserve` (one-way subsidy) as needed.
- Subscribe to alerts on `UnwrapFallbackToMint` events: the false-positive
  case from M1 is gone, so every emission now indicates either a depleted
  reserve or a fee-on-transfer mismatch in the auto-unwrap path.
- Configure outbound rate limits on both contracts via `setRateLimits`
  immediately after the multisig handoff (README Step 13 / CLAUDE.md
  post-deploy checklist Step 7). Unconfigured EIDs are fail-open — the
  bridge is usable from block one but unprotected against single-block
  drain until the multisig dials limits in. To halt flow on an EID, use
  the deny-all idiom (`limit=1, window=type(uint64).max`) — do NOT
  write `(0, 0)`, which fail-opens. See README "Rate limiting" and
  "Pausing an EID" for the calldata.
- Monitor cumulative outbound flow per EID off-chain. The on-chain
  `RateLimiter` only bounds a single window; sustained attack traffic
  can still drain over several windows. Tighten or reset limits if
  cumulative flow looks anomalous.
- Coordinate with the ON token issuer on both chains before any pause /
  upgrade / blacklist change.
