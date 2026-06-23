# Security Review — ON CCIP Bridge

This document is the consolidated output of a multi-agent security review of the
Orochi Network ON CCIP Bridge. It covers the custom contract, deployment
scripts, CCIP integration, test suite, and operational surface.

## Remediation status (2026-05-19 pass)

After the initial review, each finding was re-validated against actual code and
addressed. Status field added to every finding. Tag legend:

| Status              | Meaning                                                                                          |
|---------------------|--------------------------------------------------------------------------------------------------|
| `FIXED`             | Code/config/doc change landed in this remediation pass.                                          |
| `DOC ADDED`         | Finding resolved via NatSpec / inline comment / runbook clarification (no behaviour change).     |
| `FALSE POSITIVE`    | Re-validation showed the issue does not exist as described, or is already addressed in-tree.     |
| `ALREADY ADDRESSED` | Closed before this review pass began (e.g. by the SECURITY.md restoration commit itself).        |
| `DESIGN ACK`        | Pre-existing INFO entry retained for record; no action taken because the design choice is sound. |
| `DEFERRED`          | Valid but not implemented in this pass; tracked for pre-mainnet follow-up.                       |

Counts after this pass:

| Status              | Count |
|---------------------|------:|
| FIXED               |    76 |
| DOC ADDED           |     7 |
| FALSE POSITIVE      |     6 |
| ALREADY ADDRESSED   |     1 |
| DESIGN ACK          |    10 |
| DEFERRED            |     4 |
| **Total**           | **104** |

(11 of the entries are "investigated, no defect" — `CCIP-5` plus 10 `DESIGN ACK`
items including the WON-10/15/18, DEP-14/21, OPS-20 acknowledgements — so the
effective resolution rate on actionable findings is 89 / 93. FIXED count includes
one FIXED-partial: `DEP-3`.)

Tests after the remediation pass: **130 passing, 0 failing** (was 121 before the
third-pass review; this round added 9 net new tests covering WON-11 burn zero-amount
guards, WON-14 received-zero, TEST-16 reentrancy-mock hardening, TEST-17 BSC
RMN curse, TEST-20 four typed-revert paths through `MockBadPool`).

Four findings remain `DEFERRED`:

- **TEST-7** (LOW) — requires live mainnet investigation of the BSC ON token's
  admin path before the fork test can be tightened.
- **OPS-8** (LOW) — Slither CI gating left advisory until immediately before
  mainnet broadcast; will be flipped to `--fail-on HIGH` then.
- **OPS-13** (LOW) — SARIF upload + Code-Scanning visibility bundled with the
  OPS-8 pre-mainnet workflow commit so both land together.
- **OPS-27** (INFO) — README submodule SHA table bundled with the same
  pre-mainnet workflow commit.

All originally-HIGH findings (CCIP-1, DEP-1, TEST-1, TEST-2, OPS-1, OPS-2) and
DEP-8 (HIGH, added in the second-pass review) are `FIXED`.

- **Scope:** `src/`, `script/`, `test/`, `Makefile`, `foundry.toml`, `.gitmodules`,
  `README.md`, `RUNBOOK.md`, `CLAUDE.md`, `.github/workflows/`, `.env.example`.
- **Out of scope:** vendored code in `lib/chainlink-ccip`, `lib/chainlink-evm`, and
  `lib/openzeppelin-contracts` (audited upstream; pinned at `contracts-ccip-v1.6.1` /
  `contracts-v1.4.0` / OZ 5.x).
- **Methodology:** 5 reviewers worked independently in parallel — one per area —
  each producing findings with substantiated code references.
- **Reviewers / ID prefixes:**
  - `WON-*` — `src/WrappedON.sol` contract review
  - `DEP-*` — Deployment scripts (`script/01..08`)
  - `CCIP-*` — CCIP integration, pool wiring, rate limits, trust model
  - `TEST-*` — Test coverage and quality
  - `OPS-*` — Build, docs, env handling, CI, operator runbook

Every finding has a unique ID. Numbering may be non-contiguous where an
investigation closed without a finding; those slots are preserved as INFO
records so future references remain stable.

## Disclosure

Report vulnerabilities privately to `security@orochi.network` before public
disclosure. Do not file public GitHub issues for unpatched security findings
on this repository.

## Severity definitions

| Severity   | Meaning                                                                                  |
|------------|------------------------------------------------------------------------------------------|
| CRITICAL   | Direct funds-loss or trust-breaking path with a realistic attack precondition.           |
| HIGH       | Significant fund-loss, lockup, or trust-degrading path; or a substantial operator footgun. |
| MEDIUM     | Meaningful correctness, recovery, or operability issue; partial mitigation exists.       |
| LOW        | Minor correctness or hygiene issue; primarily a polish or documentation gap.             |
| INFO       | Investigated and confirmed not a defect, or a design acknowledgement worth recording.    |

## Summary

| Area  | CRITICAL | HIGH | MEDIUM | LOW | INFO | Total |
|-------|---------:|-----:|-------:|----:|-----:|------:|
| WON   |        0 |    0 |      3 |  10 |    7 |    20 |
| DEP   |        0 |    2 |      4 |  12 |    4 |    22 |
| CCIP  |        0 |    1 |      6 |   4 |    3 |    14 |
| TEST  |        0 |    2 |      9 |   9 |    0 |    20 |
| OPS   |        0 |    2 |      4 |  18 |    6 |    30 |
| **Total** | **0** | **7** | **26** | **53** | **20** | **106** |

**Headline:** no CRITICAL findings. The custom contract surface (`WrappedON.sol`)
is clean — the three MEDIUM WON findings are all resolved (WON-19 reversed by
product decision; WON-20 fixed by removing auto-unwrap), so the highest *open*
WON finding is LOW. The bulk of the actionable risk
sits in the operational surface (key handling, post-handoff workflows,
documentation gaps) and in tightening test rigor (fork pinning, invariant
config, typed revert expectations). The single most impactful invariant —
`lockedON_BSC + reserveON_ETH >= totalSupply(wON)` — is structurally upheld;
the `MAX_CCIP_MINTED` cap, however, is an approximation rather than a hard
lifetime bound (see CCIP-7).

## Top priorities before mainnet — all originally-HIGH findings closed

All six findings originally tagged HIGH (`CCIP-1`, `DEP-1`, `TEST-1`, `TEST-2`, `OPS-1`,
`OPS-2`) are now `FIXED`. See the per-finding status entries below for the specific
remediation. The only remaining open items are `TEST-7` (LOW, deferred until the BSC
ON token admin path is concluded — see CLAUDE.md "Known open items") and `OPS-8`
(LOW, Slither gating flipped to fail-on-HIGH immediately before mainnet broadcast).

---

# Findings

## WrappedON.sol (`WON-*`)

### WON-1: `mint` does not guard against zero-amount calls
- **Severity:** LOW
- **Status:** FIXED — `mint` now reverts `ZeroAmount` on zero. Test: `test_MintRevertsOnZeroAmount`.
- **Location:** `src/WrappedON.sol:221-235`
- **Description:** `deposit` and `withdraw` both revert on `amount == 0`, but `mint` (the CCIP entrypoint) does not. A zero-amount call increments nothing and mints nothing, but it emits an ERC20 `Transfer(pool, account, 0)` event and an OZ AccessControl check passes silently. Under normal CCIP operation the pool will never pass zero, but the asymmetry is worth eliminating for indexer hygiene and to match the pattern of every other state-mutating entry point in the contract.
- **Impact:** No meaningful state harm; a misbehaving or test pool can spam zero-value Transfer events. No financial loss.
- **Recommendation:** Add `if (amount == 0) revert ZeroAmount();` at the top of `mint`, matching the `deposit`/`withdraw` guards.

### WON-2: `burn(address,uint256)` overload burns without allowance — design acknowledgement
- **Severity:** INFO
- **Status:** DESIGN ACK — the recommended on-chain count check requires `AccessControlEnumerable`, which expands inheritance for marginal benefit. The single-pool invariant is enforced operationally: script 03 (`GrantRoles`) only grants to the deployed pool, the multisig handoff transfers admin to a Safe, and the RUNBOOK monitoring table pages on every `RoleGranted(BURNER_ROLE, *)`. Adding `AccessControlEnumerable` is left as an option for a future redeploy if multi-grantee scenarios become realistic.
- **Location:** `src/WrappedON.sol:254-259`
- **Description:** The two-argument `burn(address account, uint256 amount)` overload calls `_burn(account, amount)` with no `_spendAllowance` check, matching the `IBurnMintERC20` interface contract. The test at `test/WrappedON.t.sol:264` explicitly verifies this. Safety relies entirely on `BURNER_ROLE` exclusivity. If `BURNER_ROLE` were ever granted to more than one address, any role holder could burn arbitrary balances without delegation.
- **Impact:** Single-pool deployment is safe; multi-grantee deployment is not.
- **Recommendation:** Add a `getRoleMemberCount(BURNER_ROLE) <= 1` post-deploy assertion to `script/08_PostDeployVerify.s.sol`, and document the constraint in the multisig handoff runbook.

### WON-3: `ccipMintHeadroomUsed` can be depressed below true BSC-locked balance
- **Severity:** LOW
- **Status:** FIXED — RUNBOOK monitoring table now keys on `IERC20(ON).balanceOf(BSC_LockReleaseTokenPool)` as the authoritative locked-balance read with an explicit note that `ccipMintHeadroomUsed` is a local indicator only. **M1 / #23:** the counter was additionally renamed `ccipMintedSupply` → `ccipMintHeadroomUsed` (and `_decrementCcipMinted` → `_decrementCcipMintHeadroom`) so the name no longer implies it tracks BSC-side minted/locked supply — it is a CCIP mint-cap *headroom* counter. This is the chosen alignment for QuillAudits **M1** (the "soft headroom counter" option): keep the saturating subtract, rename so no name/doc presents it as a BSC-liquidity proxy; authoritative exposure stays `BSC_ON.balanceOf(BSC_pool)`.
- **Location:** `src/WrappedON.sol` (`ccipMintHeadroomUsed`, `_decrementCcipMintHeadroom`)
- **Description:** The saturating-decrement in `_decrementCcipMintHeadroom` is intentional: it handles deposit-backed wON being bridged outbound without underflowing. The consequence is that `ccipMintHeadroomUsed` can read zero while a non-trivial amount of BSC-locked ON exists. Monitoring alerts keyed only to `ccipMintHeadroomUsed` approaching `MAX_CCIP_MINTED` may produce false negatives. (Closely related to CCIP-7.)
- **Impact:** `ccipMintHeadroomUsed` is not a reliable real-time BSC-exposure gauge. Operational/monitoring risk only.
- **Recommendation:** RUNBOOK monitoring guidance should key on the BSC `LockReleaseTokenPool` locked balance (on-chain call or event index) alongside `ccipMintHeadroomUsed`.

### WON-4: No named event emitted on `mint` / `burn` paths
- **Severity:** LOW
- **Status:** FIXED — `CCIPMinted(account, amount, ccipMintHeadroomUsed)` emitted from `mint`; `CCIPBurned(account, amount, ccipMintHeadroomUsed)` emitted from all three burn entrypoints. Tests: `test_MintEmitsCCIPMinted`, `test_BurnEmitsCCIPBurned_*`.
- **Location:** `src/WrappedON.sol:221-235` (mint), `242-268` (burn entrypoints)
- **Description:** `deposit` emits `Wrapped`, `withdraw` emits `Unwrapped`, but the CCIP `mint` path emits only the inherited ERC20 `Transfer(address(0), account, amount)`. Burns are similar. Indexers cannot distinguish CCIP-inbound mints from deposit wraps by event topic alone.
- **Impact:** Cross-chain reconciliation tooling must correlate with pool-level CCIP events.
- **Recommendation:** Add `CCIPMinted(address indexed account, uint256 amount, uint256 ccipMintHeadroomUsed)` (and optionally `CCIPBurned`) for direct on-chain auditability.

### WON-5: Overwriting pending CCIP admin produces no cancellation event
- **Severity:** LOW
- **Status:** FIXED — `CCIPAdminProposalCancelled(address)` emitted in `setCCIPAdmin` when overwriting a different pending address. Identical re-proposal does NOT emit (verified by `test_SetCCIPAdminRePropose_DoesNotEmitCancellation`). Test: `test_SetCCIPAdminEmitsCancellationWhenOverwritten`.
- **Location:** `src/WrappedON.sol:287-313`
- **Description:** `setCCIPAdmin` allows the current admin to overwrite `s_pendingCcipAdmin` with a new address at any time. The prior proposed address receives no on-chain cancellation signal. If they had a multisig transaction queued for `acceptCCIPAdmin`, it will revert with `OnlyPendingCCIPAdmin`.
- **Impact:** Operational confusion; no funds at risk.
- **Recommendation:** Emit `CCIPAdminProposalCancelled(address indexed cancelled)` when overwriting a non-zero pending admin with a different address.

### WON-6: `withdraw` orders balance-check before burn — currently safe
- **Severity:** INFO
- **Status:** DESIGN ACK — no code change. Recorded for completeness.
- **Location:** `src/WrappedON.sol:199-210`
- **Description:** Current ordering: read `ON.balanceOf(this)` → revert if insufficient → `_burn` → `safeTransfer`. With ON as a plain non-hookable ERC20 and `nonReentrant` active, no attack path exists. This is purely a defensive note: if `ON` were ever replaced by an ERC-777-style token with receiver hooks, the ordering would still be correct because reentry would observe the post-burn `totalSupply`.
- **Impact:** None under current ON token.
- **Recommendation:** No code change required. The `ON` immutable + non-upgradeable design closes this path.

### WON-7: `supportsInterface` omits `IERC20Metadata`
- **Severity:** INFO
- **Status:** FIXED — `IERC20Metadata.interfaceId` added to `supportsInterface`. Test updated: `test_SupportsInterfacePositiveAndNegative` now asserts `true`.
- **Location:** `src/WrappedON.sol:330-334`
- **Description:** The contract satisfies `IERC20Metadata` (via OZ ERC20) but does not return `true` for its interface ID. Integrations that ERC-165-check before reading `decimals()` will get a false negative.
- **Impact:** Minor integration friction; no security risk.
- **Recommendation:** Add `|| interfaceId == type(IERC20Metadata).interfaceId`.

### WON-8: Constructor `decimals()` call lacks try/catch
- **Severity:** MEDIUM
- **Status:** FALSE POSITIVE — the constructor is only deployable against a canonical ON token whose interface and value are fixed at the project level. ON on Ethereum (`0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d`, 600M supply) and ON on BSC (`0x0e4F6209eD984b21EDEA43acE6e09559eD051D48`, 100M supply) are both immutable non-upgradeable ERC20Metadata implementations with `decimals() == 18`. `Helper.getConfig(block.chainid)` hardcodes these mainnet addresses, and the `01_DeployWrappedON` script reads `onToken` from `Helper.getConfig()` rather than from operator input. There is no realistic deploy path where `decimals()` returns a non-18 value or reverts — the equality check `onDecimals != decimals()` already provides the only defence the architecture supports. Adding a try/catch + zero-check would be a defensive no-op that doesn't move the threat model.
- **Location:** `src/WrappedON.sol:149-152`
- **Description:** `IERC20Metadata(onToken).decimals()` is called without try/catch in the constructor. A non-`IERC20Metadata` token with a fallback returning 18-like bytes would pass; a token returning `0` would pass only if wON's `decimals()` were changed from 18.
- **Impact:** None under the canonical-token constraint.
- **Recommendation:** No code change. The deploy-time controls (hardcoded canonical addresses + non-mintable, non-upgradeable ON token) are the load-bearing guarantee.

