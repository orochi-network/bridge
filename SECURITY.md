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
| FIXED               |    24 |
| DOC ADDED           |     3 |
| FALSE POSITIVE      |     4 |
| ALREADY ADDRESSED   |     1 |
| DESIGN ACK          |     3 |
| DEFERRED            |     2 |
| **Total**           | **37** |

(Four of the original entries are records of "investigated, no defect" — `CCIP-5`,
plus the three `INFO` design acknowledgements — so the effective resolution rate
on actionable findings is 31 / 33.)

Tests after the remediation pass: **111 passing, 0 failing** (was 102 before).

Two HIGH-severity findings remain `DEFERRED`:

- **TEST-7** — requires live mainnet investigation of the BSC ON token's admin path
  before the fork test can be tightened.
- **OPS-8** — Slither CI gating left advisory until immediately before mainnet
  broadcast; will be flipped to `--fail-on HIGH` then.

The other four originally HIGH-severity findings (DEP-1, CCIP-1, TEST-1, TEST-2,
OPS-1, OPS-2) are all `FIXED`.

- **Scope:** `src/`, `script/`, `test/`, `Makefile`, `foundry.toml`, `.gitmodules`,
  `README.md`, `RUNBOOK.md`, `CLAUDE.md`, `.github/workflows/`, `.env.example`.
- **Out of scope:** vendored code in `lib/ccip` and `lib/openzeppelin-contracts`
  (audited upstream; pinned at `v2.17.0-ccip1.5.16` / OZ 5.x).
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
| WON   |        0 |    0 |      0 |   4 |    3 |     7 |
| DEP   |        0 |    1 |      2 |   3 |    1 |     7 |
| CCIP  |        0 |    1 |      3 |   3 |    1 |     8 |
| TEST  |        0 |    2 |      4 |   3 |    0 |     9 |
| OPS   |        0 |    2 |      3 |   5 |    0 |    10 |
| **Total** | **0** | **6** | **12** | **18** | **5** | **41** |

**Headline:** no CRITICAL findings. The custom contract surface (`WrappedON.sol`)
is clean — the highest WON finding is LOW. The bulk of the actionable risk
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
- **Location:** `src/WrappedON.sol:146-153`
- **Description:** `deposit` and `withdraw` both revert on `amount == 0`, but `mint` (the CCIP entrypoint) does not. A zero-amount call increments nothing and mints nothing, but it emits an ERC20 `Transfer(pool, account, 0)` event and an OZ AccessControl check passes silently. Under normal CCIP operation the pool will never pass zero, but the asymmetry is worth eliminating for indexer hygiene and to match the pattern of every other state-mutating entry point in the contract.
- **Impact:** No meaningful state harm; a misbehaving or test pool can spam zero-value Transfer events. No financial loss.
- **Recommendation:** Add `if (amount == 0) revert ZeroAmount();` at the top of `mint`, matching the `deposit`/`withdraw` guards.

### WON-2: `burn(address,uint256)` overload burns without allowance — design acknowledgement
- **Severity:** INFO
- **Status:** DESIGN ACK — the recommended on-chain count check requires `AccessControlEnumerable`, which expands inheritance for marginal benefit. The single-pool invariant is enforced operationally: script 03 (`GrantRoles`) only grants to the deployed pool, the multisig handoff transfers admin to a Safe, and the RUNBOOK monitoring table pages on every `RoleGranted(BURNER_ROLE, *)`. Adding `AccessControlEnumerable` is left as an option for a future redeploy if multi-grantee scenarios become realistic.
- **Location:** `src/WrappedON.sol:164-167`
- **Description:** The two-argument `burn(address account, uint256 amount)` overload calls `_burn(account, amount)` with no `_spendAllowance` check, matching the `IBurnMintERC20` interface contract. The test at `test/WrappedON.t.sol:264` explicitly verifies this. Safety relies entirely on `BURNER_ROLE` exclusivity. If `BURNER_ROLE` were ever granted to more than one address, any role holder could burn arbitrary balances without delegation.
- **Impact:** Single-pool deployment is safe; multi-grantee deployment is not.
- **Recommendation:** Add a `getRoleMemberCount(BURNER_ROLE) <= 1` post-deploy assertion to `script/08_PostDeployVerify.s.sol`, and document the constraint in the multisig handoff runbook.