### WON-9: `Wrapped` event field labelled `amount` carries the post-fee `received` value
- **Severity:** LOW
- **Status:** FIXED — event signature renamed to `Wrapped(address indexed account, uint256 received)` so indexers using the parameter name (e.g. via the deployed ABI JSON) see the post-fee semantics directly. The wire format / topic is unchanged because event-parameter names are not part of the keccak signature, so existing decoders keyed off `Transfer`/`Wrapped(address,uint256)` continue to match. NatSpec on the event now spells out the received-amount semantics. The corresponding `Unwrapped` event remains `amount`-labelled because `withdraw` operates against a non-hookable internal reserve and there is no fee-on-transfer asymmetry to disclose.
- **Location:** `src/WrappedON.sol:101` (`Wrapped` event), `164-192` (`deposit`)
- **Description:** `deposit` uses received-amount accounting (computes `received = balanceAfter - balanceBefore`) so the credited wON tracks the actual transfer, including any fee-on-transfer skim. The emitted event field was labelled `amount`, suggesting it matched the caller-supplied argument; under a fee-on-transfer token the two diverge.
- **Impact:** Indexers correlating against the caller-supplied `amount` argument would see a mismatch with the post-fee credit. No funds at risk.
- **Recommendation:** Rename to `received` or add a second parameter making the requested amount explicit.

### WON-10: `acceptCCIPAdmin` lacks defence-in-depth `address(this)` guard
- **Severity:** INFO
- **Status:** DESIGN ACK — `setCCIPAdmin` already rejects `address(this)` via `InvalidCCIPAdmin` (round-6 R-56), so the path to `s_pendingCcipAdmin == address(this)` is structurally closed. Adding the same guard to `acceptCCIPAdmin` would be symmetric belt-and-suspenders only; no realistic attack path. Recorded for completeness — left out to keep the contract surface minimal.
- **Location:** `src/WrappedON.sol:317-324`
- **Description:** `acceptCCIPAdmin` does not redundantly check `msg.sender != address(this)`. Even if the pending slot were somehow forced to `address(this)`, no external caller can satisfy `msg.sender == address(this)` without a recursive `address(this).call(…)` — which the contract never makes.
- **Impact:** None under current logic.
- **Recommendation:** Optional. If the maintainer prefers symmetry, add `if (msg.sender == address(this)) revert InvalidCCIPAdmin();` at the top of `acceptCCIPAdmin`.

### WON-11: Burn entrypoints lack the `ZeroAmount` guard that `mint` has
- **Severity:** LOW
- **Status:** FIXED — added `if (amount == 0) revert ZeroAmount();` to all three burn overloads (`burn(uint256)`, `burn(address,uint256)`, `burnFrom`). Mirrors the WON-1 mint guard. New tests: `test_BurnRevertsOnZeroAmount_SingleArg`, `test_BurnRevertsOnZeroAmount_AddressOverload`, `test_BurnFromRevertsOnZeroAmount`.
- **Location:** `src/WrappedON.sol:242-268`
- **Description:** WON-1 closed `mint(0)`. The three burn paths emitted `CCIPBurned(account, 0, supply)` on zero-amount calls, polluting indexer accounting.
- **Impact:** Indexer audit-trail noise. No funds at risk.
- **Recommendation:** Add the zero-amount guard symmetrically.

### WON-12: `CCIPAdminProposalCancelled` event emitted before state write
- **Severity:** LOW
- **Status:** FIXED — `s_pendingCcipAdmin = newAdmin` now happens before either event emits. No reentrancy risk in either order (no external calls), but emitting after the state write matches the `mint`/`burn`/`acceptCCIPAdmin` order and prevents an indexer subscribing to `CCIPAdminProposalCancelled` from reading the stale `pendingCCIPAdmin()` in the same block.
- **Location:** `src/WrappedON.sol:287-313`
- **Description:** Effects-events inversion vs the rest of the contract. Consistency only.
- **Impact:** None for funds; potential indexer race only.
- **Recommendation:** Reorder to state-write-then-emit.

### WON-13: `CCIPBurned` re-reads `ccipMintHeadroomUsed` from storage
- **Severity:** LOW
- **Status:** FIXED — `_decrementCcipMintHeadroom` now returns the new supply; each burn path emits the local return value (saves one SLOAD per burn × 3 sites, matches the `mint` path's `wouldBe`-local pattern).
- **Location:** `src/WrappedON.sol:242-268` (burn entrypoints), `345-359` (`_decrementCcipMintHeadroom` + `_ccipBurn`)
- **Description:** Asymmetric with the `mint` path which emits the local `wouldBe`. Identical pattern in three places was a refactor smell.
- **Impact:** Gas only.
- **Recommendation:** Return-value refactor on `_decrementCcipMintHeadroom`.

### WON-14: `deposit` admits a `received == 0` no-op path
- **Severity:** LOW
- **Status:** FIXED — `deposit` now rejects `received == 0` post-transfer with `ZeroAmount`. Mirrors the WON-1 mint guard for the deposit path. New test: `test_DepositRevertsOnReceivedZero` using a mock whose `transferFrom` returns `true` without moving anything.
- **Location:** `src/WrappedON.sol:164-192`
- **Description:** A 100%-fee or buggy ERC20 whose `transferFrom` returned `true` without state change would let `deposit(N)` mint zero wON and emit `Wrapped(_, 0)`. Canonical ON cannot hit this; the received-amount accounting is itself the defensive accommodation for non-canonical variants — so a symmetric guard is consistent.
- **Impact:** Indexer audit-trail noise; no funds at risk.
- **Recommendation:** Add the post-transfer zero-amount guard.

### WON-15: `Unwrapped` event keeps `amount` while `Wrapped` uses `received` (asymmetric semantics)
- **Severity:** INFO
- **Status:** DESIGN ACK — kept `Unwrapped(account, amount)` because `withdraw` is internal-reserve-only: `safeTransfer` from the contract's own balance to the user has no fee-on-transfer asymmetry on canonical ON. Added explicit NatSpec on the event documenting the asymmetry (vs WON-9's `Wrapped(received)` rename) so a future fee-on-transfer ON variant would not silently misreport. Symmetrizing to a `received`-style accounting on `withdraw` would require received-amount tracking at the recipient — which the contract can't observe without trust assumptions on the recipient.
- **Location:** `src/WrappedON.sol:101-108`
- **Description:** Same field name in a sibling event masks the difference in semantics between the two paths.
- **Impact:** Documentation-only under canonical ON.
- **Recommendation:** Inline NatSpec on `Unwrapped`.

### WON-16: `mint` per-function NatSpec understates the CCIP-7 cap-replenishment behaviour
- **Severity:** INFO
- **Status:** FIXED — `mint`'s docstring now cross-references the contract-level CAP REPLENISHMENT block (CCIP-7) and explicitly says the cap is a live BSC-balance approximation, not a lifetime CCIP-mint ceiling. The previous wording ("so deposit-backed wON does not consume it") suggested a clean separation between the deposit and CCIP-mint paths' impact on the counter, which is misleading once deposit-backed wON is bridged out.
- **Location:** `src/WrappedON.sol:214-235`
- **Description:** Per-function NatSpec contradicted the more detailed contract-level block. An auditor reading `mint`'s docstring first formed an incorrect mental model.
- **Impact:** Documentation only.
- **Recommendation:** Rephrase to match the contract-level block.

### WON-17: CCIP `mint`/`burn` entrypoints lack `nonReentrant`
- **Severity:** LOW
- **Status:** FIXED — added `nonReentrant` to `mint`, `burn(uint256)`, `burn(address,uint256)`, `burnFrom`. Defence-in-depth: OZ 5.x ERC20 has no hooks, so reentry via `_mint`/`_burn` cannot happen against the current code — but a future OZ release or a subclass override adding an `_update` hook would expose a `ccipMintHeadroomUsed` desync window. The `deposit`/`withdraw` paths already carry `nonReentrant`; consistency was worth the ~2.5k gas/call.
- **Location:** `src/WrappedON.sol:221, 242, 254, 262`
- **Description:** The CCIP-side entrypoints didn't carry the same modifier as the wrap-side, so a hookable-token redeploy or a future OZ subclass change could open a same-tx reentry. Existing invariants pass under the new modifier.
- **Impact:** No active exploit path against current OZ ERC20; forward-compat hardening.
- **Recommendation:** Mirror `nonReentrant` from `deposit`/`withdraw`.

### WON-18: `mint`/`burn` cross-function reentrancy not under direct test
- **Severity:** INFO
- **Status:** DESIGN ACK — `WON-17` adds `nonReentrant` to all four CCIP entrypoints, which is the structural fix. The TEST-8 deposit-side reentry test (now hardened by TEST-16 to assert the specific `ReentrancyGuardReentrantCall` selector) exercises the OZ guard's behaviour against a hook-bearing token; adding a parallel CCIP-side test would be belt-and-suspenders since the same `nonReentrant` modifier is in play. Recorded so a future deploy against a hookable-ERC20 token has a single canonical follow-up: extend TEST-8's pattern to the CCIP path.
- **Location:** `test/WrappedON.t.sol`, `src/WrappedON.sol:221, 242, 254, 262`
- **Description:** No malicious-burner-pool mock exercises a same-tx reentry from `burn → mint` or vice versa.
- **Impact:** Forward-compat only.
- **Recommendation:** Defer to redeploy if the bridge is ever wired to a hookable ON variant.