### WON-3: `ccipMintedSupply` can be depressed below true BSC-locked balance
- **Severity:** LOW
- **Status:** FIXED — RUNBOOK monitoring table now keys on `IERC20(ON).balanceOf(BSC_LockReleaseTokenPool)` as the authoritative locked-balance read with an explicit note that `ccipMintedSupply` is a local indicator only.
- **Location:** `src/WrappedON.sol:234-237`
- **Description:** The saturating-decrement in `_decrementCcipMinted` is intentional: it handles deposit-backed wON being bridged outbound without underflowing. The consequence is that `ccipMintedSupply` can read zero while a non-trivial amount of BSC-locked ON exists. Monitoring alerts keyed only to `ccipMintedSupply` approaching `MAX_CCIP_MINTED` may produce false negatives. (Closely related to CCIP-7.)
- **Impact:** `ccipMintedSupply` is not a reliable real-time BSC-exposure gauge. Operational/monitoring risk only.
- **Recommendation:** RUNBOOK monitoring guidance should key on the BSC `LockReleaseTokenPool` locked balance (on-chain call or event index) alongside `ccipMintedSupply`.

### WON-4: No named event emitted on `mint` / `burn` paths
- **Severity:** LOW
- **Status:** FIXED — `CCIPMinted(account, amount, ccipMintedSupply)` emitted from `mint`; `CCIPBurned(account, amount, ccipMintedSupply)` emitted from all three burn entrypoints. Tests: `test_MintEmitsCCIPMinted`, `test_BurnEmitsCCIPBurned_*`.
- **Location:** `src/WrappedON.sol:146-153`, burn entrypoints
- **Description:** `deposit` emits `Wrapped`, `withdraw` emits `Unwrapped`, but the CCIP `mint` path emits only the inherited ERC20 `Transfer(address(0), account, amount)`. Burns are similar. Indexers cannot distinguish CCIP-inbound mints from deposit wraps by event topic alone.
- **Impact:** Cross-chain reconciliation tooling must correlate with pool-level CCIP events.
- **Recommendation:** Add `CCIPMinted(address indexed account, uint256 amount, uint256 ccipMintedSupply)` (and optionally `CCIPBurned`) for direct on-chain auditability.

### WON-5: Overwriting pending CCIP admin produces no cancellation event
- **Severity:** LOW
- **Status:** FIXED — `CCIPAdminProposalCancelled(address)` emitted in `setCCIPAdmin` when overwriting a different pending address. Identical re-proposal does NOT emit (verified by `test_SetCCIPAdminRePropose_DoesNotEmitCancellation`). Test: `test_SetCCIPAdminEmitsCancellationWhenOverwritten`.
- **Location:** `src/WrappedON.sol:193-205`
- **Description:** `setCCIPAdmin` allows the current admin to overwrite `s_pendingCcipAdmin` with a new address at any time. The prior proposed address receives no on-chain cancellation signal. If they had a multisig transaction queued for `acceptCCIPAdmin`, it will revert with `OnlyPendingCCIPAdmin`.
- **Impact:** Operational confusion; no funds at risk.
- **Recommendation:** Emit `CCIPAdminProposalCancelled(address indexed cancelled)` when overwriting a non-zero pending admin with a different address.

### WON-6: `withdraw` orders balance-check before burn — currently safe
- **Severity:** INFO
- **Status:** DESIGN ACK — no code change. Recorded for completeness.
- **Location:** `src/WrappedON.sol:128-139`
- **Description:** Current ordering: read `ON.balanceOf(this)` → revert if insufficient → `_burn` → `safeTransfer`. With ON as a plain non-hookable ERC20 and `nonReentrant` active, no attack path exists. This is purely a defensive note: if `ON` were ever replaced by an ERC-777-style token with receiver hooks, the ordering would still be correct because reentry would observe the post-burn `totalSupply`.
- **Impact:** None under current ON token.
- **Recommendation:** No code change required. The `ON` immutable + non-upgradeable design closes this path.

### WON-7: `supportsInterface` omits `IERC20Metadata`
- **Severity:** INFO
- **Status:** FIXED — `IERC20Metadata.interfaceId` added to `supportsInterface`. Test updated: `test_SupportsInterfacePositiveAndNegative` now asserts `true`.
- **Location:** `src/WrappedON.sol:222-226`
- **Description:** The contract satisfies `IERC20Metadata` (via OZ ERC20) but does not return `true` for its interface ID. Integrations that ERC-165-check before reading `decimals()` will get a false negative.
- **Impact:** Minor integration friction; no security risk.
- **Recommendation:** Add `|| interfaceId == type(IERC20Metadata).interfaceId`.

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

---

## CCIP integration & pool wiring (`CCIP-*`)

### CCIP-1: BSC pool `withdrawLiquidity` is rebalancer-gated, but `setRebalancer` is owner-set with no monitor
- **Severity:** HIGH
- **Status:** FIXED — `script/08_PostDeployVerify.s.sol` now calls `_checkBscRebalancer(pool)` on every BSC verify run and reverts `UnexpectedRebalancer` if the slot is non-zero. The RUNBOOK monitoring table already pages on `setRebalancer` calldata; the verify-time assertion catches an accidental set at deploy and on every operator re-verify.
- **Location:** `lib/ccip/contracts/src/v0.8/ccip/pools/LockReleaseTokenPool.sol:107-113`, `script/02_DeployPools.s.sol:53`
- **Description:** `acceptLiquidity = false` blocks `provideLiquidity` only. `withdrawLiquidity` requires `msg.sender == s_rebalancer`, and `setRebalancer` is `onlyOwner` (no timelock, no cap, no in-flight-message guard). The pool owner can set the rebalancer to themselves and drain the reserve in a single multisig batch. Mid-flight BSC→ETH messages would commit on ETH (wON minted) but fail permanently on BSC release with `InsufficientLiquidity`. This is the documented CCT trust model and is correctly disclosed in CLAUDE.md/RUNBOOK — but no script-level or monitoring assertion exists on `s_rebalancer`.
- **Impact:** The custodial risk is accepted by design. The gap is that an accidental or malicious `setRebalancer` is not detected promptly.
- **Recommendation:** Add `_checkRebalancer(localPool)` to `script/08_PostDeployVerify.s.sol` asserting `LockReleaseTokenPool(pool).getRebalancer() == address(0)`. Add the same assertion to the RUNBOOK monitoring checklist as a recurring check.

### CCIP-2: Symmetric rate limits ignore directional asymmetry of the bridge
- **Severity:** MEDIUM
- **Status:** DOC ADDED — script 05 NatSpec now documents the intentional symmetry decision and prompts operators to override before mainnet broadcast if directional tightening is desired.
- **Location:** `script/05_ApplyChainUpdates.s.sol:69-75`
- **Description:** Both pools share `DEFAULT_CAPACITY = 100_000 ether` and `DEFAULT_RATE = 10 ether/sec` in both directions. The bridge is asymmetric (ETH has the hard `MAX_CCIP_MINTED = 100M` cap; BSC has no equivalent wON-side cap). Bucket-asymmetry between independent pool clocks means queued messages can arrive after a bucket has been redrained.
- **Impact:** No direct exploit. Possible DoS / unexpected user-facing reverts during burst+queue scenarios.
- **Recommendation:** Document the intentional symmetric default in script comments, and decide explicitly before mainnet whether ETH-inbound should be tighter to preserve `MAX_CCIP_MINTED` headroom for honest flow.