### WON-19: public uncapped `deposit` could grow wON supply past sized launch liquidity (QuillAudits M3)
- **Severity:** MEDIUM
- **Status:** REVERSED (2026-06-23) by product decision — `deposit` is permissionless again; `LIQUIDITY_MANAGER_ROLE` removed entirely. Original FIXED status (below) preserved as history. See two residual-risk notes appended after the description.
- **Previous status (now superseded):** FIXED — `deposit` was gated to `LIQUIDITY_MANAGER_ROLE` (issue [#25](https://github.com/orochi-network/bridge/issues/25)). The constructor seeded the role to the bootstrap admin, script 06 granted it to the multisig at handoff, and `RenounceDeployerAdmin` renounced the deployer's grant. Tests: `test_DepositRevertsWithoutLiquidityManagerRole`, `test_DepositSucceedsWithLiquidityManagerRole`, `test_ConstructorGrantsLiquidityManagerRoleToAdmin`, `test_AdminCanRevokeLiquidityManagerRole` (WrappedON.t.sol).
- **Location:** `src/WrappedON.sol` (`deposit`).
- **Description:** QuillAudits *Wrapped ON* Finding M3. `deposit()` was public and uncapped: any ETH-ON holder could mint wON 1:1. The team intends to seed a *limited* ETH-side reserve (≈10M, up to 100M). A public wrap lets anyone convert ETH ON → wON freely, which does not break the aggregate supply invariant but can grow wON supply — and therefore ETH→BSC redemption demand — beyond the BSC liquidity and rate limits the launch was sized for (compounding M2 / CCIP-2 stuck-message pressure).
- **Impact (original):** A limited-liquidity launch would otherwise expose a public, uncapped conversion path; redemption demand toward BSC could exceed available BSC pool liquidity.
- **Recommendation (original):** (Was implemented) restrict `deposit` to a protocol-managed `LIQUIDITY_MANAGER_ROLE`. Per-window ETH→BSC redemption is then bounded by what the role-holder wraps plus the BSC inbound rate limits (see RUNBOOK §4.5).
- **Residual risk note A — permissionless deposit:** With `deposit` permissionless and uncapped, wON supply growth and ETH→BSC redemption demand are bounded only by the ETH-side ON circulating supply (600M) and the configured CCIP pool rate limits. The aggregate safety invariant (`lockedON_BSC + reserveON_ETH >= totalSupply(wON)`) continues to hold mechanically, but burst ETH→BSC redemption pressure is no longer capped by role access. Operators must size BSC pool liquidity and ETH→BSC rate limits conservatively (see RUNBOOK §4.5).
- **Residual risk note B — auto-unwrap reserve drain (RETIRED 2026-06-23, see WON-20):** An earlier draft had `WrappedON.mint` auto-unwrap — transferring native ON out of the reserve when it covered a BSC→ETH arrival — which let a compromised `MINTER_ROLE` pool drain the reserve via fabricated inbound messages. Auto-unwrap was removed (issue [#48](https://github.com/orochi-network/bridge/issues/48)) before redeploy: `mint` now only mints wON and never touches the reserve, so this vector no longer exists. The reserve can only ever leave via `withdraw` (caller burns their own wON). See WON-20.

### WON-20: auto-unwrap could deliver native ON to contract receivers expecting wON (BSC→ETH)
- **Severity:** MEDIUM
- **Status:** FIXED (2026-06-23) — auto-unwrap removed from `WrappedON.mint`. The CCIP `releaseOrMint` path now always mints wON (the registered token) to every receiver, EOA or contract; it never reads the reserve or delivers native ON. The asset a BSC→ETH receiver gets is deterministic. Tests: `test_MintMintsWonEvenWhenReserveCovers`, `test_MintMintsWonAtExactReserve`, `test_MintToContractReceiverMintsWon`, `testFuzz_MintAlwaysMintsWonRegardlessOfReserve` (WrappedON.t.sol); `test_BscToEth_MintsWonEvenWhenReserveCovers` (PoolRoundtrip.t.sol); `test_Fork_ETH_BscToEth_MintsWonEvenWhenReserveCovers` (Fork_ETH.t.sol). Retires residual-risk note B above.
- **Location:** `src/WrappedON.sol` (`mint`).
- **Description:** Issue [#48](https://github.com/orochi-network/bridge/issues/48). The auto-unwrap branch added in [#45](https://github.com/orochi-network/bridge/pull/45) delivered native ON (and minted 0 wON) when `ON.balanceOf(wON) >= amount`. For CCIP *programmatic* token transfers (token + data), a contract receiver coded to expect `amount` wON would instead observe 0 new wON and an unexpected native-ON balance — breaking its wON-based accounting or stranding value. The trigger was **front-runnable**: `deposit`/`withdraw` are permissionless, so anyone could move `ON.balanceOf(wON)` across the `>= amount` boundary in the same block, flipping the delivered asset. A BSC→ETH sender could not predict which asset their receiver got.
- **Impact:** Integration footgun for contract receivers on the BSC→ETH lane. No protocol-invariant violation — `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` held throughout. EOA receivers were unaffected (native ON was the intended outcome for them).
- **Recommendation:** (Implemented) remove auto-unwrap; always mint wON on the CCIP path. Holders who want native ON call `withdraw`. This eliminates the front-runnable asset switch at the source and shrinks the trust surface — the `mint` path can no longer move ON out of the reserve. Alternatives considered and rejected: EOA-gating the auto-unwrap (`account.code.length == 0`) and documentation-only; see `docs/superpowers/specs/2026-06-23-won-remove-autounwrap-design.md`.

---

## Deployment scripts (`DEP-*`)

### DEP-1: Script 04 is not idempotent after partial broadcast
- **Severity:** HIGH
- **Status:** FIXED — script 04 now probes `TokenAdminRegistry.getTokenConfig(token)` before broadcasting; skips the register / accept / setPool steps individually based on observed state. Re-running after a partial failure is now safe at every step.
- **Location:** `script/04_RegisterAdminAndPool.s.sol:66-70`
- **Description:** The NatSpec on line 47 claims "`acceptAdminRole` and `setPool` are idempotent," but the three calls inside the single `vm.startBroadcast()` block are executed unconditionally. On re-run, `_registerAdmin → registerAdminViaGetCCIPAdmin → proposeAdministrator` reverts `AlreadyRegistered`; `acceptAdminRole` reverts `OnlyPendingAdministrator`. There is no pre-broadcast probe.
- **Impact:** If `_registerAdmin` + `acceptAdminRole` land but `setPool` fails (nonce gap, gas exhaustion), the operator cannot re-run the script to finish `setPool` — they have to call it manually with raw `forge script`, against misleading NatSpec.
- **Recommendation:** Probe `TokenAdminRegistry.isAdministrator(token, msg.sender)`. If already the administrator, skip the register/accept block and call only `setPool`. Pattern is already used in scripts 05 and 06.

### DEP-2: `handoff` / `renounce` Makefile targets do not depend on `precheck-helper`
- **Severity:** MEDIUM
- **Status:** FIXED — `precheck-helper` is now a prerequisite of `handoff` and `renounce` (and via the existing `handoff-all → handoff` chain, both legs). Misfilled Helper placeholders fail fast before any broadcast.
- **Location:** `script/06_TransferOwnership.s.sol:73,152,158`, `Makefile:116-142`
- **Description:** `_handoff` only calls `_requireSet` on the addresses it reads (`cfg.tokenAdminRegistry`). For other Helper fields, no pre-flight check exists. Unlike `deploy-eth` / `deploy-bsc`, the `handoff`, `handoff-all`, and `renounce` Make targets do not invoke `precheck-helper` first.
- **Impact:** A misfilled Helper between deploy and handoff is not surfaced fast.
- **Recommendation:** Add `precheck-helper` as a prerequisite to `handoff`, `handoff-all`, and `renounce`.

### DEP-3: `RenounceDeployerAdmin` does not verify BSC-side pool handoff
- **Severity:** MEDIUM
- **Status:** FIXED (partial) — automated cross-chain checks aren't possible from a single `forge script` instance, but the renounce now logs an explicit REMINDER to verify the BSC pool ownership before treating the deployer EOA as fully retired. RUNBOOK §3.4 already required `make verify-bsc` post-handoff; the on-script reminder makes the dependency unmissable.
- **Location:** `script/06_TransferOwnership.s.sol:231-258`, comment at line 175
- **Description:** `_assertReadyToRenounce` checks the ETH-side pool owner and ETH `TokenAdminRegistry` admin role. It does not verify that the BSC `LockReleaseTokenPool` ownership has been accepted by the multisig. BSC pool ownership is the **custody-grade** authority over locked ON (via `setRebalancer → withdrawLiquidity`).
- **Impact:** An operator running `make renounce` after completing only the ETH leg of `handoff-all` will succeed. Deployer EOA loses ETH privilege but retains BSC pool ownership. The bridge is left in a permanently asymmetric authority state — including full custody of the BSC reserve still on the deployer.
- **Recommendation:** Read the BSC pool `owner()` (via a small view helper invoked over the BSC RPC) and block renounce until it matches the multisig. At minimum, expand the "Next steps" log to require explicit BSC-side verification.

### DEP-4: Script 08 misreports `address(0)` Helper as `RouterMismatch`
- **Severity:** LOW
- **Status:** FIXED — `_requireSet` on `router`, `rmnProxy`, and `tokenAdminRegistry` added before `_checkPoolWiring`. Unfilled placeholders now surface as `MissingAddress(name)`.
- **Location:** `script/08_PostDeployVerify.s.sol:55,86-98`
- **Description:** `_checkPoolWiring(localPool, local.router, local.rmnProxy)` is called without first running `_requireSet`. If placeholders are unfilled, the script reverts `RouterMismatch(expected=0x0, actual=…)`, which looks like a pool misconfiguration rather than an operator error.
- **Impact:** Misleading diagnostic at the verify step.
- **Recommendation:** Call `_requireSet(local.router, "router")` and `_requireSet(local.rmnProxy, "rmnProxy")` before `_checkPoolWiring`.

### DEP-5: Script 05 lacks `_requireSet` on remote infra addresses
- **Severity:** LOW
- **Status:** FALSE POSITIVE — re-validated against the script source. `remote.router`, `remote.rmnProxy`, and `remote.tokenAdminRegistry` are NEVER read by script 05; only `remote.chainSelector` (a non-address constant) and `remote.onToken` (validated indirectly via `_remoteTokenAddress`) are consumed. Adding `_requireSet` on never-read fields wouldn't catch any real misconfiguration. The `make deploy-eth` / `make deploy-bsc` flow already calls `precheck-helper` as a prerequisite, which validates every placeholder on both chains.
- **Location:** `script/05_ApplyChainUpdates.s.sol:24,63-75`
- **Description:** Only `remotePool`, `remoteToken`, and `localPool` are guarded. `remote.router`, `remote.rmnProxy`, `remote.tokenAdminRegistry` from `_remoteConfig(block.chainid)` are not — they're never *read* in this script, but the absence of the guard means a misfilled remote config produces no early fail signal.
- **Impact:** Diagnostic only — `precheck-helper` already covers this when used.
- **Recommendation:** Add `_requireSet(remote.router, "remote router")` defensively, or rely on `precheck-helper` being a prerequisite to all `make deploy-*` and `apply` targets.

### DEP-6: Script 03 has no pre-broadcast probe — benign
- **Severity:** INFO
- **Status:** FIXED — `hasRole(MINTER_ROLE, pool)` and `hasRole(BURNER_ROLE, pool)` probes added; already-granted roles are skipped to produce cleaner logs and avoid wasted-gas no-op broadcasts.
- **Location:** `script/03_GrantRoles.s.sol:23-25`
- **Description:** Unlike 01/02/05/06, script 03 does not probe state. OZ 5.x `grantRole` is a no-op if the role is already held, so re-runs are silently safe but waste two broadcast tx.
- **Impact:** Wasted gas on re-run, no correctness risk.
- **Recommendation:** Optionally probe `hasRole` for cleaner logs.

### DEP-7: `Deployments.writeAddress` not atomic — corrupt JSON bypasses safety net
- **Severity:** LOW
- **Status:** FIXED — `tryReadAddress` now wraps `keyExistsJson` and `parseJsonAddress` in try/catch, returning `address(0)` on malformed JSON so corrupt files route through the calling script's `_requireSet` diagnostic instead of a low-level Foundry panic.
- **Location:** `script/Deployments.sol:63-70`
- **Description:** `vm.writeJson` writes in-place; a process killed mid-write leaves a corrupt file. `tryReadAddress` guards against a missing file via `vm.exists` but not against parse errors — `parseJsonAddress` will panic before any `_requireSet` guard runs.
- **Impact:** Corrupt-file recovery produces a Foundry-internal panic instead of a friendly diagnostic.
- **Recommendation:** Wrap `parseJsonAddress` in try/catch, returning `address(0)` with a console warning on failure (consistent with the missing-file path), or document the recovery step (delete + re-run) prominently in RUNBOOK.

### DEP-8: `_checkDeployerRenounced` is vacuously satisfied under `make verify-*`
- **Severity:** HIGH
- **Status:** FIXED — `_checkDeployerRenounced` now accepts an explicit `deployer` parameter; the caller in `run()` reads it from `DEPLOYER` env via the new `_envAddressOrZero` helper and reverts `DeployerEnvMissing` when the var is absent and `MULTISIG` is set. Verification with `MULTISIG` set now requires the operator to supply the deployer address (or skip the renounce assertion by leaving `MULTISIG` unset). New tests: `test_CheckDeployerRenounced_RevertsWhenDeployerStillHoldsRole` (asserts the typed `RoleNotRenounced` revert when the deployer still holds the role) and `test_CheckDeployerRenounced_PassesAfterRenounce` (asserts the happy path).
- **Location:** `script/08_PostDeployVerify.s.sol:213-227`, `Makefile:108-114`
- **Description:** The renounce assertion read `msg.sender` directly. `verify-eth` / `verify-bsc` invoke `forge script` view-only with no `--sender` / `--account` / `--private-key`, so `msg.sender` is Foundry's default sender (`0x1804c8AB…`) — an address that has never held `DEFAULT_ADMIN_ROLE`. The branch `won.hasRole(adminRole, msg.sender)` therefore always evaluates `false` and the `RoleNotRenounced` revert is unreachable; the only post-deploy programmatic check that the deployer EOA has actually renounced was silently a no-op.
- **Impact:** A non-renounced deployer state would NOT be caught by `make verify-*` despite the runbook treating it as load-bearing.
- **Recommendation:** Thread the deployer address through as a parameter and require an env var (`DEPLOYER`) when `MULTISIG` is set so the renounce check actually validates what its name promises.

### DEP-9: Script 08 `_checkRemoteLink` `abi.decode` lacks length guard
- **Severity:** LOW
- **Status:** FIXED — both `remotePoolBytes` and `remoteTokenBytes` are length-checked (`== 32`) before `abi.decode`. A non-32-byte value now surfaces as a typed `MalformedRemoteEncoding(selector, field, actualLength)` instead of a low-level Foundry panic. Mirrors the encoding-assumption check already documented for the CCIP-6 stale-wiring path in script 05.
- **Location:** `script/08_PostDeployVerify.s.sol:128-141`
- **Description:** `TokenPool.setRemotePool` accepts raw `bytes` with no encoding constraint. A non-32-byte stored value would panic at `abi.decode(remotePoolBytes, (address))` with a generic ABI error rather than producing a typed diagnostic.
- **Impact:** Diagnostic only; CCIP message validation would still revert at use-time. The friendlier error helps operators debug an unusual manual wiring.
- **Recommendation:** Assert `remotePoolBytes.length == 32` (and likewise for `remoteTokenBytes`) before decoding, with a human-readable revert.

### DEP-10: Script 07 broadcasts without `isSupportedChain` preflight
- **Severity:** LOW
- **Status:** FIXED — `UpdateRateLimits.run()` now reverts `RemoteChainNotWired(selector)` before any broadcast if the local pool does not list the remote selector as supported. Mirrors the preflight posture of script 05 and script 08.
- **Location:** `script/07_UpdateRateLimits.s.sol:25-35`
- **Description:** `setChainRateLimiterConfig` on an unwired remote selector would burn a broadcast tx with a generic deep-revert. Scripts 05 and 08 both preflight `isSupportedChain`; script 07 didn't.
- **Impact:** Wasted gas + unclear diagnostic; no correctness risk.
- **Recommendation:** `require(TokenPool(localPool).isSupportedChain(remoteSelector), "remote chain not wired yet; run script 05 first");` before `vm.startBroadcast()`.

### DEP-11: Wrong `DEPLOYER` env silently passes `_checkDeployerRenounced`
- **Severity:** MEDIUM (sibling to DEP-8 HIGH)
- **Status:** FIXED — script 01 now writes the deployer EOA to `deployments/<chainId>.json` under a `deployer` key; script 08's `_checkDeployerRenounced` cross-validates the operator-supplied `DEPLOYER` env against the recorded value and reverts `DeployerAddressMismatch(envSupplied, recorded)` if they differ. Falls open when the JSON predates this fix (no `deployer` key recorded) so legacy deployments aren't blocked.
- **Location:** `script/01_DeployWrappedON.s.sol:39-44`, `script/08_PostDeployVerify.s.sol:104-110`
- **Description:** DEP-8 replaced `msg.sender` with `vm.envOr("DEPLOYER", …)`, but `won.hasRole(adminRole, deployer)` reverts only if the supplied address still holds the role. A typo or unrelated address trivially returns false → the renounce assertion passed for the wrong subject.
- **Impact:** Without DEP-11 a typo'd verify would happily print `[ok] renounced` while the real deployer still held the role.
- **Recommendation:** Record + cross-validate the deployer at script 01 / script 08.

### DEP-12: `MULTISIG=0x0` silently skipped the entire handoff block
- **Severity:** LOW
- **Status:** FIXED — script 08 now reads `MULTISIG` via `vm.envOr(…, address(0))` and, when zero, distinguishes "literal `0x000…0`" (typed `MultisigIsZeroAddress` revert) from "unset" (log + continue) via an explicit `try vm.envAddress(MULTISIG)` probe.
- **Location:** `script/08_PostDeployVerify.s.sol:80-97`
- **Description:** Before the fix, the try/catch around `vm.envAddress` caught only "unset"; an explicit `MULTISIG=0x0` succeeded, then the `if (multisig != address(0))` guard skipped both `_checkOwnershipHandoff` and `_checkDeployerRenounced`. `All checks passed.` printed regardless.
- **Impact:** Silent-skip of the most important post-handoff assertions.
- **Recommendation:** Surface the typo with a typed revert; explicit non-zero check.

### DEP-13: Corrupt `deployments/<chainId>.json` could trigger silent re-deploy
- **Severity:** LOW
- **Status:** FIXED — `Deployments.jsonIsValid(chainId)` probes the file for syntactic JSON validity (true for missing file, true for valid JSON with absent key, false for malformed JSON). Scripts 01 / 02 refuse to broadcast on a corrupt-JSON state with a typed `DeploymentsJsonCorrupt(chainId, key)` revert. The "delete a single key to force redeploy" recovery path is preserved (the JSON stays syntactically valid; only the key is missing).
- **Location:** `script/Deployments.sol:23-39`, `script/01_DeployWrappedON.s.sol:25-35`, `script/02_DeployPools.s.sol:29-40`
- **Description:** DEP-7's `tryReadAddress` returned `address(0)` for missing-file AND corrupt-file. Scripts 01 / 02 used that zero as "not deployed → broadcast" — so a partially-written JSON would silently re-deploy.
- **Impact:** Wasted broadcast + a possibly-orphaned previous on-chain artefact.
- **Recommendation:** `jsonIsValid` probe before broadcasting.

### DEP-14: Script 04 idempotency probe misses the "wired by a different broadcaster" branch
- **Severity:** INFO
- **Status:** DESIGN ACK — the `regAdmin != broadcaster && regPool == pool` branch is an abnormal state (registry shows a non-broadcaster admin yet the pool is already wired). Skipping silently would mask the question "who registered this?" — the operator should investigate before treating the deployment as healthy. The existing `_registerAdmin` revert when re-running is the right surface for "this isn't what you think it is".
- **Location:** `script/04_RegisterAdminAndPool.s.sol:82-106`
- **Description:** A prior run on a different EOA leaves the registry wired correctly but `regAdmin != broadcaster`. Re-running broadcasts `_registerAdmin` which reverts.
- **Impact:** Spurious failed broadcast under an abnormal state — but the abnormality is itself worth surfacing.
- **Recommendation:** Accept current behaviour; document the recovery path in RUNBOOK.

### DEP-15: `STRICT_RATE_LIMITS=false` printed `[ok]` rather than the documented warning
- **Severity:** LOW
- **Status:** FIXED — `_checkRateLimits` now routes disabled-bucket logging through `_logBucket(direction, bucket)`, which emits `[warn] %s rate limit DISABLED (STRICT_RATE_LIMITS=false)` for the disabled-bucket case under non-strict mode. Operator-facing output now matches the NatSpec promise.
- **Location:** `script/08_PostDeployVerify.s.sol:151-168`
- **Description:** The non-strict path early-returned from `_assertConfiguredOrWarn` and then unconditionally logged `[ok] cap=0 rate=0` — contradicting the "downgrades to a warning" NatSpec.
- **Impact:** Operator might read the `[ok]` line and miss that rate limits are off.
- **Recommendation:** Gate `[ok]` on `isEnabled` and emit `[warn]` otherwise.

### DEP-16: `STRICT_RATE_LIMITS` accepts only `true`/`false` bool literals
- **Severity:** INFO
- **Status:** DOC ADDED — Foundry's `vm.envOr(string, bool)` accepts only `true`/`false` (case-insensitive). Documented in `.env.example` (the same constraint applies to `OUTBOUND_ENABLED` / `INBOUND_ENABLED` driven by script 07). Wrapping in a string-parse normaliser was considered and rejected — it would mask "operator typed `STRICT_RATE_LIMITS=yes` thinking it would work" rather than failing fast on the typo.
- **Location:** `script/08_PostDeployVerify.s.sol:153`, `.env.example`
- **Description:** A `0`/`1`/`yes`/`no` value would revert deep inside the cheatcode with Foundry's native parse error.
- **Impact:** Operator UX only.
- **Recommendation:** Document the constraint.

### DEP-17: `_envAddressOrZero` swallowed both "unset" and "malformed"
- **Severity:** LOW
- **Status:** FIXED — replaced the try/catch helper with `vm.envOr("DEPLOYER", address(0))`, which returns zero only for unset. A truncated-hex value now bubbles up with Foundry's native parse error instead of being masked as `DeployerEnvMissing`.
- **Location:** `script/08_PostDeployVerify.s.sol:101-107`
- **Description:** A malformed `DEPLOYER` value (e.g. `0x123`) returned zero through the catch arm, then surfaced the wrong diagnostic.
- **Impact:** Operator diagnostic only.
- **Recommendation:** Use `envOr` and let malformed values bubble up.

### DEP-18: Script 03 `getToken()` cross-check lacked try/catch
- **Severity:** LOW
- **Status:** FIXED — `getToken()` (and the DEP-22 new `getRouter()` / `getRmnProxy()` / `typeAndVersion()` checks) are each wrapped in try/catch so a non-pool contract at `deployments/<chainId>.json::pool` surfaces a typed `PoolGetTokenCallFailed`, `PoolMisidentified`, or `PoolTypeMismatch` revert instead of an empty EVM revert.
- **Location:** `script/03_GrantRoles.s.sol:36-86`
- **Description:** A stale or hand-edited JSON pointing at a non-pool address would revert with no selector and no human-readable reason. Every other failure mode in the script surfaced as a custom error.
- **Impact:** Operator diagnostic only.
- **Recommendation:** Try/catch around the staticcalls.

### DEP-19: `_checkBscRebalancer` / `_checkOwnershipHandoff` used `require` strings
- **Severity:** LOW
- **Status:** FIXED — replaced both `require` strings with typed `BscRebalancerReadFailed(pool)` / `PoolOwnerReadFailed(pool)` errors. Brings these helpers in line with the rest of the script's error vocabulary and lets `vm.expectRevert(selector)` work in tests (TEST-20).
- **Location:** `script/08_PostDeployVerify.s.sol:194-209, 220-227`
- **Description:** Slither's `prefer-custom-errors` detector would flag these. Tests had to rely on string-matching.
- **Impact:** Style / test ergonomics.
- **Recommendation:** Typed errors.

### DEP-20: Script 06 BSC handoff branch lacked the CCIP-4 symmetric `getToken()` cross-check
- **Severity:** MEDIUM
- **Status:** FIXED — `_handoff` now staticcalls `ITokenPoolReadToken(pool).getToken()` (try/catch) and reverts `PoolTokenMismatch(pool, poolToken, expectedToken)` if the pool isn't bound to the expected token. Mirrors the CCIP-4 check in script 03. Applied to both ETH and BSC sides; the BSC side is the higher-stakes leg because the pool owns the locked-ON reserve via `setRebalancer`/`withdrawLiquidity`.
- **Location:** `script/06_TransferOwnership.s.sol:96-104`
- **Description:** A tampered `deployments/<chainId>.json::pool` could redirect ownership of a custody-grade BSC pool. The ETH-side CCIP-4 check protected role grants but not the ownership handoff.
- **Impact:** Filesystem-tamper required for exploit; if it lands, full custody of the BSC reserve transfers to an attacker-controlled pool.
- **Recommendation:** Symmetric check on the handoff path.

### DEP-21: Script 05 re-run path doesn't detect on-chain rate-limit drift from `DEFAULT_*` constants
- **Severity:** INFO
- **Status:** DESIGN ACK — script 05 is the *wiring* step (`applyChainUpdates`); script 07 is the explicit rate-limit-changes step (`setChainRateLimiterConfig`). The `isSupportedChain == true` skip branch deliberately does NOT touch rate-limit state, with an explicit log line directing operators to `make update-limits`. A revert on drift would conflate two distinct operator workflows. Documented behaviour matches script semantics.
- **Location:** `script/05_ApplyChainUpdates.s.sol:53-72`
- **Description:** An operator editing `DEFAULT_CAPACITY` / `DEFAULT_RATE` between deploy runs would not see the new values applied by a re-run of `make deploy-eth`.
- **Impact:** Operator-workflow surprise only.
- **Recommendation:** Accept; the explicit `make update-limits` step is the right place for rate-limit changes.

### DEP-22: CCIP-4 `getToken()` check is forgeable; strengthened with multi-surface identity probes
- **Severity:** LOW (filesystem-tamper required; impact high if hit)
- **Status:** FIXED — script 03 now cross-checks `typeAndVersion() == "BurnMintTokenPool 1.5.0"`, `getRouter() == cfg.router`, AND `getRmnProxy() == cfg.rmnProxy` in addition to the existing `getToken() == wonAddr`. Each check is individually forgeable by a custom mock, but the combined surface raises the cost of a deployments JSON tamper from "write a 30-line `FakePool { getToken() returns wON; … }`" to "match four pool-identity surfaces simultaneously, including the cfg-bound router and RMN addresses".
- **Location:** `script/03_GrantRoles.s.sol:36-86`
- **Description:** A filesystem-write-attack between script 02 broadcast and script 03 read could install a `FakePool { getToken() returns wON; drain() { wON.mint(attacker, 100M); } }` and harvest `MINTER_ROLE`/`BURNER_ROLE`. The CCIP-4 check was a real defence but raised the forgery cost by a constant; DEP-22 raises it meaningfully.
- **Impact:** Up to 100M wON mint authority granted to a forged pool if all four checks are passed.
- **Recommendation:** Multi-surface identity probe.

---

## CCIP integration & pool wiring (`CCIP-*`)

### CCIP-1: BSC pool `withdrawLiquidity` is rebalancer-gated, but `setRebalancer` is owner-set with no monitor
- **Severity:** HIGH
- **Status:** FIXED — `script/08_PostDeployVerify.s.sol` now calls `_checkBscRebalancer(pool)` on every BSC verify run and reverts `UnexpectedRebalancer` if the slot is non-zero. The RUNBOOK monitoring table already pages on `setRebalancer` calldata; the verify-time assertion catches an accidental set at deploy and on every operator re-verify.
- **Location:** `lib/chainlink-ccip/chains/evm/contracts/pools/LockReleaseTokenPool.sol:53-102`, `script/02_DeployPools.s.sol:53`
- **Description:** CCIP 1.6.1 has no `acceptLiquidity` flag; with no rebalancer set, `provideLiquidity` and `withdrawLiquidity` both revert `Unauthorized` (they require `msg.sender == s_rebalancer`), and `setRebalancer` is `onlyOwner` (no timelock, no cap, no in-flight-message guard). The pool owner can set the rebalancer to themselves and drain the reserve in a single multisig batch. Mid-flight BSC→ETH messages would commit on ETH (wON minted) but fail permanently on BSC release with `InsufficientLiquidity`. This is the documented CCT trust model and is correctly disclosed in CLAUDE.md/RUNBOOK — but no script-level or monitoring assertion exists on `s_rebalancer`.
- **Impact:** The custodial risk is accepted by design. The gap is that an accidental or malicious `setRebalancer` is not detected promptly.
- **Recommendation:** Add `_checkRebalancer(localPool)` to `script/08_PostDeployVerify.s.sol` asserting `LockReleaseTokenPool(pool).getRebalancer() == address(0)`. Add the same assertion to the RUNBOOK monitoring checklist as a recurring check.

### CCIP-2: Symmetric rate limits ignore directional asymmetry of the bridge
- **Severity:** MEDIUM
- **Status:** DOC ADDED — script 05 NatSpec now documents the intentional symmetry decision and prompts operators to override before mainnet broadcast if directional tightening is desired.
- **External audit:** QuillAudits *Wrapped ON* Initial Audit Report — Finding M2 (Medium, Likelihood High; "ETH→BSC burns can proceed without local proof of BSC release liquidity"), tracked as issue [#24](https://github.com/orochi-network/bridge/issues/24), maps here. M2 has **no on-chain fix on the Ethereum side** — an ETH burn cannot synchronously read BSC liquidity (inherent to the CCT architecture). Remediation is operational and now documented: (1) size the ETH→BSC inbound rate-limit to BSC releasable liquidity minus a buffer (this finding); (2) a §3 monitoring alert on `BSC_ON.balanceOf(BSC pool)` vs that capacity; (3) the stuck-message recovery procedure in **RUNBOOK §4.5** (replenish via direct ON transfer since `provideLiquidity` is disabled, then CCIP manual execution). The burned-on-source value is delayed, not lost — `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` is preserved.
- **Location:** `script/05_ApplyChainUpdates.s.sol:69-75`
- **Description:** Both pools share `DEFAULT_CAPACITY = 100_000 ether` and `DEFAULT_RATE = 10 ether/sec` in both directions. The bridge is asymmetric (ETH has the hard `MAX_CCIP_MINTED = 100M` cap; BSC has no equivalent wON-side cap). Bucket-asymmetry between independent pool clocks means queued messages can arrive after a bucket has been redrained.
- **Impact:** No direct exploit. Possible DoS / unexpected user-facing reverts during burst+queue scenarios.
- **Recommendation:** Document the intentional symmetric default in script comments, and decide explicitly before mainnet whether ETH-inbound should be tighter to preserve `MAX_CCIP_MINTED` headroom for honest flow.

### CCIP-3: Bucket capacity/rate ratio is high — single tx can saturate for ~2.8h
- **Severity:** LOW
- **Status:** DOC ADDED — script 05 NatSpec now spells out the ~2.8h-from-zero refill window so operators decide consciously before mainnet rather than inheriting it implicitly.
- **Location:** `script/05_ApplyChainUpdates.s.sol:20-29`, `src/WrappedON.sol:78-80`
- **Description:** `DEFAULT_CAPACITY = 100_000 ether` against `DEFAULT_RATE = 10 ether/sec` = 10,000 s to refill (~2.78 h). A single bridging tx can saturate the bucket and block all other users until refill.
- **Impact:** Temporary DoS, resolvable by waiting or by operator-adjusted rate.
- **Recommendation:** Consider sizing capacity to a smaller multiple of rate (e.g. 100-second refill window) and document the chosen ratio as an explicit decision in RUNBOOK.

### CCIP-4: `deployments/<chainId>.json` is trusted blindly when granting `MINTER_ROLE`/`BURNER_ROLE`
- **Severity:** MEDIUM
- **Status:** FIXED — `script/03_GrantRoles.s.sol` now staticcalls `TokenPool(pool).getToken()` and reverts `PoolTokenMismatch` if it doesn't equal the deployed wON before granting any roles. A tampered JSON pointing at a non-pool contract or a pool wired to a different token now fails fast instead of leaking mint authority.
- **Location:** `script/04_RegisterAdminAndPool.s.sol:61-69`, `script/03_GrantRoles.s.sol`
- **Description:** Roles are granted to the address stored in `deployments/<chainId>.json` with no on-chain check that the address is a real CCIP pool wired to the right token. A hand-edited or supply-chain-tampered JSON could redirect `MINTER_ROLE` to an attacker contract, enabling minting up to 100M wON.
- **Impact:** Up to 100M wON mint authority can be granted to a wrong address if the JSON file is compromised before `make deploy-eth` runs.
- **Recommendation:** In `script/03_GrantRoles.s.sol`, assert `TokenPool(pool).getToken() == address(wON)` before granting roles. This is a single staticcall that cannot be forged without deploying a matching contract.

### CCIP-5: Chain selectors verified correct — no finding
- **Severity:** INFO
- **Status:** FALSE POSITIVE — investigated; all four selectors match the canonical CCIP directory. Record retained so the slot is reserved.
- **Location:** `script/Helper.sol:29-32`
- **Description:** Reviewed against the canonical Chainlink CCIP directory: ETH Mainnet `5009297550715157269`, BSC Mainnet `11344663589394136015`, Sepolia `16015286601757825753`, BSC Testnet `13264668187771770619` — all correct.
- **Impact:** None.
- **Recommendation:** None.

### CCIP-6: Stale-wiring check assumes `abi.encode(address)` encoding
- **Severity:** LOW
- **Status:** FALSE POSITIVE — re-reading `script/05_ApplyChainUpdates.s.sol:47-50`, the comment block immediately above the `bytes32` cast already states: "`abi.encode(address)` produces exactly 32 bytes (left-padded), and the pool's `getRemotePools` returns the same shape. Compare directly as bytes32 rather than hashing both sides — same intent, cheaper, and clearer about the assumed shape." The encoding assumption is documented and the assertion `wiredRemote.length == 32 && bytes32(wiredRemote) == bytes32(uint256(uint160(remotePool)))` already explicitly checks the length, so a non-32-byte encoding would fail the `require`, not silently pass it.
- **Location:** `script/05_ApplyChainUpdates.s.sol:51-53`
- **Description:** `wiredRemote` is cast to `bytes32` and compared. Correct for `abi.encode(address)` (32-byte left-padded). `TokenPool.setRemotePool` takes raw `bytes` with no encoding requirement, so a directly-set non-32-byte encoding bypasses the check. Real CCIP messages would still revert at validation time, so this is a diagnostic-only issue.
- **Impact:** Silent skip of stale-detection under non-standard manual wiring.
- **Recommendation:** Add a code comment documenting the encoding assumption; assert `wiredRemote.length == 32` explicitly.

### CCIP-7: `MAX_CCIP_MINTED` cap is not a lifetime bound — bridge cycling can refill headroom
- **Severity:** MEDIUM
- **Status:** DOC ADDED — `WrappedON.sol` NatSpec now contains a dedicated CAP REPLENISHMENT paragraph spelling out the cycling-refills-headroom behaviour, the preserved safety invariant, and the operational consequence (monitor `ccipMintHeadroomUsed` relative to current BSC locked balance, not relative to `MAX_CCIP_MINTED`). The monotone-counter alternative is left as a redeploy option if a true lifetime CCIP-mint bound becomes a requirement. **M1 / #23:** the counter was renamed `ccipMintedSupply` → `ccipMintHeadroomUsed` to make the "headroom used, not BSC-minted-supply" semantics explicit at the identifier level (see WON-3).
- **External audit:** Maps to QuillAudits *Wrapped ON* Initial Audit Report — Finding I4 (Informational, reviewed at `b9de6da`), tracked as repo issue [#26](https://github.com/orochi-network/bridge/issues/26). Closed by a doc-consistency sweep of `README.md`, `RUNBOOK.md`, and `docs/ARCHITECTURE.md` confirming no wording presents `MAX_CCIP_MINTED` as a `totalSupply()` ceiling. Canonical phrasing: *MAX_CCIP_MINTED caps the local CCIP mint counter, not aggregate wON supply.*
- **Clarification (the exact invariant vs. the local counter):** The genuine cross-chain invariant is enforced by CCIP, not by this contract: every CCIP message pairs one BSC `lock`/`release` with one Ethereum `mint`/`burn`, so the ON locked on BSC *via CCIP* equals the wON minted on Ethereum *via CCIP*, message-for-message. **Ethereum cannot read the BSC pool's balance**, so that equality rests on a Chainlink trust assumption (the DON + RMN delivering each message once and honouring the pairing) — `mint` fires when the trusted off-ramp calls `releaseOrMint` and cannot verify the matching BSC lock itself. `ccipMintHeadroomUsed` is only a *local* proxy that exists because the real figure is off-chain: it saturates at 0 (hence WON-3) and reflects neither operator-seeded rebalancer liquidity nor any live cross-chain read. Do not conflate the exact protocol pairing with the approximate local counter.
- **Location:** `src/WrappedON.sol:345-349` (saturating decrement)
- **Description:** wON is fungible. A user can `deposit` native ETH-side ON (deposit-backed wON, `ccipMintHeadroomUsed` untouched), then bridge that wON to BSC (`burn` saturating-decrements `ccipMintHeadroomUsed` toward zero). After cycling, the 100M cap is fully replenished, even though no CCIP-minted supply was burned. In the extreme: 100M deposit → 100M bridge-out → counter resets to 0 → another 100M CCIP-mint available. The safety invariant `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` still holds, but the cap's intent (bounding damage from a compromised pool) is weakened: compromised-pool damage is bounded by *current* `ccipMintHeadroomUsed` headroom, which may exceed 100M cumulatively over time.
- **Impact:** The cap is an approximation, not a hard CCIP-mint lifetime ceiling. The contract NatSpec already states this; the SECURITY-relevant point is that monitoring should not assume cap-fraction-used equals risk-fraction-used.
- **Recommendation:** Document the cycling scenario explicitly in `WrappedON.sol` NatSpec. If a true lifetime CCIP-mint bound is desired, use a monotone non-decrementing counter (with a parallel cap higher than 100M to permit honest cycling).

### CCIP-8: RMN curse halts both directions — no runbook response
- **Severity:** LOW
- **Status:** FALSE POSITIVE — `RUNBOOK.md §4.2 "Responding to an RMN curse"` already documents the operator-side response: confirm the curse via the CCIP Explorer, coordinate with Chainlink ops, transfers resume automatically once uncursed. The finding was missed by the reviewer's scan.
- **Location:** `lib/chainlink-ccip/chains/evm/contracts/pools/TokenPool.sol:283,302`
- **Description:** A curse on the BSC selector blocks both `lockOrBurn` and `releaseOrMint`. Users cannot exit in either direction. RUNBOOK has no documented response procedure.
- **Impact:** During an RMN curse, all bridging stops. Funds are not at risk; user UX is.
- **Recommendation:** Add a "RMN Curse Response" section to RUNBOOK: detection (monitor `CursedByRMN` reverts or query `IRMN.isCursed`), authority (Chainlink), user communication.

### CCIP-9: Cross-chain decimal parity for BSC ON unverified at deploy/verify
- **Severity:** MEDIUM
- **Status:** FALSE POSITIVE — same architecture argument as WON-8. The BSC ON token at `0x0e4F6209eD984b21EDEA43acE6e09559eD051D48` is a non-upgradeable ERC20 with `decimals() == 18` already deployed and immutable; `Helper.getConfig(56)` hardcodes this address. A future redeploy against a token with different `decimals()` would also require updating `Helper.sol`, which is a deliberate code change reviewed under normal change control rather than a runtime risk. The ETH-side equality check in the wON constructor remains the architectural enforcement point — a redeploy that ignored both would already have to bypass Helper's hardcoded mainnet addresses.
- **Location:** `script/02_DeployPools.s.sol:53`, `script/08_PostDeployVerify.s.sol` (BSC branch)
- **Description:** WON-8's check guards the ETH side. No script asserts that the BSC ON token returns 18. A future redeploy against a token with different `decimals()` would silently misalign cross-chain accounting (no revert — wrong nominal amount delivered).
- **Impact:** None under canonical-token + hardcoded-Helper constraint.
- **Recommendation:** No code change required. Deploy-time controls (hardcoded canonical addresses in Helper + immutable ON tokens on both chains) are sufficient.

### CCIP-10: `isEnabled=false` rate-limit state cannot pass `make verify-*`
- **Severity:** LOW
- **Status:** FIXED — `_checkRateLimits` reads `STRICT_RATE_LIMITS` from env (default `true`, preserving the previous "rate limits must be on at launch" posture). With `STRICT_RATE_LIMITS=false` a disabled bucket downgrades from `RateLimitDisabled` revert to a no-op (the silently-bricked `enabled-but-rate==0` state still reverts `RateLimitMisconfigured` regardless — that case is never a deliberate launch choice). New tests: `test_NonStrictPassesOnDisabledBucket` and `test_NonStrictStillRejectsZeroRate`.
- **Location:** `script/08_PostDeployVerify.s.sol:141-181`
- **Description:** Script 07's preflight accepts `OUTBOUND_ENABLED=false` (mirroring CCIP's `_validateTokenBucketConfig` exactly); script 08's `_assertEnabledAndConfigured` reverted on `!isEnabled`. An operator deliberately running with rate-limits off — a documented but unusual launch decision — could not pass `make verify-*`.
- **Impact:** Operator UX only — the bridge is intended to launch with rate-limits engaged, but the escape hatch should be reachable through the released toolchain.
- **Recommendation:** Add a `STRICT_RATE_LIMITS` env gate (default true), or document the interaction.

### CCIP-11: `0x00` literal in `hasRole` call is visually ambiguous
- **Severity:** INFO
- **Status:** FIXED — replaced with `bytes32(0)` in `script/04_RegisterAdminAndPool.s.sol:142`. Functionally identical (Solidity literal `0x00` widens to `bytes32(0)` when typed as `bytes32`), but `bytes32(0)` matches the RUNBOOK §0.2 `cast call` example and is harder to mis-read as a 1-byte value.
- **Location:** `script/04_RegisterAdminAndPool.s.sol:142`
- **Description:** `hasRole(0x00, broadcaster)` and `hasRole(bytes32(0), broadcaster)` produce identical bytecode; the second form is clearer.
- **Impact:** None.
- **Recommendation:** Replace with `bytes32(0)`.

### CCIP-12: `CCIPBurned.account` semantic mismatch with `Transfer.from` for the single-arg `burn(uint256)`
- **Severity:** INFO
- **Status:** DOC ADDED — NatSpec on the `burn(uint256)` overload now states: `account` is `msg.sender` (the burning pool), not the token holder. The concurrent ERC20 `Transfer(from, 0, amount)` has `from` = the token holder; indexers correlating both events need to match against `Transfer.from`. No on-chain behaviour change.
- **Location:** `src/WrappedON.sol:237-247`
- **Description:** Subscribing only to `CCIPBurned` and assuming `account` is the holder misreads the single-arg path.
- **Impact:** Indexer correctness — documentation gap.
- **Recommendation:** NatSpec disclosure.

### CCIP-13: `RouterUpdated` not in RUNBOOK monitoring table
- **Severity:** MEDIUM (custody-grade, silent post-handoff)
- **Status:** FIXED — added `RouterUpdated(oldRouter, newRouter)` (both pools) as **Critical** in the §3 trust-model monitoring table, with explicit rationale in the new "Rationale for the post-handoff additions" subsection. The `setRouter(addr)` function is `onlyOwner`; a compromised multisig can swap `s_router` and route both `lockOrBurn` (drains BSC reserve) and `releaseOrMint` (mints unbacked wON up to cap) through attacker-controlled `_onlyOnRamp` / `_onlyOffRamp` lookups.
- **Location:** `RUNBOOK.md` §3 (Trust-model monitoring table)
- **Description:** Direct analog of CCIP-1 (`setRebalancer`) for routing; was not in the live alert surface.
- **Impact:** Bypass of CCIP message-validation guard rails if missed.
- **Recommendation:** Critical-severity row in the monitoring table.

### CCIP-14: `RemotePoolSet` / `ChainAdded` / `ChainRemoved` / `ChainConfigured` not monitored
- **Severity:** MEDIUM
- **Status:** FIXED — added all four to the monitoring table. `RemotePoolSet` is **Critical** (alters the source-pool keccak used to validate inbound mints — opens forged-source-mint door). `ChainAdded`/`ChainRemoved`/`ChainConfigured` are **High** (rate-limit reset / selector wiring changes).
- **Location:** `RUNBOOK.md` §3 (Trust-model monitoring table)
- **Description:** Compromised owner can redirect source-pool validation or re-wire rate limits without surfacing on the alert path.
- **Impact:** Allows forged inbound mints or attacker-favourable rate-limit reconfigurations.
- **Recommendation:** Add to monitoring table.

---

## Test coverage & quality (`TEST-*`)

### TEST-1: Fork tests not pinned to a block number — latent flakiness
- **Severity:** HIGH
- **Status:** FIXED — every `vm.createFork` / `vm.createSelectFork` call now passes a pinned block (defaulting to `ETH=22_000_000`, `BSC=50_000_000`), overridable via `ETH_FORK_BLOCK` and `BSC_FORK_BLOCK` env vars. Defaults should be refreshed deliberately on any CCIP-side state change.
- **Location:** `test/fork/Fork_ETH.t.sol:60`, `test/fork/Fork_BSC.t.sol:63`, `test/fork/Fork_Bridge.t.sol:74-75`
- **Description:** All three fork tests call `vm.createSelectFork(rpc)` / `vm.createFork(rpc)` with no block number, so each run forks the live chain tip. On-ramp / off-ramp addresses are resolved dynamically via `getOffRamps`/`getOnRamp`. A CCIP router upgrade can silently change ramp resolution and break tests with no code change here.
- **Impact:** CI non-determinism; mainnet upgrades can mask or fabricate regressions.
- **Recommendation:** Pass a fixed `blockNumber` to each `createFork` / `createSelectFork`. Document the chosen block and update it deliberately.

### TEST-2: No `[invariant]` config block — defaults (depth 15, `fail_on_revert = false`)
- **Severity:** HIGH
- **Status:** FIXED — `foundry.toml` now has an explicit `[invariant]` table: `runs=256, depth=50, fail_on_revert=true`, plus a `[profile.ci.invariant]` override at `runs=500, depth=100`. The handler's early-exit guards mean `fail_on_revert=true` is safe. The full invariant suite still passes (4/4).
- **Location:** `foundry.toml` (general), `test/WrappedONInvariant.t.sol`
- **Description:** `[profile.ci]` overrides `fuzz.runs = 1000` but sets nothing for invariants. Foundry defaults to `runs = 256, depth = 15, fail_on_revert = false`. Depth 15 is far too shallow for the five-action handler to reach interesting `adversarialPoolBurn → ccipMint → adversarialPoolBurn` interleavings. `fail_on_revert = false` silently swallows handler reverts (broken handlers degrade coverage with no signal).
- **Impact:** Saturating-decrement regressions, multi-step invariant violations, and broken handler logic are all under-detected.
- **Recommendation:** Add `[invariant]` (or `[profile.ci.invariant]`): `runs = 500..1000, depth = 50..100, fail_on_revert = true`. Existing handlers already early-exit on zero balance, so `fail_on_revert = true` should not introduce noise.

### TEST-3: Bare `vm.expectRevert()` masks wrong-error regressions
- **Severity:** MEDIUM
- **Status:** FIXED — typed selectors / payload assertions across all 7 call sites: `TokenPool.CallerIsNotARampOnRouter`, `RateLimiter.TokenRateLimitReached` (via `expectPartialRevert`), `TokenPool.Unauthorized` (via `expectPartialRevert`), the CCIP ConfirmedOwner `bytes("Only callable by owner")` literal, `IERC20Errors.ERC20InsufficientBalance` / `ERC20InsufficientAllowance`, `RegisterAdminAndPool.CannotResolveCCIPAdmin`. `expectPartialRevert` matches the 4-byte selector when the args are time- or caller-dependent.
- **Location:** `test/PoolRoundtrip.t.sol:246`, `:305`; `test/DeploymentE2E.t.sol:366`, `:423`; `test/WrappedON.t.sol:128`, `:231`; `test/Script04Paths.t.sol:176`
- **Description:** Nine calls to bare `vm.expectRevert()` accept any revert reason. The comments name the intended selector (`TokenRateLimitReached`, `ERC20InsufficientBalance`, `CannotResolveCCIPAdmin`, `OwnableUnauthorizedAccount`) but assertions don't check it. A refactor that reverts for a different reason still passes — most critically the `test_OnlyOnRampCanLock` access-control check.
- **Impact:** Access-control or gating regressions silently keep tests green.
- **Recommendation:** Use `vm.expectRevert(abi.encodeWithSelector(...))` or at minimum `vm.expectRevert(bytes4(...))` everywhere. OZ 5.x typed errors expose selectors directly.

### TEST-4: Rate-limit refill test is a single-point spot-check
- **Severity:** MEDIUM
- **Status:** FIXED — new `testFuzz_RateLimitRefillMath(uint128 drainAmt, uint40 elapsedSeconds)` drains by a fuzzed amount, warps a fuzzed time, then asserts `bucket.tokens` exactly equals `capacity - drainAmt + elapsed * rate` clamped to `capacity`.
- **Location:** `test/PoolRoundtrip.t.sol:278-312`
- **Description:** Drain-to-zero + warp-1-second + send-1-ether is a point check, not a fuzz. Partial-drain followed by various elapsed times — exactly the regime where token-bucket arithmetic bugs surface — is not exercised.
- **Impact:** Off-by-one / rounding bugs in `tokens += elapsed * rate` capped at `capacity` would slip through.
- **Recommendation:** Add `testFuzz_RateLimitRefill(uint128 drainAmt, uint40 elapsedSeconds)` bounding `drainAmt ∈ [1, capacity]` and `elapsedSeconds ∈ [0, 10_000]`, asserting `available == min(drainAmt, elapsed * rate)`.

### TEST-5: `test_E2E_RenounceBeforeMultisigAcceptIsBlocked` does not actually exercise the renounce script
- **Severity:** MEDIUM
- **Status:** DESIGN ACK — the script's actual revert path IS exercised by `test/Script06Renounce.t.sol:test_RevertsWhenCcipAdminNotAccepted` (referenced in `test_E2E_RenounceBeforeMultisigAcceptIsBlocked`'s NatSpec). This test covers the precondition logic inline; the script-level revert is covered separately. Renaming or adding a `vm.expectRevert` call here would be redundant.
- **Location:** `test/DeploymentE2E.t.sol:440-476`
- **Description:** The test only asserts the in-script precondition bool `ccipAdminReady` is `false` — it never calls `RenounceDeployerAdmin.run()` or `_assertReadyToRenounce`. The "block" is a pure boolean evaluation; no `vm.expectRevert`.
- **Impact:** A regression in `_assertReadyToRenounce` would not be caught by this test (it is independently covered in `Script06Renounce.t.sol`, but the claim in this file is overstated).
- **Recommendation:** Either call the script and `expectRevert`, or add a clear cross-reference to `Script06Renounce.t.sol`.

### TEST-6: Invariant handler exercises only `burn(amount)` — `burnFrom` and `burn(address,uint256)` omitted
- **Severity:** MEDIUM
- **Status:** FIXED — added `ccipBurnFrom` (approves pool, then `burnFrom`) and `ccipBurnAddress` (pool calls `burn(address,uint256)`) as handler actions; both included in `targetSelector`. Every burn overload's `_decrementCcipMintHeadroom` branch is now fuzzer-reachable.
- **Location:** `test/WrappedONInvariant.t.sol:113-132,152-166`
- **Description:** Both invariant burn actions call the single-argument overload. The other two overloads each independently call `_decrementCcipMintHeadroom`. Multi-step sequences involving them (including allowance interactions) are invisible to the property-based engine.
- **Impact:** Path-specific saturating-decrement bugs in `burnFrom` or `burn(address,uint256)` would be missed.
- **Recommendation:** Add `ccipBurnFrom` and `ccipBurnAddress` handler actions and include them in `targetSelector`.

### TEST-7: `test_Fork_BSC_TokenOwnershipModel` is too loose
- **Severity:** LOW
- **Status:** DEFERRED — the test's looseness reflects the open `Known open item` in CLAUDE.md ("BSC ON token CCIP-admin hook"). Tightening the assertion to verify the resolved admin equals the deployer requires first concluding which path the live BSC token exposes (RUNBOOK §0.2). Once that is settled the test can pin the chosen path.
- **Live probe (issue #22):** `script/ValidateBscAdmin.s.sol` (`make validate-bsc-admin`) runs script 04's path resolution read-only against live BSC. Probed against `0x0e4F…1D48` on **2026-06-01**, the canonical ON token resolves to **path 4 for any deployer**: `getCCIPAdmin()` absent, `owner()` returns the **zero address** (ownership renounced → `registerAdminViaOwner` unusable), `AccessControl.hasRole` absent. **Implication:** script 04 will revert `CannotResolveCCIPAdmin` on BSC mainnet; CCIP-admin registration must be arranged out-of-band with Chainlink (the `TokenAdminRegistry` owner) before the BSC deploy. This is now a *confirmed* pre-mainnet blocker rather than an unknown — but the resolution (Chainlink coordination) is operational, so the finding stays open until that registration is in place.
- **Location:** `test/fork/Fork_BSC.t.sol:108-112`
- **Description:** The test asserts `hasCCIPAdmin || hasOwnable`; a non-deployer Ownable owner would still pass. The script-04 `proposeAdministrator` fallback path (used when neither interface is exposed) is not exercised by the fork test at all — but is a known open item in CLAUDE.md.
- **Impact:** The fork test does not reliably signal which script-04 path will succeed on mainnet.
- **Recommendation:** Assert that the resolved admin equals the expected deployer; on no-interface, `vm.skip(true)` with a `console.log` rather than failing.

### TEST-8: No reentrancy test for `deposit` with a hooked ERC20
- **Severity:** LOW
- **Status:** FIXED — new `ReentrantMockON` overrides `transferFrom` to re-enter `WrappedON.deposit`; `test_DepositReentrancyGuardFires` constructs a wON against it and asserts the outer deposit completes (i.e. the inner reentry is rejected by `nonReentrant`).
- **Location:** `test/WrappedON.t.sol` (general)
- **Description:** The `nonReentrant` guard's behaviour is asserted only by reading the modifier, never by a malicious-ON mock that reenters via `transferFrom`. The current ON is non-hookable, but the constructor accepts any IERC20.
- **Impact:** Future redeployments against a hookable token rely on review rather than test.
- **Recommendation:** Add `test_Deposit_ReentrancyGuardFires` using a mock ON whose `transferFrom` re-enters `deposit`/`withdraw`, asserting the OZ `ReentrancyGuardReentrantCall` selector.

### TEST-9: Specific OZ 5.x typed errors not asserted
- **Severity:** LOW
- **Status:** FIXED — `test_WithdrawRevertsOnInsufficientWonBalance` and `test_BurnFromRevertsOnInsufficientAllowance` now use `vm.expectRevert(abi.encodeWithSelector(IERC20Errors.*Error.selector, …))` with full payload.
- **Location:** `test/WrappedON.t.sol:128,231`
- **Description:** `test_BurnFromRevertsOnInsufficientAllowance` and `test_WithdrawRevertsOnInsufficientWonBalance` use bare `expectRevert()` for `ERC20InsufficientAllowance` / `ERC20InsufficientBalance`. Subset of TEST-3 but called out for the user-facing ERC20 surface specifically.
- **Impact:** Wrong-error regressions on the ERC20 path pass silently.
- **Recommendation:** Use `vm.expectRevert(abi.encodeWithSelector(IERC20Errors.*Error.selector, …))`.

### TEST-10: Stale-pending CCIP admin re-proposal not tested
- **Severity:** MEDIUM
- **Status:** FIXED — new `test_AcceptAfterProposalOverwriteReverts` in `test/WrappedON.t.sol`: after `setCCIPAdmin(A)` then `setCCIPAdmin(B)`, A's `acceptCCIPAdmin` must revert `OnlyPendingCCIPAdmin` and B's must succeed. The `CCIPAdminProposalCancelled(A)` event sibling (WON-5) pinned the writer-side overwrite signal; this pins the accept-side behaviour so a regression that failed to clear the stale pending wouldn't silently honour A's tx.
- **Location:** `test/WrappedON.t.sol`
- **Description:** The `setCCIPAdmin(A) → setCCIPAdmin(B) → A.acceptCCIPAdmin()` sequence was unexercised.
- **Impact:** A regression failing to overwrite `s_pendingCcipAdmin` would be invisible to tests.
- **Recommendation:** Add `test_AcceptAfterProposalOverwriteReverts`.

### TEST-11: `acceptCCIPAdmin()` double-call not tested
- **Severity:** MEDIUM
- **Status:** FIXED — new `test_AcceptCCIPAdminDoubleCallReverts` in `test/WrappedON.t.sol`: after a successful accept, `pendingCCIPAdmin() == address(0)` and a second call from the now-current admin reverts `OnlyPendingCCIPAdmin`.
- **Location:** `test/WrappedON.t.sol`
- **Description:** After success, `s_pendingCcipAdmin = address(0)`. A second call from the new admin should revert `OnlyPendingCCIPAdmin`. Untested.
- **Impact:** Slot-clear regression would be invisible.
- **Recommendation:** Add `test_AcceptCCIPAdminDoubleCallReverts`.

### TEST-12: `mint(address(0))` and `burn(address(0))` ordering not pinned
- **Severity:** LOW
- **Status:** FIXED — added two tests in `test/WrappedON.t.sol`: `test_MintToZeroAddressRevertsAndDoesNotInflate` asserts `ERC20InvalidReceiver` AND `ccipMintHeadroomUsed` unchanged; `test_BurnAddressOverloadZeroAddressRevertsAndDoesNotDesync` asserts `ERC20InvalidSender` AND `ccipMintHeadroomUsed` unchanged. The mint-path test pins the WriteCounter→Mint ordering (OZ rolls the counter write back on the `_mint(0)` revert); the burn-path test pins the WriteCounter→Burn ordering (OZ rolls the saturating-decrement back on the `_burn(0)` revert). Two complementary halves cover the symmetric class — a future refactor that decoupled counter and ERC20 path on either side would break one of them.
- **Location:** `test/WrappedON.t.sol`
- **Description:** `ccipMintHeadroomUsed` is incremented BEFORE `_mint`; on OZ 5.x `ERC20InvalidReceiver` the EVM rolls back, so it's safe today. No test pinned the ordering.
- **Impact:** A refactor decoupling the increment from the mint could leave `ccipMintHeadroomUsed` permanently inflated.
- **Recommendation:** Add `test_MintToZeroAddressRevertsAndDoesNotInflate` (and symmetric `burn(address(0))` test).

### TEST-13: Script-04 path-3 silent-revert disambiguation lacks dedicated mock
- **Severity:** MEDIUM
- **Status:** FIXED — new `MockSilentRevertModule` in `test/Script04Paths.t.sol` does an explicit `assembly { revert(0, 0) }`. New `test_Dispatch_Path3_SilentRevertFallsThrough` asserts the script falls through to path-4 `CannotResolveCCIPAdmin` when the module silently reverts (the same look-alike behaviour as a missing v1.5 selector). Together with `test_Dispatch_Path3_StructuredRevertPropagates`, both sides of the `reason.length != 0` branch are now under test.
- **Location:** `test/Script04Paths.t.sol`
- **Description:** Existing tests relied on the real v1.5 module's empty-revert behavior. A complementary mock that does an explicit `revert();` was missing, so an inversion of the `reason.length != 0` branch could pass.
- **Impact:** A regression dropping the `!= 0` check would silently swallow real v1.6 structured reverts.
- **Recommendation:** Add the silent-revert mock and a complementary structured-revert mock.

### TEST-14: Invariant handler omits two-step CCIP admin rotation
- **Severity:** LOW
- **Status:** FIXED — added `setCCIPAdminRace` and `acceptCCIPAdminRace` handler selectors in `test/WrappedONInvariant.t.sol`, both included in `targetSelector`. The handler tracks the current ccipAdmin internally so rotations interleave correctly with mint/burn. All four invariants (`BackingCoversSupply`, `CounterBoundedByBscLocked`, `CcipMintedSupplyWithinCap`, `ReserveMatchesNetDeposits`) still pass across the rotation paths.
- **Location:** `test/WrappedONInvariant.t.sol`
- **Description:** Two-step admin transitions were never interleaved with mint/burn under the fuzzer.
- **Impact:** Low likelihood of finding a bug, but a state-space gap.
- **Recommendation:** Add `setCCIPAdminRace` / `acceptCCIPAdminRace` handler functions.

### TEST-15: `releaseOrMint` direction not exercised under RMN curse
- **Severity:** LOW
- **Status:** FIXED — new `test_ReleaseOrMintRevertsWhenRMNCursed` in `test/PoolRoundtrip.t.sol` cursed the BSC selector on the ETH RMN, then asserted the typed `TokenPool.CursedByRMN` selector when `ethPool.releaseOrMint` is called via `ethOffRamp`. Combined with the existing outbound test, both curse-check branches (`_validateLockOrBurn` and `_validateReleaseOrMint`) are now under test.
- **Location:** `test/PoolRoundtrip.t.sol`
- **Description:** `test_LockOrBurnRevertsWhenRMNCursed` covered the outbound direction only.
- **Impact:** A regression that only patched one direction's curse check would pass the outbound test while silently letting funds arrive under a curse.
- **Recommendation:** Add `test_ReleaseOrMintRevertsWhenRMNCursed`.

### TEST-16: `test_DepositReentrancyGuardFires` was a false-negative
- **Severity:** MEDIUM
- **Status:** FIXED — `ReentrantMockON` now pre-funds itself with 100 ON and approves the wON contract from inside `transferFrom`, so the inner reentry's ERC20 accounting is satisfied and a removed `nonReentrant` modifier would no longer trivially revert via `ERC20InsufficientBalance`. The mock's `require(!success)` is paired with a typed-selector assertion `bytes4(ret) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector` so an inner revert from a *different* cause cannot masquerade as the guard firing.
- **Location:** `test/WrappedON.t.sol:39-65`
- **Description:** The inner reentry called `safeTransferFrom(rOn, rWon, 1)` while `address(rOn)` held zero balance, so the inner call reverted on insufficient balance regardless of whether `nonReentrant` fired. Removing the modifier still passed the test.
- **Impact:** False sense of security on the deposit-reentry guard.
- **Recommendation:** Assert the typed selector + give the inner call enough balance to reach the modifier.

### TEST-17: BSC-side outbound RMN curse on `lockOrBurn` was untested
- **Severity:** LOW
- **Status:** FIXED — new `test_BscLockOrBurnRevertsWhenRMNCursed` in `test/PoolRoundtrip.t.sol`. Cursed `bscRmn` against `ETH_SELECTOR`, asserted `bscPool.lockOrBurn(...)` reverts `TokenPool.CursedByRMN`. TEST-15 covered ETH-side outbound + inbound; TEST-17 closes the BSC-side outbound leg.
- **Location:** `test/PoolRoundtrip.t.sol`
- **Description:** A regression patching only the ETH pool's curse wiring would pass TEST-15 but let BSC users lock through a curse.
- **Impact:** Direction-asymmetric curse-bypass risk if missed.
- **Recommendation:** Symmetric test.

### TEST-18: `DeployerEnvMissing` revert path had no unit test
- **Severity:** LOW
- **Status:** DESIGN ACK — the harness `exposeCheckDeployerRenounced` already exercises the post-env-resolved code; the `run()`-level `vm.envOr(…)` → `DeployerEnvMissing` revert sequence is a tiny `if (addr == 0) revert` whose regression would surface immediately in any operator-side verify run. Adding a `vm.setEnv("MULTISIG", …)` test would also need to manage `DEPLOYER` unset across the test process which Foundry's env model makes brittle. Documented as a known minimal-coverage gap.
- **Location:** `script/08_PostDeployVerify.s.sol:94-106`, `test/Script08Verify.t.sol`
- **Description:** A future refactor that swapped the condition could silently restore the DEP-8 vacuous-satisfaction bug.
- **Impact:** Minimal — the assertion is two lines.
- **Recommendation:** Accept; revisit if env-set tests become a project pattern.

### TEST-19: Invariant handler admin-rotation selectors had a high no-op rate
- **Severity:** LOW
- **Status:** FIXED — `setCCIPAdminRace` now searches the actor pool for an actor distinct from the current admin (modulo-bounded indexing to avoid overflow under fuzz seeds near `uint256.max`); `acceptCCIPAdminRace` bootstraps a proposal when none is pending so every call contributes observable state. No-op rate now ~0 across both selectors at depth=50.
- **Location:** `test/WrappedONInvariant.t.sol:226-257`
- **Description:** Original selectors silently returned ~2/9 of the time when seeds resolved to the current admin or pending was zero — dilutes effective state-space coverage.
- **Impact:** Lower invariant coverage at fixed depth.
- **Recommendation:** Handler-side gating.

### TEST-20: Four typed-revert paths added in the second-pass had no negative coverage
- **Severity:** MEDIUM
- **Status:** FIXED — four new tests in `test/Script08Verify.t.sol`:
  - `test_CheckBscRebalancer_RevertsOnUnexpectedRebalancer` (CCIP-1 typed revert).
  - `test_CheckBscRebalancer_RevertsOnReadFailure` (DEP-19 typed revert).
  - `test_CheckRemoteLink_RevertsOnMalformedRemotePool` (DEP-9 typed revert).
  - `test_CheckRemoteLink_RevertsOnMalformedRemoteToken` (DEP-9 typed revert).
  Each uses the new `MockBadPool` fixture to drive a specific malformed-response case. A regression that inverted any of the four checks now fails an explicit test.
- **Location:** `test/Script08Verify.t.sol`
- **Description:** `UnexpectedRebalancer` and `MalformedRemoteEncoding` were defined but never exercised in tests; the script-06 idempotency branches and script-05 stale-wiring `require` were only exercised end-to-end (E2E tests perform the operations inline rather than driving the script's `run()`).
- **Impact:** A regression could land silently on the existing suite.
- **Recommendation:** Direct negative tests via a harness.

---

## Operational, build, docs (`OPS-*`)

### OPS-1: Mainnet deployment via README leaks private key on `ps aux`
- **Severity:** HIGH
- **Status:** FIXED — the raw-key path was removed entirely: `DEPLOY_FLAGS` signs via `--account $(ACCOUNT)` (keystore, default `deployer`), `DEPLOYER_PK` is gone from `.env.example`, and the Makefile/README/RUNBOOK document keystore signing as the only path (`cast wallet import deployer --interactive` + `--account deployer`). No `--private-key` remains anywhere in the deploy tooling, so there is no longer a default that leaks the key on `ps aux`.
- **Location:** `Makefile:6`, `README.md` (§4, §8)
- **Description:** `DEPLOY_FLAGS` hardcodes `--private-key $(DEPLOYER_PK)`, putting the raw key in process arguments visible to any process on the host and recorded in shell history. RUNBOOK §0.3 recommends `cast wallet import` + `--account deployer` — README does not mention it.
- **Impact:** An operator following README alone on mainnet exposes their key for the duration of the broadcast window.
- **Recommendation:** Add a security callout in README §4/§8 referencing the `cast wallet import deployer --interactive` + `--account deployer` flow. Provide a `DEPLOY_FLAGS_ACCOUNT` override in the Makefile so operators can switch without editing it.

### OPS-2: `make update-limits` post-handoff will revert — operator pays gas for nothing
- **Severity:** HIGH
- **Status:** FIXED — `make update-limits` accepts `CALLER_FLAGS` (e.g. `CALLER_FLAGS='--account ratelimit-admin'`) for post-handoff callers, and falls back to the deployer keystore account (`--account $(ACCOUNT)`) pre-handoff. The raw `DEPLOYER_PK` fallback was removed (keystore-only), so the pre-handoff path no longer puts a key in process args either.
- **Location:** `Makefile:144-151`, `README.md:173-178`, `RUNBOOK.md §4.1`
- **Description:** `update-limits` expands `DEPLOY_FLAGS` (hardcoded `--private-key $(DEPLOYER_PK)`). After handoff, the deployer is neither pool owner nor rate-limit admin; the call reverts `onlyOwner`. The Makefile guard only checks that `DEPLOYER_PK` is *set*.
- **Impact:** Operator broadcasts a revert-bound tx after handoff. The Makefile has no path for the multisig or a delegated `rateLimitAdmin` to make the call.
- **Recommendation:** Introduce a `CALLER_PK` (defaulting to `DEPLOYER_PK`) and/or an `--account` override path. Document explicitly in RUNBOOK §4.1 and the Makefile that post-handoff the caller must be the multisig or a delegated `rateLimitAdmin`.

### OPS-3: Submodules not pinned by branch in `.gitmodules`
- **Severity:** MEDIUM
- **Status:** FIXED — `.gitmodules` now carries an explicit header comment warning against `git submodule update --remote` and documenting the safe path (`git -C lib/<name> checkout <hash>`).
- **Location:** `.gitmodules`
- **Description:** All five submodules are pinned to exact release tags — `lib/chainlink-ccip` (`contracts-ccip-v1.6.1`), `lib/chainlink-evm` (`contracts-v1.4.0`), `lib/chainlink-local` (`v0.2.8`), `lib/forge-std` (`v1.16.1`), and `lib/openzeppelin-contracts` (`v5.6.1`); each gitlink commit resolves to its tag via `git describe --tags --exact-match`, and `foundry.lock` records the matching tag + rev. No `branch =` lock in any entry. `git submodule update --remote` (a common but wrong invocation) would advance all to upstream tip.
- **Impact:** Low in practice (the Makefile uses `--init --recursive`), but a misconfigured CI step that uses `--remote` could change compiler and library behaviour silently.
- **Recommendation:** Add a comment in `.gitmodules` warning against `--remote`, and add a dependency table to README listing the exact intended commit hashes for auditor cross-reference.

### OPS-4: No `[invariant]` block in `foundry.toml` — invariant tests run at weak defaults
- **Severity:** MEDIUM
- **Status:** FIXED — same change as TEST-2: explicit `[invariant]` table with `fail_on_revert=true`.
- **Location:** `foundry.toml`
- **Description:** Same root cause as TEST-2, called out separately as a config issue: `[profile.ci]` sets `fuzz.runs = 1000` but invariants run at Foundry defaults (256 runs, depth 15, `fail_on_revert = false`).
- **Impact:** Reserve-safety invariants are weaker than intended.
- **Recommendation:** Add `[invariant]` (or `[profile.ci.invariant]`) explicit settings with `fail_on_revert = true`.

### OPS-5: No mid-sequence failure recovery instructions for `make deploy-eth/-bsc`
- **Severity:** MEDIUM
- **Status:** FIXED — README §5 now carries a "Recovery after mid-sequence failure" callout describing the safe action (re-run the same `make` target — all scripts are idempotent — and explicitly NOT manually re-running individual scripts).
- **Location:** `Makefile:91-106`, `RUNBOOK.md §1`, `README.md §5`
- **Description:** Five sequential `forge script` calls. All scripts are idempotent (per CLAUDE.md), but neither RUNBOOK nor README tells operators that the safe recovery action is simply re-running the same `make` target from the start.
- **Impact:** Operators in mid-failure may guess at manual recovery, miscalculate which scripts already executed, and skip a step (most likely `03_GrantRoles`) → a pool that cannot mint.
- **Recommendation:** Add a "Recovery" callout in RUNBOOK §1 and README §5: "If any script fails, re-run the same `make` target. All scripts are idempotent. Do not manually re-run individual scripts."

### OPS-6: CLAUDE.md command for `make test` does not match the actual Makefile target
- **Severity:** LOW
- **Status:** FIXED — CLAUDE.md "Build & test" block updated to reference `make test` with a note that fork tests self-skip when RPC vars are absent.
- **Location:** `CLAUDE.md:99`, `Makefile:54-55`
- **Description:** CLAUDE.md shows `forge test -vvv --no-match-path "test/fork/**"`. The actual target is `forge test -vvv` (fork tests self-skip when RPC vars are absent). Functionally equivalent, but a developer comparing the two may distrust both.
- **Impact:** Minor confusion.
- **Recommendation:** Update CLAUDE.md to match, with a note that fork tests self-skip.

### OPS-7: No SECURITY.md / disclosure policy in tree (this file is the restoration)
- **Severity:** LOW
- **Status:** ALREADY ADDRESSED — this very file restored the disclosure policy with `security@orochi.network`.
- **Location:** repository root
- **Description:** SECURITY.md was removed in commit `dea561d` and is being restored by this review. Without a disclosure channel, security researchers have no guidance on how to report critical findings before public disclosure.
- **Impact:** Increased risk of public disclosure before a patch.
- **Recommendation:** This file (as committed) addresses the gap. Maintain `security@orochi.network` as the disclosure address and consider enabling GitHub Security Advisories.

### OPS-8: CI does not gate Slither — `continue-on-error: true`
- **Severity:** LOW
- **Status:** DEFERRED — Slither gating is left advisory until immediately before mainnet broadcast. At that point the `continue-on-error: true` will be removed (or `--fail-on HIGH` added) so a HIGH detector blocks merges. Currently advisory so the pre-mainnet rule cleanup can be done in a single audit-final commit rather than retroactively across PRs.
- **Location:** `.github/workflows/ci.yml:48`
- **Description:** Slither runs but is non-blocking. New HIGH/CRITICAL detectors on `src/WrappedON.sol` would not block merges.
- **Impact:** Pre-mainnet, static analysis is advisory rather than gating.
- **Recommendation:** Before mainnet, drop `continue-on-error: true` (or use `--fail-on HIGH`). Suppress vendored-library noise via `.slither.config.json`.

### OPS-9: `.env.example` missing `MULTISIG`
- **Severity:** LOW
- **Status:** FIXED — `MULTISIG=0x0…0` placeholder added to `.env.example` with a comment explaining when it's required.
- **Location:** `.env.example`, `Makefile:117,129,138`
- **Description:** `handoff`, `handoff-all`, `renounce` all require `$(MULTISIG)`. `.env.example` does not list it.
- **Impact:** Operator confusion at the handoff step.
- **Recommendation:** Add `MULTISIG=0x000…000  # Gnosis Safe address; required for handoff-all and renounce` to `.env.example`.

### OPS-10: No multisig pre-acceptance simulation guidance in RUNBOOK §3.2
- **Severity:** LOW
- **Status:** FIXED — RUNBOOK §3.2 now has a "Verify each transaction before signing" subsection with explicit instructions (Safe simulation, Tenderly, cross-check against `deployments/<chainId>.json`, post-acceptance `make verify-*` run).
- **Location:** `RUNBOOK.md §3.2`
- **Description:** The five multisig transactions are listed but no guidance is given on simulating them (Safe built-in, Tenderly, or `forge script --simulate`) before signing. The BSC pool owner is the custody-grade authority over the entire locked-ON reserve — a typo'd calldata target here is high-consequence.
- **Impact:** Signers may sign without verifying target addresses; an incorrect target would still revert ("not pending owner") but extends the deployer-retention window unnecessarily.
- **Recommendation:** Add: "Before signing each transaction, simulate via Safe / Tenderly. Cross-check target addresses against `deployments/<chainId>.json`. Run `make verify-eth` / `make verify-bsc` after acceptance."

### OPS-11: `remappings.txt` duplicated `foundry.toml:remappings`
- **Severity:** LOW
- **Status:** FIXED — deleted `remappings.txt`. `foundry.toml`'s `remappings` table is now the single source of truth, with a header comment warning future contributors not to recreate the sibling file. Foundry gives `remappings.txt` precedence when both exist, so the duplication was a silent-divergence trap.
- **Location:** `remappings.txt` (deleted), `foundry.toml:17-26`
- **Description:** Both files listed the same four remappings. An edit to one but not the other would silently change resolution (most dangerous for `@chainlink/contracts-ccip/` drifting to a different vendored version).
- **Impact:** Latent — easy to introduce a divergence in a future PR.
- **Recommendation:** Delete `remappings.txt`; keep only `foundry.toml`'s table.

### OPS-12: Slither installed without a version pin
- **Severity:** LOW
- **Status:** FIXED — `pip3 install slither-analyzer==0.11.0` in `.github/workflows/ci.yml`. New detectors or behaviour changes upstream no longer silently alter CI output. Refresh deliberately on bumps. Combined with OPS-8 (gating flipped immediately before mainnet broadcast), the pre-mainnet sign-off uses the same Slither version as the lead-up.
- **Location:** `.github/workflows/ci.yml:63`
- **Description:** Pre-fix `pip3 install slither-analyzer` followed upstream. New detector or behaviour change silently alters CI output.
- **Impact:** Latent — CI signal could drift without a code change in the repo.
- **Recommendation:** Pin to a tested release.

### OPS-13: Slither output not uploaded to GitHub Code Scanning
- **Severity:** LOW
- **Status:** DEFERRED — pre-mainnet hardening. SARIF upload + `security-events: write` adds a meaningful "appears in the PR Security tab" surface, but it's strictly a visibility nicety on top of the OPS-8 gating change. Bundled with OPS-8 so both land together in the final pre-mainnet workflow commit.
- **Location:** `.github/workflows/ci.yml:45-73`
- **Description:** Findings live only in workflow logs; nothing surfaces in the PR Security tab.
- **Impact:** Operator visibility only.
- **Recommendation:** Add `--sarif slither.sarif`, `permissions: security-events: write`, and a `github/codeql-action/upload-sarif@v3` step.

### OPS-14: `foundry-rs/foundry-toolchain@v1` moves with the major version
- **Severity:** INFO
- **Status:** FIXED — pinned to `foundry-rs/foundry-toolchain@v1.4.0` in both `test` and `slither` jobs. Refresh deliberately. SHA-pinning is the next hygiene step before mainnet broadcast.
- **Location:** `.github/workflows/ci.yml:24,58`
- **Description:** `v1` is a moving major-version pointer; a regression on the next CI run would silently alter build behaviour.
- **Impact:** Latent; standard supply-chain hygiene.
- **Recommendation:** Pin to a specific Foundry release tag and SHA-pin the action reference.

### OPS-15: New env vars missing from `.env.example`
- **Severity:** LOW
- **Status:** FIXED — `.env.example` now lists commented-out `DEPLOYER`, `OUTBOUND_ENABLED`, `INBOUND_ENABLED`, `STRICT_RATE_LIMITS` (introduced by DEP-8 / DEP-16 / CCIP-10) with usage notes pointing back to the relevant finding IDs.
- **Location:** `.env.example`
- **Description:** `DEPLOYER` is load-bearing for `make verify-*` post-handoff; an operator hitting `DeployerEnvMissing` with no template entry had nothing to copy.
- **Impact:** Operator setup friction.
- **Recommendation:** Add to template.

### OPS-16: `CALLER_FLAGS` Makefile expansion is unquoted
- **Severity:** INFO
- **Status:** DOC ADDED — `.env.example` now warns that `CALLER_FLAGS` must be strictly `--account <name>` or `--keystore <path>` and must NOT contain shell metacharacters. Threat model assumes a trusted local `.env`; the documented constraint matches what the Makefile target's textual expansion requires.
- **Location:** `Makefile` (update-limits target), `.env.example`
- **Description:** A `.env` value of `--account x; rm -rf deployments/` would produce two shell commands at broadcast time.
- **Impact:** Mitigated by the documented constraint + trusted-`.env` assumption.
- **Recommendation:** Strict-allowlist validation in the Makefile is the next step; documented for now.

### OPS-17: Test count stale in `README.md` / `RUNBOOK.md`
- **Severity:** LOW
- **Status:** FIXED — both updated to `130 non-fork tests (126 unit/integration + 4 stateful invariants)`. Same edit applied to `CLAUDE.md`, `docs/ARCHITECTURE.md`, and this file.
- **Location:** `README.md:46`, `RUNBOOK.md:74`, `CLAUDE.md:89`, `docs/ARCHITECTURE.md:550`
- **Description:** Stale "111 tests" referenced post-second-pass.
- **Impact:** Doc drift.
- **Recommendation:** Update; track via a CI grep gate going forward.

### OPS-18: `[invariant]` table lacked a comment about local-vs-CI asymmetry
- **Severity:** INFO
- **Status:** FIXED — `foundry.toml`'s `[invariant]` block now has an inline comment explaining that `make test` uses the local defaults (256/50) while CI's `FOUNDRY_PROFILE=ci` overrides at 500/100. A green local `make test` does not imply a green CI run.
- **Location:** `foundry.toml:33-46`
- **Description:** Two configs in the same file, neither pointed at the other.
- **Impact:** Operator confusion only.
- **Recommendation:** Inline comment.

### OPS-19: `Wrapped` event rename not surfaced in README
- **Severity:** LOW
- **Status:** FIXED — README "Trust-model / events" bullet now explicitly notes the `amount → received` rename + that ABI consumers reading parameters by name need to update bindings; consumers reading by index are unaffected.
- **Location:** `README.md` (Trust-Model / events bullets)
- **Description:** WON-9 was internal to the contract changelog; README didn't reflect it.
- **Impact:** Integration friction for indexers that use name-based parameter access.
- **Recommendation:** Surface in README.

### OPS-20: `_assertEnabledAndConfigured` was effectively test-only after the CCIP-10 split
- **Severity:** INFO
- **Status:** DESIGN ACK — `_assertEnabledAndConfigured` is retained as a strict-mode shim that delegates to `_assertConfiguredOrWarn(strict=true)`. NatSpec calls it out as the "strict gate" entrypoint; tests use it via the harness without threading the `strict` toggle. Deleting the shim and routing the harness through `exposeAssertConfiguredOrWarn` is possible but increases test churn for no behaviour change.
- **Location:** `script/08_PostDeployVerify.s.sol:215-227`
- **Description:** After CCIP-10 split off `_assertConfiguredOrWarn`, the original helper became a one-line delegator only invoked from the harness.
- **Impact:** Test-only dead code in the production script.
- **Recommendation:** NatSpec.

### OPS-21: ARCHITECTURE.md handler-action count stale (7 vs actual 9)
- **Severity:** LOW
- **Status:** FIXED — `docs/ARCHITECTURE.md:539` updated to `4 stateful invariants over 9 handler actions` (TEST-6 added two burn-overload handlers, TEST-14 added two admin-rotation handlers).
- **Location:** `docs/ARCHITECTURE.md`
- **Description:** Inherited from the pre-second-pass count.
- **Impact:** Doc drift.
- **Recommendation:** Update to match `targetSelector` length.

### OPS-22: Stale `H-` / `C-` audit-tag cross-references
- **Severity:** LOW
- **Status:** FIXED — references in `RUNBOOK.md` and `CLAUDE.md` (and the new `docs/ARCHITECTURE.md`) updated inline to point at the current WON-/DEP-/CCIP-/TEST-/OPS- IDs with the legacy tag in parentheses (e.g. "`TEST-7` — legacy audit tag H-4"). `H-5` had no current ledger entry (the half-handoff footgun is closed operationally by `make handoff-all` rather than at the script level) and is annotated as such.
- **Location:** `RUNBOOK.md:30, 156, 163, 165, 221`, `CLAUDE.md:120`, `docs/ARCHITECTURE.md:580`
- **Description:** The original audit's `H-`/`C-` IDs were replaced by the per-domain WON-/DEP-/CCIP-/TEST-/OPS- scheme in commit `3253efe`; cross-refs in the operator docs hadn't been retrofitted.
- **Impact:** An auditor clicking through couldn't resolve the references.
- **Recommendation:** Inline retrofit + legacy-tag note.

### OPS-23: Documented testnet deploy procedure cannot succeed unmodified
- **Severity:** MEDIUM
- **Status:** DOC ADDED — new RUNBOOK §1.0 "Deploy a mock ON token (testnet only)" tells operators to deploy a `MockERC20("Orochi Network (Testnet)", "ON", 18)` and patch `Helper.sol` with the resulting address before running scripts 01/02 on Sepolia / BSC testnet. A `script/00_DeployMockON.s.sol` automating this is the next-step recommendation (tracked here for pre-mainnet follow-up).
- **Location:** `RUNBOOK.md` §1.0 (new), `README.md` §1, `docs/ARCHITECTURE.md` §10
- **Description:** `Helper.sol` intentionally leaves `onToken: address(0)` for chainids `11_155_111` / `97`; scripts 01 / 02 `_requireSet` it. The documented `make deploy-eth RPC=sepolia` / `make deploy-bsc RPC=bsc_testnet` reverted immediately with `MissingAddress`.
- **Impact:** Testnet rehearsal — the headline pre-mainnet ritual — blocked.
- **Recommendation:** Document the manual mock deploy now; script-based path before mainnet.

### OPS-24: `make test-e2e` description didn't match the recipe
- **Severity:** LOW
- **Status:** FIXED — `Makefile`, `CLAUDE.md`, and the README test list updated to read "everything except WrappedON unit tests and forks". The broader sweep (Deployments, Script04..08, WrappedONInvariant) is the actually-useful CI loop.
- **Location:** `Makefile:9-14`, `CLAUDE.md:91`, `README.md:53`
- **Description:** The recipe runs `--no-match-path 'test/{WrappedON.t.sol,fork/**}'` which sweeps in 9 files / 70+ tests, but the description claimed "PoolRoundtrip + DeploymentE2E" only.
- **Impact:** Operator confusion.
- **Recommendation:** Match descriptions to recipe.

### OPS-25: `make help` omits `handoff-all` and `precheck-helper`
- **Severity:** LOW
- **Status:** FIXED — `make help` now lists `precheck-helper`, `handoff-all`, `fmt`, and `patch-pragmas`. README §9 / RUNBOOK §3.1 already recommend `handoff-all` as the preferred two-chain handoff; `make help` now matches.
- **Location:** `Makefile:8-30`
- **Description:** Operators discovering targets via `make help` saw only the per-chain `handoff` target.
- **Impact:** Discoverability.
- **Recommendation:** Add to help block.

### OPS-26: CLAUDE.md "Test coverage gaps" cited a SECURITY.md section that no longer existed
- **Severity:** LOW
- **Status:** FIXED — CLAUDE.md bullet rewritten to point at `TEST-1..TEST-20` per-finding entries with status callouts. The original "8 tracked gaps" phrasing was correct in spirit but cited a section title that disappeared in the SECURITY.md restoration commit.
- **Location:** `CLAUDE.md:122`
- **Description:** Dangling ledger reference.
- **Impact:** Doc drift.
- **Recommendation:** Update to current scheme.

### OPS-27: README submodule commit-hash table never landed (half of OPS-3)
- **Severity:** INFO
- **Status:** DEFERRED — bundled with the pre-mainnet workflow commit alongside OPS-8 (Slither gating) and OPS-13 (SARIF upload). The `lib/chainlink-ccip` / `lib/chainlink-evm` pin tags are documented in prose at README:15 and ARCHITECTURE.md §3.2; an enumerated SHA table is the cross-reference aid an auditor reads `git submodule status` for today, and is worth adding once.
- **Location:** `README.md` (top-of-file), `docs/ARCHITECTURE.md` §3.2
- **Description:** OPS-3's original recommendation was two-part; only `.gitmodules` warning landed.
- **Impact:** Auditor cross-reference friction.
- **Recommendation:** SHA table in README before mainnet broadcast.

### OPS-28: `setRateLimitAdmin` + registry `transferAdminRole` rotations not monitored
- **Severity:** LOW
- **Status:** FIXED — monitoring table now includes `setRateLimitAdmin(addr)` calldata trace (both pools, **High** — `onlyOwner`, no event) and `AdministratorTransferRequested`/`AdministratorTransferred` on `TokenAdminRegistry` (**High**). The wON `CCIPAdminTransferProposed`/`Transferred` was already covered; OPS-28 closes the registry-side sibling.
- **Location:** `RUNBOOK.md` §3 (Trust-model monitoring table)
- **Description:** §4.1.1 explicitly recommends delegating `rateLimitAdmin` to a hot key; without monitoring, a delegation calldata trace was the only signal of the change.
- **Impact:** Operator-visibility gap on legitimate-but-significant calls.
- **Recommendation:** Add to monitoring table.

### OPS-29: BSC ON non-mintability not documented or verified
- **Severity:** INFO
- **Status:** FIXED — RUNBOOK §0.2 now includes a `cast call` probe block for likely mint surfaces on BSC ON (`mint(address,uint256)`, `owner()`, `totalSupply()`). The bridge's `MAX_CCIP_MINTED = 100M` assumes the BSC supply is fixed at 100M; if BSC ON had a minter and supply exceeded 100M, excess BSC ON could be locked but not reflect to ETH, stranding users with the surplus. ARCHITECTURE.md §13 cross-references OPS-29 in the open-items list.
- **Location:** `RUNBOOK.md` §0.2, `docs/ARCHITECTURE.md` §13
- **Description:** ETH ON is tagged "non-mintable" in CLAUDE.md / README; BSC ON was tagged "non-upgradeable" only — a weaker property.
- **Impact:** Cap-vs-supply asymmetry under a future mint event.
- **Recommendation:** Document + verify via `cast call`.

### OPS-30: `RoleAdminChanged` not in handoff-window monitoring
- **Severity:** LOW (forward-compat / defence-in-depth)
- **Status:** FIXED — added `RoleAdminChanged(role, prev, new)` on `MINTER_ROLE`/`BURNER_ROLE` (wON) to the monitoring table at **High**. Annotated as forward-compat because OZ AccessControl 5.x's `_setRoleAdmin` is internal; wON calls it exactly once at `initialize` (the one-time `UPGRADER_ROLE` self-admin — UPG-1, mitigation #3) and does not expose it externally, so no post-deploy admin rotation of `MINTER_ROLE`/`BURNER_ROLE` is reachable — but the monitor catches one if a future impl ever adds an external path.
- **Location:** `RUNBOOK.md` §3 (monitoring table)
- **Description:** §3.1 alerts on `RoleGranted` but not on a `RoleAdminChanged` swap that would silently re-parent who can grant.
- **Impact:** Forward-compat only.
- **Recommendation:** Add row.

---

## Upgrade model (`UPG-*`)

_Added 2026-06-23: wON became UUPS-upgradeable behind an ERC1967Proxy in branch
`feat/won-upgradeable`. The "non-upgradeable by design" stance documented in an earlier
version of this file is superseded. History: the original rationale was "migration path =
redeploy + re-register"; that remains an option but is no longer the only path._

### UPG-1: Upgrade authority is custody-grade

- **Severity:** HIGH (by design — mitigated to DESIGN ACK)
- **Status:** DESIGN ACK (mitigations documented below). The `UPGRADER_ROLE`-admin timelock-bypass flagged in PR #47 review was CLOSED 2026-06-23 — see mitigation #3.
- **Description:** `_authorizeUpgrade` is gated by `UPGRADER_ROLE`, held by the `TimelockController`. A TimelockController whose proposer/executor roles are held by a compromised multisig can schedule and execute an upgrade to a malicious implementation, which could drain the wON reserve, mint unbacked wON past `MAX_CCIP_MINTED`, or destroy any other state. This is a custody-grade risk analogous to the BSC pool's `setRebalancer` path.
- **Mitigations:**
  1. **48h mandatory delay** (the `TimelockController` default; `minDelay = 172800 seconds`). Any upgrade attempt is visible on-chain for 48 hours before it can execute. Monitoring on `CallScheduled` from the timelock gives the community and security team time to respond (revoke, cancel, or redeploy). This window is genuinely enforced because of mitigation #3.
  2. **Emergency pause** — the multisig's `PAUSER_ROLE` lets it halt value paths immediately if a malicious upgrade is in flight, limiting damage before the timelock executes.
  3. **Self-administered `UPGRADER_ROLE` (on-chain enforced)** — `initialize` calls `_setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE)`, so the role's admin is `UPGRADER_ROLE` itself (held only by the `TimelockController`), NOT `DEFAULT_ADMIN_ROLE`. Without this, OZ's default makes `DEFAULT_ADMIN_ROLE` (the ops multisig post-handoff) the admin of `UPGRADER_ROLE`, letting it `grantRole(UPGRADER_ROLE, itself)` and `upgradeToAndCall` in one transaction with **no delay** — making mitigation #1's 48h window advisory, not enforced. With self-administration, only the timelock can grant/revoke upgrade authority and every such grant is itself a 48h-timelocked tx; the role is set to the timelock at `initialize` and never granted to an EOA. Tests: `test_UpgraderRoleIsSelfAdministered`, `test_DefaultAdminCannotGrantUpgraderRole`, `test_TimelockCanGrantUpgraderRole` (WrappedONUpgrade.t.sol).
  4. **Implementation address monitoring** — `Upgraded(implementation)` on the proxy (ERC1967 standard event) must be a Critical alert in the monitoring table (RUNBOOK §Trust model).
  5. **Storage hygiene** — state is in ERC-7201 namespaced storage; accidental collision from a future impl adding fields is prevented by the namespace isolation. Field ordering in `WrappedONStorage` must not change across upgrades.
- **`PAUSER_ROLE` admin:** intentionally left as the OZ default `DEFAULT_ADMIN_ROLE` (the ops multisig manages pausers). Acceptable because pause is halt-only (UPG-4) — a liveness authority, not an upgrade/custody one; a malicious pauser can at worst freeze the value paths, which `unpause` (also multisig) reverses. Pinned by `test_PauserRoleAdminIsDefaultAdmin`.
- **Residual risk:** A compromised multisig that also holds `PAUSER_ROLE` (post-handoff) could pause AND schedule an upgrade — but it must still route the upgrade through the 48h timelock (mitigation #3 removes the no-delay bypass), so the window stands. Key management of the multisig signers is the load-bearing control.

### UPG-2: `_disableInitializers` in constructor prevents impl takeover

- **Severity:** HIGH (if absent) — mitigated by code
- **Status:** FIXED (code; present in shipped `WrappedON.sol`)
- **Description:** An implementation contract with an open `initialize` function can be taken over by a third party (anyone can call `initialize` on the bare implementation and set themselves as admin). OZ's standard mitigation is `_disableInitializers()` in the implementation constructor.
- **Fix:** `WrappedON` constructor calls `_disableInitializers()` with the `@custom:oz-upgrades-unsafe-allow constructor` NatSpec. Test: `test_ImplCannotBeInitialized` (or equivalent).
- **Impact if removed:** A third party could claim `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE`, and `s_ccipAdmin` on the bare implementation (not the proxy). The implementation holds no value, but registering it in `TokenAdminRegistry` or misleading integrators about the proxy's state would be an attack surface.

### UPG-3: ERC-7201 storage namespace prevents slot collision

- **Severity:** MEDIUM (if unaddressed) — mitigated by code
- **Status:** DESIGN ACK (mitigated by ERC-7201 namespacing + documented invariant)
- **Description:** UUPS upgrades that extend storage by inserting new fields in the middle of a struct break existing storage slot mappings for all fields that follow, causing silent data corruption.
- **Mitigation:** All persistent state lives in a single `WrappedONStorage` struct at slot `0xc9356e8aa19da270b9a132fda93e9af24668c8487450db15f9b9e8baeb751900` (the ERC-7201 namespace for `orochi.storage.WrappedON`, verified against `cast index-erc7201`). New fields may only be **appended** to the end of `WrappedONStorage`. This constraint is enforced by convention (documented in RUNBOOK §4.7), not by on-chain checks. The foundry-upgrades FFI plugin was evaluated and intentionally NOT adopted to keep CI forge-only; the storage-preservation invariant is verified instead via the upgrade state-preservation test suite.
- **Operator note:** Any upgrade PR must include a diff showing no existing field was moved or resized. Code review is the gate.

### UPG-4: Pause is liveness-only — does not prevent theft by a compromised pool

- **Severity:** MEDIUM (awareness / threat-model clarity)
- **Status:** DESIGN ACK (documented)
- **Description:** `pause()` halts `mint`, `burn*`, `deposit`, and `withdraw` — all four value paths carry `whenNotPaused` — but ERC20 `transfer`/`transferFrom` stay live. So a paused bridge DOES block even a compromised `MINTER_ROLE` pool from minting. Pause is nonetheless an emergency stop, not theft-prevention: the underlying exploit (compromised pool, bad upgrade, etc.) still exists and needs separate remediation while paused. A compromised `PAUSER_ROLE` can only grief — indefinitely halt the value paths — and cannot move funds, since transfers stay live and pause grants no spending authority.
- **Impact (compromised pauser):** Griefing — `mint`/`burn` halted while CCIP messages queue; `deposit`/`withdraw` halted for ETH-side users. Resumable by any multisig signer calling `unpause`.
- **Impact (compromised pool with `MINTER_ROLE`):** A paused bridge BLOCKS the compromised pool's mint path too — pause inadvertently provides partial mitigation against a compromised pool if the multisig can pause before the attacker mints.
- **Residual risk:** A compromised multisig could unpause immediately after pausing; the 48h timelock does not cover `pause`/`unpause` (intentional — emergency response requires speed). Key management of the Safe signers and threshold is the load-bearing control.

---

# Closing note

This review intentionally excludes vendor library audit findings — Chainlink CCIP
1.6.1 and OpenZeppelin 5.x are independently audited and pinned. Re-review is
recommended after any submodule bump, after any change to `src/WrappedON.sol`,
or before mainnet broadcast. The HIGH-severity findings should be closed prior
to mainnet rollout; MEDIUM findings should be triaged and either closed or
explicitly accepted with documented rationale.