### CCIP-3: Bucket capacity/rate ratio is high — single tx can saturate for ~2.8h
- **Severity:** LOW
- **Status:** DOC ADDED — script 05 NatSpec now spells out the ~2.8h-from-zero refill window so operators decide consciously before mainnet rather than inheriting it implicitly.
- **Location:** `script/05_ApplyChainUpdates.s.sol:20-21`, `src/WrappedON.sol:147-152`
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
- **Status:** FALSE POSITIVE — re-reading `script/05_ApplyChainUpdates.s.sol:47-50`, the comment block immediately above the `bytes32` cast already states: "`abi.encode(address)` produces exactly 32 bytes (left-padded), and the pool's `getRemotePool` returns the same shape. Compare directly as bytes32 rather than hashing both sides — same intent, cheaper, and clearer about the assumed shape." The encoding assumption is documented and the assertion `wiredRemote.length == 32 && bytes32(wiredRemote) == bytes32(uint256(uint160(remotePool)))` already explicitly checks the length, so a non-32-byte encoding would fail the `require`, not silently pass it.
- **Location:** `script/05_ApplyChainUpdates.s.sol:51-53`
- **Description:** `wiredRemote` is cast to `bytes32` and compared. Correct for `abi.encode(address)` (32-byte left-padded). `TokenPool.setRemotePool` takes raw `bytes` with no encoding requirement, so a directly-set non-32-byte encoding bypasses the check. Real CCIP messages would still revert at validation time, so this is a diagnostic-only issue.
- **Impact:** Silent skip of stale-detection under non-standard manual wiring.
- **Recommendation:** Add a code comment documenting the encoding assumption; assert `wiredRemote.length == 32` explicitly.

### CCIP-7: `MAX_CCIP_MINTED` cap is not a lifetime bound — bridge cycling can refill headroom
- **Severity:** MEDIUM
- **Status:** DOC ADDED — `WrappedON.sol` NatSpec now contains a dedicated CAP REPLENISHMENT paragraph spelling out the cycling-refills-headroom behaviour, the preserved safety invariant, and the operational consequence (monitor `ccipMintedSupply` relative to current BSC locked balance, not relative to `MAX_CCIP_MINTED`). The monotone-counter alternative is left as a redeploy option if a true lifetime CCIP-mint bound becomes a requirement.
- **Location:** `src/WrappedON.sol:234-237` (saturating decrement)
- **Description:** wON is fungible. A user can `deposit` native ETH-side ON (deposit-backed wON, `ccipMintedSupply` untouched), then bridge that wON to BSC (`burn` saturating-decrements `ccipMintedSupply` toward zero). After cycling, the 100M cap is fully replenished, even though no CCIP-minted supply was burned. In the extreme: 100M deposit → 100M bridge-out → counter resets to 0 → another 100M CCIP-mint available. The safety invariant `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` still holds, but the cap's intent (bounding damage from a compromised pool) is weakened: compromised-pool damage is bounded by *current* `ccipMintedSupply` headroom, which may exceed 100M cumulatively over time.
- **Impact:** The cap is an approximation, not a hard CCIP-mint lifetime ceiling. The contract NatSpec already states this; the SECURITY-relevant point is that monitoring should not assume cap-fraction-used equals risk-fraction-used.
- **Recommendation:** Document the cycling scenario explicitly in `WrappedON.sol` NatSpec. If a true lifetime CCIP-mint bound is desired, use a monotone non-decrementing counter (with a parallel cap higher than 100M to permit honest cycling).

### CCIP-8: RMN curse halts both directions — no runbook response
- **Severity:** LOW
- **Status:** FALSE POSITIVE — `RUNBOOK.md §4.2 "Responding to an RMN curse"` already documents the operator-side response: confirm the curse via the CCIP Explorer, coordinate with Chainlink ops, transfers resume automatically once uncursed. The finding was missed by the reviewer's scan.
- **Location:** `lib/ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol:162,180`
- **Description:** A curse on the BSC selector blocks both `lockOrBurn` and `releaseOrMint`. Users cannot exit in either direction. RUNBOOK has no documented response procedure.
- **Impact:** During an RMN curse, all bridging stops. Funds are not at risk; user UX is.
- **Recommendation:** Add a "RMN Curse Response" section to RUNBOOK: detection (monitor `CursedByRMN` reverts or query `IRMN.isCursed`), authority (Chainlink), user communication.

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
- **Status:** FIXED — added `ccipBurnFrom` (approves pool, then `burnFrom`) and `ccipBurnAddress` (pool calls `burn(address,uint256)`) as handler actions; both included in `targetSelector`. Every burn overload's `_decrementCcipMinted` branch is now fuzzer-reachable.
- **Location:** `test/WrappedONInvariant.t.sol:113-132,152-166`
- **Description:** Both invariant burn actions call the single-argument overload. The other two overloads each independently call `_decrementCcipMinted`. Multi-step sequences involving them (including allowance interactions) are invisible to the property-based engine.
- **Impact:** Path-specific saturating-decrement bugs in `burnFrom` or `burn(address,uint256)` would be missed.
- **Recommendation:** Add `ccipBurnFrom` and `ccipBurnAddress` handler actions and include them in `targetSelector`.

### TEST-7: `test_Fork_BSC_TokenOwnershipModel` is too loose
- **Severity:** LOW
- **Status:** DEFERRED — the test's looseness reflects the open `Known open item` in CLAUDE.md ("BSC ON token CCIP-admin hook"). Tightening the assertion to verify the resolved admin equals the deployer requires first concluding which path the live BSC token exposes (RUNBOOK §0.2). Once that is settled the test can pin the chosen path.
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

---

## Operational, build, docs (`OPS-*`)

### OPS-1: Mainnet deployment via README leaks private key on `ps aux`
- **Severity:** HIGH
- **Status:** FIXED — README §4 now carries a "Mainnet key handling" callout pointing at the `cast wallet import` + `--account deployer` flow already documented in RUNBOOK §0.3. The Makefile retains the `--private-key` default for the testnet case (less risk, lower setup friction) but the README is now explicit that mainnet operators must switch.
- **Location:** `Makefile:6`, `README.md` (§4, §8)
- **Description:** `DEPLOY_FLAGS` hardcodes `--private-key $(DEPLOYER_PK)`, putting the raw key in process arguments visible to any process on the host and recorded in shell history. RUNBOOK §0.3 recommends `cast wallet import` + `--account deployer` — README does not mention it.
- **Impact:** An operator following README alone on mainnet exposes their key for the duration of the broadcast window.
- **Recommendation:** Add a security callout in README §4/§8 referencing the `cast wallet import deployer --interactive` + `--account deployer` flow. Provide a `DEPLOY_FLAGS_ACCOUNT` override in the Makefile so operators can switch without editing it.

### OPS-2: `make update-limits` post-handoff will revert — operator pays gas for nothing
- **Severity:** HIGH
- **Status:** FIXED — `make update-limits` now accepts `CALLER_FLAGS` (e.g. `CALLER_FLAGS='--account ratelimit-admin'`) for post-handoff callers. Falls back to `DEPLOYER_PK` when unset (pre-handoff path). The Makefile guard refuses to run when neither is provided.
- **Location:** `Makefile:144-151`, `README.md:173-178`, `RUNBOOK.md §4.1`
- **Description:** `update-limits` expands `DEPLOY_FLAGS` (hardcoded `--private-key $(DEPLOYER_PK)`). After handoff, the deployer is neither pool owner nor rate-limit admin; the call reverts `onlyOwner`. The Makefile guard only checks that `DEPLOYER_PK` is *set*.
- **Impact:** Operator broadcasts a revert-bound tx after handoff. The Makefile has no path for the multisig or a delegated `rateLimitAdmin` to make the call.
- **Recommendation:** Introduce a `CALLER_PK` (defaulting to `DEPLOYER_PK`) and/or an `--account` override path. Document explicitly in RUNBOOK §4.1 and the Makefile that post-handoff the caller must be the multisig or a delegated `rateLimitAdmin`.

### OPS-3: Submodules not pinned by branch in `.gitmodules`
- **Severity:** MEDIUM
- **Status:** FIXED — `.gitmodules` now carries an explicit header comment warning against `git submodule update --remote` and documenting the safe path (`git -C lib/<name> checkout <hash>`).
- **Location:** `.gitmodules`
- **Description:** `lib/ccip` and `lib/chainlink-local` are at tagged commits; `lib/forge-std` and `lib/openzeppelin-contracts` are at interim commits. No `branch =` lock in any entry. `git submodule update --remote` (a common but wrong invocation) would advance all to upstream tip.
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

---

# Closing note

This review intentionally excludes vendor library audit findings — Chainlink CCIP
1.5.x and OpenZeppelin 5.x are independently audited and pinned. Re-review is
recommended after any submodule bump, after any change to `src/WrappedON.sol`,
or before mainnet broadcast. The HIGH-severity findings should be closed prior
to mainnet rollout; MEDIUM findings should be triaged and either closed or
explicitly accepted with documented rationale.
