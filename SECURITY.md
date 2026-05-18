# SECURITY.md — Orochi Network ON Bridge

Findings from a five-agent security review of the Chainlink CCIP CCT bridge for the
Orochi Network ON token (Ethereum Mainnet ⇄ BNB Smart Chain), with the disposition of
each finding tracked inline.

**Scope:** `src/WrappedON.sol`, `script/01–08`, `script/Helper.sol`, `script/Deployments.sol`,
`test/**`, plus integration with vendored Chainlink CCIP contracts in `lib/ccip/`.

**Reviewed against:** `lib/ccip @ v2.17.0-ccip1.5.16` (production CCIP 1.5.x ABI).

## Status summary (PR #19, post-review pass)

| Severity | Total | Fixed in code | Accepted (documented) | Operational (documented) |
|---|---:|---:|---:|---:|
| Critical | 3 | 2 (C-2, C-3) | 1 (C-1) | 0 |
| High     | 6 | 4 (H-1, H-3, H-5, H-6) | 0 | 2 (H-2 §3.1, H-4 §0.2) |
| Medium   | 9 | 8 (M-1, M-2, M-3, M-4, M-5, M-6, M-7, M-9) | 1 (M-8 calibration) | 0 |
| Low/Nit  | 6 | 6 (incl. `supportsInterface` now `view` per R-58) | 0 | 0 |
| **Original total** | **24** | **20** | **2** | **2** |

PR #19 reviewer follow-ups span R-1 through R-58. All findings either fixed in code,
accepted with documented rationale, or addressed via operational guidance in
`RUNBOOK.md`. Per-round breakdown:

- **Round 1** (R-1..R-13): mostly code fixes for the initial brng1151 + bao-ninh review
  passes; everything except R-8 (PR description correction) and R-13 (a Make/doc grab-bag
  with several "accepted" sub-items) landed in code.
- **Round 2** (R-14..R-20): brng1151 round 2; semantic re-framing of the CCIP-mint cap
  (R-14, R-15) plus a multisig-equals-deployer handoff guard (R-16) and four script /
  doc consistency fixes (R-17..R-20).
- **R-21** (Chainlink CCIP compliance audit): rewrote script 07's rate-limit preflight to
  exactly mirror the protocol's `_validateTokenBucketConfig`; supersedes M-4.
- **Round 3 brng1151** (R-22..R-30): script 04 dispatch + structured-revert coverage,
  WrappedONInvariant adversarial-burn handler, CCIP-validator wrapper, ledger
  consistency fixes.
- **Round 3 bao-ninh** (R-31..R-41): C-3 / README catch-up to the R-14 reframing,
  script 08 rate-limit-misconfigured detector, RenounceDeployerAdmin pool/registry
  guards, scripts 01/02 idempotency probes, RUNBOOK keystore note, several nits.
- **Round 4 brng1151** (R-42..R-48): test coverage for the R-34 pre-renounce guards
  (helper extraction + 7-branch test suite), TransferOwnership idempotency probes,
  Script08 verifier tests, `tryReadAddress` consistency, headline + math fixes,
  Script04 `run()` limitation documented.
- **Round 5 brng1151 + bao-ninh** (R-49..R-55): TransferOwnership pendingOwner() bug
  fix, R-21 backfill, Script06Renounce/Script08Verify run() limitation extended from
  R-48, `tryReadAddress` switch in TransferOwnership, headline rewrite, test-count
  doc fixes.
- **Round 6 multi-agent review** (R-56..R-58): `setCCIPAdmin` guards against self-
  proposal and `address(this)` (new `InvalidCCIPAdmin` error), `withdraw(0)` matches
  `deposit(0)`'s `ZeroAmount` guard, `supportsInterface` mutability narrowed back to
  `view` to keep the inheritance chain extensible.

Non-fork tests: **102 total** (98 unit/integration + 4 stateful invariants).

CI status (`feat/ccip-bridge`): Build & test ✓. Slither runs as a non-blocking advisory job
(`continue-on-error: true`) — its findings are surfaced for triage but do not gate merge.
Re-enable as a hard gate after resolving the current finding set.

Each entry below: file:line — issue — impact — fix — **Status**.

---

## Critical (mainnet-blocking)

### C-1. `acceptLiquidity = false` does NOT disable `withdrawLiquidity` on the BSC pool
- **Where:** `lib/ccip/contracts/src/v0.8/ccip/pools/LockReleaseTokenPool.sol:97-115`;
  documentation comment in `script/02_DeployPools.s.sol`; CLAUDE.md.
- **Issue:** `i_acceptLiquidity` only gates `provideLiquidity`. `withdrawLiquidity` and
  `transferLiquidity` require only `msg.sender == s_rebalancer`, and `setRebalancer` is
  `onlyOwner`. An earlier project comment claimed `withdrawLiquidity` was "permanently
  disabled" — that was **wrong**.
- **Impact:** After ownership handoff, the BSC multisig can call
  `setRebalancer(multisig); withdrawLiquidity(100M)` and drain every locked ON token,
  leaving all CCIP-minted wON on Ethereum unbackable.
- **Status: ACCEPTED (Chainlink CCT trust model).** This is the documented Chainlink
  pattern for `LockReleaseTokenPool` — the operator multisig is intended to manage
  reserve liquidity via the rebalancer. Subclassing to neuter `setRebalancer` /
  `withdrawLiquidity` / `transferLiquidity` was considered and rejected as a deviation
  from the audited Chainlink template.
- **Mitigations applied:**
  - Comment in `script/02_DeployPools.s.sol` rewritten to honestly describe the trust
    model (no more "footgun removed" claim).
  - CLAUDE.md "Trust model: BSC reserve custody" section calls this out explicitly.
  - RUNBOOK.md monitoring step: alert on every BSC-pool `LiquidityRemoved`,
    `LiquidityAdded`, `OwnerUpdate`, and any call to `setRebalancer`.

### C-2. `Deployments.writeAddress` silently destroyed prior JSON entries
**Status: FIXED.** `script/Deployments.sol:25-29` rebuilt the serialization object from scratch on each forge process, so each `vm.writeJson` call overwrote the file and erased previous keys. Switched to the 3-arg `vm.writeJson(value, file, "$.key")` overload that patches a single JSON path; the file is initialized to `{}` on first write so the path target exists.

### C-3. No supply cap on the CCIP-mint path
**Status: FIXED (superseded by R-1 + R-14).** `src/WrappedON.sol` had two unbounded mint paths and did not encode the safety invariant `lockedON_BSC + reserveON_ETH ≥ totalSupply(wON)`. A `MAX_CCIP_MINTED = 100_000_000 ether` cap is now enforced on the CCIP-mint path via `ccipMintedSupply` (incremented in `mint`, saturating-decremented in every burn entrypoint); `mint` reverts `CCIPMintCapExceeded(cap, wouldBe)`. `deposit` is intentionally uncapped — bounded naturally by ETH-side ON supply — so heavy wrap usage cannot starve inbound CCIP messages. Under the re-framed semantics (R-14) the counter approximates BSC's locked-ON balance, and the cap bounds the damage of a compromised pool minting without a matching BSC lock; the safety invariant is preserved by mechanics (CCIP mint↔BSC lock pairing + deposit↔reserve lockstep), not a totalSupply cap.

---

## High

### H-1. `RenounceDeployerAdmin` didn't verify the multisig holds `DEFAULT_ADMIN_ROLE`
**Status: FIXED.** `script/06_TransferOwnership.s.sol` (`RenounceDeployerAdmin`) now requires before `renounceRole`: `MULTISIG` env set and non-zero, deployer still holds `adminRole`, multisig holds `adminRole`, and `won.getCCIPAdmin() == multisig`. Plus a post-renounce assertion that the role was actually revoked.

### H-2. Deployer retains mint authority during the handoff window
- **Where:** `script/06_TransferOwnership.s.sol`.
- **Status: FIXED (operational — RUNBOOK §3.1).** The two-step grant → multisig accept →
  deployer renounce window is intrinsic to OpenZeppelin AccessControl + two-step Ownable
  and cannot be made atomic without forking those primitives. Mitigations now fully
  documented:
  - RUNBOOK §3.1 prescribes the explicit "minimize the handoff window" procedure:
    multisig signers staged before `make handoff-all`, 3.2 accepts queued immediately
    after, `make renounce` run as soon as 3.2 + 3.3 confirm (hours, not days).
  - RUNBOOK §3.1 + "Trust model" monitoring table mandate paging on
    `RoleGranted(MINTER_ROLE, *)` / `RoleGranted(BURNER_ROLE, *)` whose grantee is not
    the pool, throughout the grant→renounce window.
  - `script/08_PostDeployVerify.s.sol` `_checkDeployerRenounced` flags the case where
    handoff is incomplete (M-3 fix), so `make verify-eth` detects a stalled handoff.

### H-3. Missing `_requireSet` guards on critical infrastructure addresses
**Status: FIXED.** Added guards across scripts 02 (`cfg.router`, `cfg.rmnProxy`, ETH-side `wrappedON`), 04 (`cfg.registryModuleOwnerCustom`, `cfg.tokenAdminRegistry`, `token`, `pool`), 05 (`localPool`, `remotePool`, `remoteToken`), and 07 (`localPool`). Stale Helper configurations now fail fast with a clear `MissingAddress(<what>)` revert.

### H-4. Cross-chain front-running of `proposeAdministrator` on BSC ON token
- **Where:** `script/04_RegisterAdminAndPool.s.sol`.
- **Status: FIXED (code + operational — RUNBOOK §0.2).**
  - **Fixed in code:** post-registration assertion in script 04 that
    `TokenAdminRegistry.getPool(token) == ourPool` immediately after `setPool`. If a
    front-runner registered a hostile pool first, `setPool` will revert (caller is not
    the registered admin) and our assertion catches any partial state. Script 04 also
    emits `[path N]` log lines (R-41) so the actual registration branch is recorded.
  - **Operational (now documented):** RUNBOOK §0.2 mandates fork-based path validation
    before mainnet broadcast — operators spin up an `anvil --fork-url $BSC_RPC` node,
    re-run `make deploy-bsc` against it, and observe which `[path N]` matches. The MEV
    window on `proposeAdministrator` is closed if the path resolves to a permissionless
    on-chain branch (1, 2, or 3); a path-4 fallthrough means recovery must be coordinated
    with the ON token owner / Chainlink *before* mainnet, never reactively.

### H-5. `make handoff` is single-chain — no enforcement that BOTH chains were handed off
**Status: FIXED.** New `make handoff-all ETH_RPC=… BSC_RPC=… MULTISIG=…` target runs the handoff sequentially against both chains with the same MULTISIG. Single-chain `make handoff` retained for ops convenience but the runbook now references the multi-chain target. Renounce remains single-chain (wON only exists on ETH).

### H-6. `_checkOwnershipHandoff` ignored `pendingOwner()`
**Status: FIXED.** `script/08_PostDeployVerify.s.sol` now distinguishes three states: `owner == multisig` is `[ok]`, `pendingOwner == multisig` reverts `PoolOwnershipPending` (acceptance needed), neither reverts `PoolOwnershipNotHandedOff`.

---

## Medium

### M-1. Script 04 missed the third registration path (`registerAccessControlDefaultAdmin`)
**Status: FIXED.** Script 04 now probes a third branch (`AccessControl.hasRole(0x00, broadcaster)`) before the manual-fallback revert. The vendored `RegistryModuleOwnerCustom` is at v1.5.0 in our submodule but the live registry on ETH + BSC mainnet is at v1.6.0 and exposes this selector, so the call goes via a local `IRegistryModuleOwnerCustom16` interface.

### M-2. `burn(address, uint256)` bypasses allowance (intentional but undocumented)
**Status: FIXED (documentation).** `src/WrappedON.sol` NatSpec on `burn(address,uint256)` now explicitly states it bypasses allowance and is gated solely on `BURNER_ROLE`, which must be held exclusively by the audited `BurnMintTokenPool`. RUNBOOK.md monitoring step: alert on any `RoleGranted(BURNER_ROLE, *)` whose grantee is not the pool address.

### M-3. Script 08 didn't verify deployer renounced `DEFAULT_ADMIN_ROLE`
**Status: FIXED.** `_checkDeployerRenounced(won, multisig)` runs when `MULTISIG` env is set and asserts multisig holds `DEFAULT_ADMIN_ROLE`, caller (deployer) does NOT, and `getCCIPAdmin() == multisig`.

### M-4. Script 07 didn't validate rate-limit config pre-broadcast
**Status: FIXED (superseded by R-21).** `script/07_UpdateRateLimits.s.sol` now runs an off-chain preflight that mirrors CCIP `RateLimiter._validateTokenBucketConfig` exactly: enabled → `rate > 0` AND `rate < capacity` (strict); disabled → `capacity == 0` AND `rate == 0`. Typo'd env vars now fail loudly before `vm.startBroadcast` rather than mid-broadcast inside a Gnosis Safe batch. The original M-4 fix used a weaker `capacity > 0` + non-strict `rate <= capacity` rule that diverged from CCIP in both directions — see R-21 for the protocol-mirror rewrite.

### M-5. `Deployments.sol` used relative paths
**Status: FIXED.** `path(chainId)` now uses `string.concat(vm.projectRoot(), "/deployments/", …)`, working regardless of cwd; `foundry.toml` `fs_permissions` for `./deployments` resolves the absolute prefix automatically.

### M-6. Vendored CCIP library was not pinned via submodule
**Status: FIXED (in PR #19, pre-this-review).** `lib/ccip` is now a real git submodule pinned to `v2.17.0-ccip1.5.16`. The pragma patch (`0.8.24` → `^0.8.24`) is wired into `make patch-pragmas` and run automatically by CI between submodule checkout and `forge build`.

### M-7. wON `setCCIPAdmin` was single-step
**Status: FIXED.** `setCCIPAdmin` now proposes; `acceptCCIPAdmin` from the proposed address completes the transfer. `pendingCCIPAdmin()` view exposed for verification. Script 06 uses propose + asserts `pendingCCIPAdmin == multisig`; `RenounceDeployerAdmin` requires `getCCIPAdmin() == multisig` before the deployer can renounce.

### M-8. Rate-limit per-tx capacity equals bucket capacity — grief vector
- **Status: ACCEPTED (calibration).** Default 100k ON capacity / 10 ON/sec rate
  preserved as a launch baseline. Rebalance via `make update-limits` after observing
  real traffic. RUNBOOK.md adds an "alert on bucket exhaustion" step.

### M-9. Fee-on-transfer / reentrancy hardening on wON (defensive)
**Status: FIXED.** `WrappedON` now inherits OZ `ReentrancyGuard`; `deposit` and `withdraw` are `nonReentrant`. `deposit` uses received-amount accounting (`before = balanceOf(this)` → `safeTransferFrom` → mint `balanceOf(this) - before`) so any fee-on-transfer behaviour on a future ON variant is correctly absorbed.

---

## Low / Nit

**Status: FIXED (all).** `Makefile` `test-e2e` passed `--match-path` twice so only `DeploymentE2E.t.sol` ran — replaced with a single brace-glob pattern that matches both. `script/06_TransferOwnership.s.sol` and `script/08_PostDeployVerify.s.sol` each had a vacuous `vm.load(won, slot 0)` read — replaced with the H-1 / M-3 / H-6 semantic checks. `src/WrappedON.sol` `supportsInterface` was declared `pure` vs parent `view` — narrowed back to `view` per R-58. `src/WrappedON.sol` `deposit(0)` was a silent no-op — now reverts `ZeroAmount()` (and `withdraw(0)` likewise per R-57). CLAUDE.md pragma-patch one-liner re-runs after `forge install` — `make install` now chains `submodule update --init --recursive` + `patch-pragmas`, and CI applies the patch automatically.

---

## Test coverage gaps (priority order — open follow-ups)

1. ~~**Reserve invariant never directly asserted.**~~ **CLOSED.** `test/WrappedONInvariant.t.sol`
   exercises a stateful handler that drives random sequences of `deposit` / `withdraw` /
   CCIP `mint` / CCIP `burn` / `adversarialPoolBurn` against a real `WrappedON`, with a
   simulated BSC pool balance, and continuously asserts the audit safety invariant
   `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` plus three companion invariants:
   `ccipMintedSupply <= bscLocked` (bound, not equality — round-3 review [2]),
   `ccipMintedSupply <= MAX_CCIP_MINTED`, and `reserveON <= cumulative deposits`. The
   `adversarialPoolBurn` selector simulates a buggy/compromised pool that burns wON
   without a matching BSC release — this walks the saturating-decrement branch in
   `_decrementCcipMinted` (otherwise unreachable when the handler keeps
   `bscLocked == ccipMintedSupply` in lockstep) and demonstrates that the safety
   invariant is preserved by the contract's mechanics, not by the handler's bookkeeping.
   4 invariants × 256 runs × 500 calls each (= 128k calls per invariant) all pass with
   zero reverts.
2. ~~**No test for `renounceRole` before multisig accepts.**~~ **CLOSED.**
   `test_E2E_RenounceBeforeMultisigAcceptIsBlocked` in `test/DeploymentE2E.t.sol`
   reproduces the `RenounceDeployerAdmin` script's precondition check (`getCCIPAdmin
   == multisig`) off-script and asserts it fails when the multisig has been granted
   the AccessControl role but has NOT accepted the two-step CCIP admin handoff —
   the exact orphaning scenario H-1 was designed to prevent. The test then completes
   the accept step and shows the renounce works once preconditions are met.
3. ~~**No rate-limit bucket-exhaustion test.**~~ **CLOSED.** Three new tests in
   `test/PoolRoundtrip.t.sol`:
   `test_RateLimitBucketExhaustionReverts` (single over-cap transfer hits
   `TokenMaxCapacityExceeded`); `test_RateLimitBucketRefillsOverTime` (drains the
   bucket, asserts immediate re-lock fails, advances `block.timestamp` and asserts
   refilled transfer succeeds); `test_RateLimitDisabledAllowsLargeTransfer` (sanity
   check on `isEnabled = false`).
4. ~~**No negative test for script 04's "neither admin path" revert.**~~ **CLOSED.**
   `test/Script04Paths.t.sol` covers four failure-mode dispatches:
   `test_RegisterAdmin_NeitherPathReverts` (bare ERC20 → `CannotResolveCCIPAdmin`);
   `test_RegisterAdmin_GetCCIPAdminMismatchFallsThrough` (path 1 condition fails,
   falls through to revert); `test_RegisterAdmin_AccessControlPath_FallsThroughAgainstV15Module`
   (path 3 reached, v1.6 selector unavailable on the vendored v1.5 module, inner
   try/catch fallthrough fires path-4 revert with a clear diagnostic).
   Side effect: the path-3 invocation is now wrapped in its own try/catch in
   `script/04_RegisterAdminAndPool.s.sol` so an unexpectedly-v1.5 registry produces
   a clear `CannotResolveCCIPAdmin` instead of a bare empty revert.
5. ~~**BSC pool ownership handoff has zero unit coverage.**~~ **CLOSED.**
   `test_E2E_BSCOwnershipHandoff` in `test/DeploymentE2E.t.sol` exercises the BSC side:
   pool `Ownable` two-step transfer, registry `transferAdminRole` two-step, mid-state
   assertions (owner unchanged until accept), and the C-1 trust-model verification that
   after handoff `setRebalancer` is owner-only for the new (multisig) owner — exactly
   the path the BSC custody-handoff RUNBOOK monitoring is designed around.
6. ~~**No fuzz tests anywhere.**~~ **CLOSED.** Three property fuzz tests in
   `test/WrappedON.t.sol` (in addition to the stateful invariants from gap [1]):
   `testFuzz_DepositWithdrawRoundtrip` (deposit→withdraw round-trip preserves every
   balance exactly); `testFuzz_CcipMintCapBoundary` (mint exactly to the cap succeeds,
   one wei over reverts — locks the cap arithmetic against off-by-one regressions);
   `testFuzz_CcipMintBurnRoundtripReusesCap` (mint→burn→mint sequence frees cap
   headroom). 256 runs each.
7. ~~**Fork tests don't assert non-zero `rate` / `capacity`.**~~ **CLOSED.**
   `test_Fork_ETH_PoolWiring` and `test_Fork_BSC_PoolWiring` now read the full
   `RateLimiter.TokenBucket` for both inbound and outbound limiters and assert
   `capacity > 0` and `rate > 0` in addition to `isEnabled`. An `isEnabled = true`
   limiter with zero rate would silently brick all transfers (the bucket never
   refills) — this catches that misconfiguration at fork-test time.
8. ~~**Script 04's `registerAdminViaOwner` and the new `registerAccessControlDefaultAdmin`
   paths** are not simulated; only the `getCCIPAdmin` branch is.~~ **CLOSED.**
   - `registerAdminViaOwner`: covered by
     `test_RegistryAccepts_RegisterAdminViaOwner` (success — broadcaster owns the token)
     and `test_RegistryRejects_RegisterAdminViaOwner_NotOwner` (failure mode).
   - `registerAccessControlDefaultAdmin`: the vendored module is v1.5 and lacks this
     selector; the production registry on ETH/BSC mainnet is v1.6. A
     `MockRegistryModuleV16` test fixture replicates the v1.6 call shape; success and
     reject paths covered by
     `test_RegistryAccepts_RegisterAccessControlDefaultAdmin` and
     `test_RegistryRejects_RegisterAccessControlDefaultAdmin_NotAdmin`.
   - The script's full dispatch — including the v1.5-fallthrough — is covered by the
     gap [4] tests above.

**Tests added in this audit pass:** `test_DepositZeroAmountReverts`,
`test_SetCCIPAdminTwoStep`, `test_SetCCIPAdminEmitsProposedThenTransferred`,
`test_AcceptCCIPAdminRevertsForNonPending`, `test_MintRevertsAtSupplyCap`,
`test_DepositRevertsAtSupplyCap`. Total non-fork suite: 41 tests (was 38).

---

## Verified correct against the deployed CCIP 1.5.x ABI

- `BurnMintTokenPool` 4-arg ctor `(token, allowlist, rmnProxy, router)` and
  `LockReleaseTokenPool` 5-arg ctor `(token, allowlist, rmnProxy, acceptLiquidity,
  router)` — match the deployed contracts.
- `TokenPool.ChainUpdate` is a 6-field struct including `allowed: bool` and singular
  `remotePoolAddress: bytes` (not the `bytes[] remotePoolAddresses` of unreleased 1.6+).
- `applyChainUpdates(ChainUpdate[])` is 1-arg (not the 2-arg `(removed, added)` of 1.6+).
- `getRemotePool(uint64) returns (bytes)` — singular (not the plural `getRemotePools`
  of 1.6+).
- Chain selectors: ETH Mainnet `5_009_297_550_715_157_269`, BSC Mainnet
  `11_344_663_589_394_136_015` — match the canonical Chainlink CCIP directory.
- wON correctly implements the runtime `IBurnMintERC20` interface; selectors match
  what `BurnMintTokenPool._burn` and `releaseOrMint` invoke.
- Decimals (18/18) consistent across chains. 1.5.x pools do not store
  `localTokenDecimals`; ABI-compatible with our 18-decimal token on both sides.
- `SafeERC20` used throughout for ON interactions.
- Donation of ON to the wON contract is benign — only the reserve grows; extra ON
  cannot be extracted without burning wON.

---

## Pre-mainnet action checklist

- [x] Resolve C-1: documented the Chainlink CCT trust model; BSC pool ownership = ON
      custody. Monitoring required (RUNBOOK.md).
- [x] C-2: `Deployments.writeAddress` JSON corruption.
- [x] C-3: global supply cap (100M) on wON.
- [x] H-1: multisig role pre-check before deployer renounces.
- [x] H-3: `_requireSet` calls across scripts 02 / 04 / 05 / 07.
- [x] H-4: post-registration assertion in script 04 + RUNBOOK §0.2 mandates fork-based
      path validation before mainnet broadcast.
- [x] H-5: `make handoff-all` Makefile target.
- [x] H-6: `pendingOwner()` probe in script 08.
- [x] M-1: third registration path in script 04.
- [x] M-3: post-renounce check in script 08.
- [x] M-4: rate-limit preflight in script 07.
- [x] M-5: absolute paths in `Deployments.sol`.
- [x] M-6: `lib/ccip` pinned as a git submodule (already shipped in PR #19).
- [x] M-7: 2-step `setCCIPAdmin`.
- [x] M-9: `nonReentrant` + received-amount accounting on wON.
- [x] All 8 test-coverage gaps closed (see "Test coverage gaps" section above for the
      per-gap test list; 98 non-fork tests pass + 4 stateful invariants × 128k calls each).
- [ ] Operator action: deploy to Sepolia ⇄ BSC Testnet first (RUNBOOK §1), then mainnet
      (RUNBOOK §2).
- [ ] Operator action: fill in `script/Helper.sol` placeholder addresses from
      https://docs.chain.link/ccip/directory before broadcasting on mainnet (RUNBOOK §0.1;
      gated by `make precheck-helper` per R-12).
- [ ] Operator action: confirm the canonical BSC ON token's CCIP-admin path on a BSC
      fork before mainnet rollout (RUNBOOK §0.2; `anvil --fork-url $BSC_RPC` + observe
      `[path N]` log from script 04).

(The three items above are tracking checkboxes for pre-broadcast operator work — the
documentation that drives them is complete; they get ticked when an operator executes
each step.)

---

## PR #19 review follow-ups

A second pass of automated review on PR #19 raised the items below. Reviewer IDs in
parentheses link to the originating PR comment.

### R-1. CCIP mint cap collided with deposit path (bao-ninh round-1 [1])
**Status: FIXED.** `src/WrappedON.sol` had a single `MAX_SUPPLY = 100M` cap shared between `deposit()` (deposit-backed) and `mint()` (CCIP-backed), so heavy wrap usage could exhaust the cap and make every inbound CCIP message permanently revert at `releaseOrMint`. Renamed to `MAX_CCIP_MINTED` and tracked via `ccipMintedSupply` (incremented in `mint`, saturating-decremented in all three burn entrypoints); `deposit()` is uncapped, bounded naturally by ETH-side ON supply. Six new tests cover the cap, burn-decrement, and saturation paths. Round-2 follow-up R-14 re-documents the counter as a BSC-pool-balance approximation (the original "circulating-CCIP ceiling" framing was impossible on a fungible token); safety property preserved by mechanics.

### R-2. WrappedON constructor lost two audit-derived guards (brng1151 #1/#5, bao-ninh #5)
**Status: FIXED.** `src/WrappedON.sol` constructor lost the LayerZero-era guards rejecting `_onToken == address(this)` (`SelfReserve`) and `decimals() != 18` (`DecimalsMismatch`), leaving CREATE2-miscalculation and wrong-decimals testnet flows unprotected. Both reverts restored; new tests `test_ConstructorRevertsOnSelfReserve` and `test_ConstructorRevertsOnDecimalsMismatch`.

### R-3. Script 04 fallback message pointed at a gated registry call (brng1151 #2)
**Status: FIXED.** `script/04_RegisterAdminAndPool.s.sol` told operators to call `TokenAdminRegistry.proposeAdministrator` in the `CannotResolveCCIPAdmin` diagnostic, but that selector is gated to registered registry modules and Chainlink. Revert message rewritten to recommend `RegistryModuleOwnerCustom.registerAdminViaOwner` (permissionless for the token's `Ownable.owner`) or coordination with Chainlink to register the admin out-of-band.

### R-4. Script 05 logged `local.chainSelector` instead of `remote.chainSelector` (brng1151 #3)
**Status: FIXED.** `script/05_ApplyChainUpdates.s.sol` log now correctly reports the remote selector. The on-chain wiring was already correct; only the operator-facing log line was wrong.

### R-5. Two contradictory SECURITY.md trackers (brng1151 #3)
**Status: FIXED.** Stale `docs/SECURITY.md` deleted; root `SECURITY.md` is the single authoritative ledger.

### R-6. `Deployments.writeAddress` produced invalid JSON (bao-ninh #2)
**Status: FIXED.** `script/Deployments.sol:38` passed `vm.toString(address)` (bare hex, no quotes) directly to `vm.writeJson`, producing unparseable JSON. Address is now wrapped with `"…"` before write; new `test/Deployments.t.sol` round-trips through `readAddress` and asserts `parseJsonAddress` succeeds on the produced file.

### R-7. Script 05 was not idempotent (bao-ninh #3)
**Status: FIXED.** `script/05_ApplyChainUpdates.s.sol`'s `applyChainUpdates` call reverted with `ChainAlreadyExists` on re-run, so partial-broadcast retries hard-failed. Script now probes `pool.isSupportedChain(remoteSelector)` first and logs + returns cleanly when the wiring already exists.

### R-8. PR description outdated re: `lib/ccip` branch (bao-ninh #4)
- **Status: ACCEPTED (PR description correction only).** `lib/ccip` is correctly pinned
  to the released `v2.17.0-ccip1.5.16` tag in `.gitmodules`, `foundry.lock`, and
  `CLAUDE.md`. The PR description's outdated `ccip-develop` claim has been corrected.

### R-9. `Makefile patch-pragmas` GNU-sed only (bao-ninh #6)
**Status: FIXED.** `sed -i 's/…/…/'` failed on macOS BSD sed. Switched to `sed -i.bak` (accepted by both) and deleted `*.sol.bak` immediately after.

### R-10. `make handoff-all` overstated as atomic (bao-ninh #7)
**Status: FIXED.** Wording in SECURITY.md H-5, RUNBOOK.md, and CLAUDE.md softened to "sequential — re-run on partial failure". The second leg has no rollback if the first succeeds; operators must re-run on partial failure, which is safe because handoff steps are idempotent.

### R-11. `MultisigEnvMissing` revert was unreachable (bao-ninh #9)
**Status: FIXED.** `script/06_TransferOwnership.s.sol`'s `vm.envAddress("MULTISIG")` itself reverted when the env was unset, so the follow-up `MultisigEnvMissing` check only fired for an explicit `MULTISIG=0x0…0`. Switched to `vm.envOr("MULTISIG", address(0))` so the manual check catches the unset case with a clear error.

### R-12. Helper placeholders weren't gated by tooling (bao-ninh #12)
**Status: FIXED.** New `script/PrecheckHelper.s.sol` asserts mainnet (chainId 1, 56) configs are non-zero. Wired into `make deploy-eth` / `make deploy-bsc` as a hard prerequisite — operators cannot broadcast against placeholder Helper config.

### R-13. Doc/Make hygiene (brng1151 #6 (info), bao-ninh #10/#11/#13/#14)
**Status: FIXED.** `script/07_UpdateRateLimits.s.sol` NatSpec now spells out that `OUTBOUND_ENABLED` / `INBOUND_ENABLED` accept ONLY the literal strings `true`/`false`. Test count harmonised across CLAUDE.md / README.md / RUNBOOK.md to the single source of truth (`forge test --no-match-path 'test/fork/**'`). `renounce-all` Make alias removed (misleading — wON only exists on ETH). Local-machine plan path removed from CLAUDE.md and RUNBOOK.md. `burn(address,uint256)` allowance bypass (brng1151 round-1 [6]) is accepted per M-2; operator-monitoring on `RoleGranted(BURNER_ROLE,*)` is the documented mitigation.

---

## PR #19 round-2 review follow-ups (brng1151)

A second review pass on commit `4b94dbe` raised 8 additional items. Numbered to match the
reviewer's order.

### R-14. Cap semantics re-documented (round-2 [1])
**Status: FIXED (semantics + docs).** R-1's disposition described `ccipMintedSupply` as "running ceiling on net CCIP-minted wON in circulation", which is impossible on a fungible token — saturating-decrement on burn can drain the counter from a deposit-backed bridge-out. Re-framed in `src/WrappedON.sol` contract NatSpec + `ccipMintedSupply` NatSpec: the counter approximates the BSC pool's expected locked-ON balance (every CCIP `mint` here paired with a `lock` there; every CCIP `burn` here paired with a `release` there), and equals `lockedON_BSC` under honest CCIP operation. The 100M cap is a defense-in-depth bound against a compromised pool minting without a matching BSC lock. The safety invariant `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` is preserved by mechanics (CCIP mint↔lock pairing + deposit↔reserve lockstep), not by the counter. Implementation unchanged.

### R-15. `withdraw` does not decrement `ccipMintedSupply` (round-2 [2])
- **Where:** `src/WrappedON.sol:withdraw`.
- **Status: ACCEPTED (intentional).** `withdraw` does not trigger a BSC release — it only
  moves ETH-side reserve. Decrementing the counter would desync it from BSC pool balance.
  The cost (a CCIP-minted holder can consume the deposit reserve) is intended per C-1's
  arbitrage-layer design. Inline comment added.

### R-16. `MULTISIG == deployer` guard in handoff (round-2 [3])
**Status: FIXED.** Setting `MULTISIG=$DEPLOYER` silently targeted the deployer EOA on every handoff call, and `RenounceDeployerAdmin`'s "multisig has role" check was satisfied vacuously, permanently orphaning the contract on renounce. Both `TransferOwnership.run()` and `RenounceDeployerAdmin.run()` in `script/06_TransferOwnership.s.sol` now revert with `MultisigEqualsDeployer(addr)` when `multisig == msg.sender`.

### R-17. PrecheckHelper covers remote chain + onToken consistency (round-2 [4])
**Status: FIXED.** `script/PrecheckHelper.s.sol` only checked the local chain's Helper config (so `deploy-eth` would miss BSC placeholders until script 05's BSC-side wiring step) and exempted onToken on testnet asymmetrically with script 05. Precheck now walks both `block.chainid` and `_remoteChainId(block.chainid)` (pure `getConfig`, no cross-chain RPC). The onToken check applies on BSC mainnet AND BSC testnet (97); ETH-side reads `wrappedON` from Deployments JSON so `Helper.onToken` can remain zero on chainId 1 / 11_155_111.

### R-18. Script 05 re-run signals (round-2 [5][6])
**Status: FIXED.** `script/05_ApplyChainUpdates.s.sol` re-runs after editing `DEFAULT_CAPACITY` / `DEFAULT_RATE` silently skipped, and the idempotency probe missed stale remote-pool wiring. Skip-log now explicitly directs operators to `make update-limits` for rate-limit changes; the idempotent path reads `getRemotePool(remoteSelector)` and reverts with a clear "stale remote pool wiring" message if it differs from the deployments JSON (operator must `applyChainUpdates(removed)` and re-run).

### R-19. Corrupt deployment JSON is undocumented (round-2 [7])
- **Where:** `script/Deployments.sol`.
- **Status: ACCEPTED (documented).** A killed prior broadcast can leave a corrupt JSON
  file. The helper only seeds when the file is missing; a corrupt file makes the next
  `vm.parseJsonAddress` fail with a clear-enough error. Recovery: delete the file and
  re-run. Inline NatSpec now documents this.

### R-20. Opaque `decimals()` revert (round-2 [8])
**Status: REVERTED (over-engineering for a test-mock symptom).** R-20 originally wrapped the ctor's `IERC20Metadata(onToken).decimals()` call in try/catch and added a `DecimalsUnreadable` error. The original symptom was a low-level ABI-decode revert from a bare-`IERC20` *test* mock; canonical ON on both chains is a fully-conformant `IERC20Metadata` so the catch branch was unreachable in production. The try/catch + extra error + `NoDecimalsToken` mock + `test_ConstructorRevertsOnUnreadableDecimals` were all removed; the ctor now calls `decimals()` directly and only retains the `DecimalsMismatch` guard against a wrong-decimals testnet wiring.

### R-21. Script 07 preflight diverged from CCIP `_validateTokenBucketConfig` (Chainlink compliance audit)
**Status: FIXED (supersedes M-4).** The original M-4 preflight in `script/07_UpdateRateLimits.s.sol` used `capacity > 0` always, non-strict `rate <= capacity`, did not reject `rate == 0`, and had no disabled-case handling — so configs the preflight accepted could fail `_validateTokenBucketConfig` mid-broadcast, AND the valid disabled-direction `(capacity=0, rate=0)` config was incorrectly blocked. Rewrote `_validateBucket` to mirror CCIP's rule exactly: enabled → `rate > 0` AND `rate < capacity` (strict); disabled → both zero. New `test/Script07Preflight.t.sol` covers each branch (12 tests including a fuzz that asserts preflight ↔ CCIP equivalence on every input — R-30 lifted this fuzz from a hand-mirror to a real cross-check against `RateLimiter._validateTokenBucketConfig`).

---

## PR #19 round-3 review follow-ups (brng1151)

A third review pass on commit `8e14688` raised 9 additional items, all of which are
addressed below (R-22 through R-30).

### R-22. PrecheckHelper required `onToken` on BSC testnet placeholder (round-3 [1])
**Status: FIXED.** Round-2 R-17 broadened the `onToken` precheck to BSC testnet (97), but `Helper.sol` intentionally encodes `onToken: address(0)` there ("deploy a mock for testing"), so every Sepolia / BSC-testnet deploy reverted with `PlaceholderField(97, "onToken")` before any work happened. `script/PrecheckHelper.s.sol` now requires `onToken` on BSC mainnet (56) only; the testnet flow expects operators to deploy a mock and patch Helper manually before broadcast, surfacing as a clear `MissingAddress` revert in script 05 if they forget.

### R-23. Stateful invariant fuzz did not walk the cap-bypass path (round-3 [2])
**Status: FIXED.** `test/WrappedONInvariant.t.sol`'s handler kept `bscLocked == ccipMintedSupply` in lockstep, making `invariant_CounterTracksBscLocked` tautological and the saturating branch in `_decrementCcipMinted` unreachable. New `adversarialPoolBurn(...)` handler selector simulates a buggy/compromised pool that burns wON without a matching BSC release. The saturating-decrement branch is now fuzzer-reachable; `invariant_CounterTracksBscLocked` weakened to `invariant_CounterBoundedByBscLocked` (`ccipMintedSupply <= bscLocked`), which holds under both honest and adversarial-burn paths.

### R-24. `MultisigEqualsDeployer` guard had no unit coverage (round-3 [3])
**Status: FIXED.** Round-2 R-16 added the `MultisigEqualsDeployer` guard in both `TransferOwnership.run()` and `RenounceDeployerAdmin.run()`, but no test exercised the new revert. New `test/Script06Guards.t.sol` directly invokes both scripts with `MULTISIG=$DEPLOYER` set via `vm.setEnv` and asserts the `MultisigEqualsDeployer(addr)` selector fires.

### R-25. Script 04 dispatch had no unit coverage of success paths (round-3 [4])
**Status: FIXED.** The `_RegistryAccepts_*` tests called the registry module directly, locking call shapes but never exercising script 04's `_registerAdmin` dispatch. New `MockRecordingModule` records which registration selector the script chose; three new tests (`test_Dispatch_Path1_GetCCIPAdmin_…`, `_Path2_Ownable_…`, `_Path3_AccessControl_…`) exercise the harness's `exposeRegisterAdmin` against the recording mock and assert the correct module function was invoked with the right token argument. Earlier module-direct tests retained as msg.sender-check coverage.

### R-26. CLAUDE.md still referenced dead `MAX_SUPPLY` / `SupplyCapExceeded` symbols (round-3 [5])
**Status: FIXED.** R-1 renamed `MAX_SUPPLY` → `MAX_CCIP_MINTED` and `SupplyCapExceeded` → `CCIPMintCapExceeded`, and the cap now applies to `mint()` only. `CLAUDE.md` lines 9–11 and 47–49 rewritten to describe the current `MAX_CCIP_MINTED` / `ccipMintedSupply` mint cap, the uncapped `deposit` path, and cross-reference R-1 + R-14.

### R-27. Script 06 NatSpec referenced a nonexistent `renounceDeployerAdmin()` function (round-3 [6])
**Status: FIXED.** Docstring in `script/06_TransferOwnership.s.sol` said "use the `renounceDeployerAdmin()` entry point below" but the artifact is a separate `RenounceDeployerAdmin` contract with a `run()` entry. NatSpec updated to point at the `RenounceDeployerAdmin` contract's `run()` entry.

### R-28. Script 04 inner `catch` swallowed structured v1.6 reverts (round-3 [7])
**Status: FIXED.** The bare `catch { … }` wrapping the v1.6 call in `script/04_RegisterAdminAndPool.s.sol` fell through on ANY revert, swallowing legitimate v1.6 failures (token already registered, registry paused, etc.) and showing the misleading `CannotResolveCCIPAdmin` diagnostic. Replaced with `catch (bytes memory reason) { if (reason.length != 0) { assembly { revert(add(reason, 0x20), mload(reason)) } } }` so empty reverts (selector absent on v1.5) fall through to the path-4 diagnostic, but every structured revert propagates unmodified. New unit test `test_Dispatch_Path3_StructuredRevertPropagates` locks this against `MockRevertingModuleV16`.

### R-29. SECURITY.md M-4 contradicted R-21 within the same file (round-3 [8])
**Status: FIXED.** R-21 rewrote the preflight to mirror CCIP's strict rule, but M-4's "FIXED" description still claimed the script "now requires `capacity > 0` and `rate <= capacity`" — both weak forms R-21 explicitly removed. M-4 reframed as "FIXED (superseded by R-21)" with the strict CCIP-mirroring rule described and the original weak rule called out as the bug R-21 fixed.

### R-30. `testFuzz_PreflightAgreesWithCcip` was a hand-mirror, not a true cross-check (round-3 [9])
**Status: FIXED.** The fuzz in `test/Script07Preflight.t.sol` re-implemented the protocol's rule inline, so a misread of the rule would have been baked into both the preflight AND the "oracle" simultaneously. New `CcipRateLimiterValidator` is a thin external wrapper around `RateLimiter._validateTokenBucketConfig` (callable because it's an `internal pure` library function). The fuzz now runs against the real protocol code; three concrete spot-check tests pin the wrapper's behaviour so a future CCIP version bump shows up as test-suite divergence rather than silent drift. Assertion strengthened to bidirectional `assertEq(preflightAccepts, ccipAccepts, …)` — the disabled-direction zero-config case is now covered both directions.

---

## PR #19 round-3 review follow-ups (bao-ninh)

A third review pass on commit `908ab22` from bao-ninh-orochi raised 11 additional items
(3 doc/script gaps, 6 minors, 2 nits). All addressed below (R-31 through R-41).

### R-31. SECURITY.md C-3 still described the superseded MAX_SUPPLY fix (bao-ninh round-3 [1])
**Status: FIXED.** C-3's status paragraph kept the round-1 framing (`MAX_SUPPLY`, `_mintCapped` helper, both paths capped) even after R-1 + R-14 rescoped to `MAX_CCIP_MINTED` (CCIP-mint path only) with `CCIPMintCapExceeded`. R-26 updated CLAUDE.md but C-3 itself was untouched. C-3 reframed as "FIXED (superseded by R-1 + R-14)" with the current per-path cap semantics described inline.

### R-32. README.md still claimed wON totalSupply ≤ 100M (bao-ninh round-3 [2])
**Status: FIXED.** `README.md` L12 supply table and L234 security narrative claimed `≤ 100M` across both mint paths, but `totalSupply` can grow up to `MAX_CCIP_MINTED + (ETH-side ON deposited)`; only `ccipMintedSupply` is capped. Supply table now reads `CCIP-mint ≤ 100M; deposit-backed uncapped`; security TL;DR rewritten to explain the cap is on the CCIP-mint path, deposit is naturally bounded, and the safety invariant is preserved by mechanics.

### R-33. Script 08 _checkRateLimits only asserted isEnabled (bao-ninh round-3 [3])
**Status: FIXED.** `script/08_PostDeployVerify.s.sol` checked only `isEnabled`, so an `isEnabled = true` bucket with `rate = 0` (silently brick) would pass `make verify-*` and only surface at the first user transaction. New `_assertEnabledAndConfigured` helper checks `isEnabled` AND `rate > 0` AND `capacity > 0`; new `RateLimitMisconfigured(direction, capacity, rate)` error distinguishes "disabled" from "enabled-but-bricked".

### R-34. RenounceDeployerAdmin didn't gate on pool/registry handoff completion (bao-ninh round-3 [4])
**Status: FIXED.** Pre-renounce checks in `script/06_TransferOwnership.s.sol` (`RenounceDeployerAdmin`) confirmed the wON role handoff but didn't catch pending pool `acceptOwnership` or registry `acceptAdminRole`, leaving the bridge half-handed-off. Two new `require`s added: `pool.owner() == multisig` and `registry.getTokenConfig(token).administrator == multisig` (low-level staticcall to avoid importing the registry struct ABI; administrator at offset 0 of `TokenConfig`). Clear diagnostic messages on failure.

### R-35. Script 04 path-3 empty-revert heuristic NatSpec (bao-ninh round-3 [5])
**Status: FIXED (in-code comment).** The `if (reason.length != 0)` heuristic in `script/04_RegisterAdminAndPool.s.sol` correctly propagates structured reverts but matches a plain `revert();` (empty-reason explicit revert) under the same case as missing-selector. The deployed v1.6 module doesn't do that, but a future version that did would silently fall through. Comment rewritten as "selector-absent ↔ empty revert" rather than "any zero-length return"; behaviour unchanged.

### R-36. Scripts 01 + 02 weren't idempotent — RUNBOOK overstated (bao-ninh round-3 [6])
**Status: FIXED.** Re-running script 01 or 02 deployed a new artifact and overwrote `deployments/<chainId>.json`, breaking downstream scripts. Both now probe `Deployments.tryReadAddress` before deploying and log + skip if the artifact is already recorded; new `Deployments.tryReadAddress` returns `address(0)` when the file is missing OR the key is absent (via `vm.keyExistsJson`). RUNBOOK preamble rewritten to describe per-script idempotency accurately, including the "delete the JSON entry to force redeploy" recovery path.

### R-37. RUNBOOK didn't mention keystore as the preferred deployer-key option (bao-ninh round-3 [7])
**Status: FIXED.** Makefile passes `--private-key $(DEPLOYER_PK)` on the command line, surfacing the key in `ps aux` and shell history during the broadcast window. RUNBOOK §0.3 now has a "Key-handling note" paragraph explaining the Foundry keystore option (`cast wallet import deployer --interactive`, then `--account deployer`) and cross-references H-2.

### R-38. Dead `DRYRUN_FLAGS` Makefile variable (bao-ninh round-3 [8])
**Status: FIXED.** Removed.

### R-39. `wrapBackedSupply` NatSpec read as if tracked state (bao-ninh round-3 [9])
**Status: FIXED.** `wrapBackedSupply` is a conceptual term, not an on-chain storage variable, but `src/WrappedON.sol` NatSpec + ctor comment and `CLAUDE.md` "Reserve invariant" used phrasing as if it were tracked state. Both passages rewritten to make explicit that the invariant is preserved by mechanics (`withdraw` revert when reserve insufficient + received-amount accounting in `deposit`), and there is no storage variable of that name.

### R-40. Script 05 keccak256 compare nit (bao-ninh round-3 [10])
**Status: FIXED (nit).** Replaced `keccak256(wiredRemote) == keccak256(expectedRemote)` in `script/05_ApplyChainUpdates.s.sol` with `wiredRemote.length == 32 && bytes32(wiredRemote) == bytes32(uint256(uint160(remotePool)))`. Same intent; cheaper, and the assumed 32-byte shape is now explicit.

### R-41. Script 04 didn't log which discovery path it took (bao-ninh round-3 [11])
**Status: FIXED (nit).** Each of the three success branches in `script/04_RegisterAdminAndPool.s.sol` now emits a `[path N]` console line before returning, so post-deploy broadcast log forensics show which registration mechanism matched.

---

## PR #19 round-4 review follow-ups (brng1151)

A fourth review pass on commit `b213dd50` from brng1151 raised 7 additional items
(3 high-confidence test/code gaps, 4 lower-confidence). All addressed below
(R-42 through R-48).

### R-42. R-34 pre-renounce guards had no test coverage (round-4 [1])
**Status: FIXED.** R-34's mapping table claimed `test_E2E_OwnershipHandoff` covered the new pool + registry checks, but that test calls `won.renounceRole(adminRole, deployer)` directly via `vm.prank`, bypassing `RenounceDeployerAdmin.run()` entirely. Refactored the precondition logic out of `run()` into an internal `_assertReadyToRenounce(won, multisig, deployer, pool, registry)` with dependencies passed in. New `test/Script06Renounce.t.sol` exposes the helper via a harness and drives all 7 branches: happy path, deployer-lacks-role, multisig-lacks-role, ccipAdmin-not-accepted, pool-address-missing, pool-owner-not-multisig, registry-admin-not-multisig. External behaviour of `run()` unchanged.

### R-43. TransferOwnership had no idempotency probes (round-4 [2])
**Status: FIXED.** `TransferOwnership.run()` in `script/06_TransferOwnership.s.sol` unconditionally re-invoked every sub-step on re-run, reverting deep inside `pool.transferOwnership` or re-proposing the pending CCIP admin. Each sub-step (pool ownership, wON admin grant, wON ccipAdmin, registry admin transfer) now probes current state and skips with a clear log line if already at multisig OR pending to multisig. Re-runs continue cleanly with only the missing steps. New `ITokenAdminRegistryRead` interface added for the registry probe.

### R-44. Script 08 `_assertEnabledAndConfigured` had no test (round-4 [3])
**Status: FIXED.** R-33 added `RateLimitMisconfigured(direction, capacity, rate)` and the `isEnabled + rate>0 + capacity>0` check but no test exercised it. New `test/Script08Verify.t.sol` exposes the helper via `PostDeployVerifyHarness` and drives all four cases: enabled-and-configured (happy path), disabled (`RateLimitDisabled`), enabled-with-zero-rate (`RateLimitMisconfigured`), enabled-with-zero-capacity (`RateLimitMisconfigured`).

### R-45. `Deployments.readAddress` made the friendly pool-missing message dead (round-4 [4])
**Status: FIXED.** R-34 used `Deployments.readAddress(...)` for the pool lookup in `RenounceDeployerAdmin`, but `readAddress` reverts on a missing key with a low-level `vm.parseJsonAddress` error, so operators following R-36's "delete the JSON entry to force redeploy" recovery path never saw the friendly message. Switched to `Deployments.tryReadAddress(...)`, which returns `address(0)` on missing key OR missing file.

### R-46. SECURITY.md headline summary only mentioned R-1..R-13 (round-4 [5])
**Status: FIXED.** `SECURITY.md` headline `Status summary` block rewritten to reflect the full span, organised by review round with brief disposition notes.

### R-47. SECURITY.md test-count math contradicted itemization (round-4 [6])
**Status: FIXED.** Headline itemized `4+1+2+3 = 10` round-3 additions but footer reported `+9 added` — "1 structured-revert propagation test" was one of the 4 dispatch tests, not a separate fifth. Itemization corrected to "4 dispatch tests (including a structured-revert propagation test)"; total updated and round-4 additions itemized.

### R-48. Script 04 dispatch tests bypass `run()` (round-4 [7])
- **Where:** `test/Script04Paths.t.sol`.
- **Issue:** `test_Dispatch_Path*` tests call `harness.exposeRegisterAdmin(...)` (an
  external wrapper around the script's internal `_registerAdmin`). A regression
  stripping `vm.startBroadcast` / `vm.stopBroadcast` from `run()` would still let
  every dispatch test pass.
- **Status: ACCEPTED (documented limitation).** A run()-level test would require
  controlling `Helper.getConfig()` outputs (currently hardcoded to mainnet/testnet
  addresses), writing a `deployments/<chainId>.json` fixture for the pool entry,
  AND setting `block.chainid` to a Helper-recognised value with non-placeholder
  CCIP addresses. The closest existing path is the `DeploymentE2E._run04_registerAdminAndPool`
  reproduction, which also bypasses `run()`. The broadcast wrap is conventional
  Foundry script boilerplate; its absence would surface immediately on any real
  deploy attempt (no broadcast happens, no transactions sent). The dispatch tests
  provide regression protection for the per-path selector logic, which is the
  load-bearing piece.

---

## PR #19 round-5 review follow-ups

A fifth review pass on commit `9a412d2` raised 7 items (6 from brng1151, 1 from
bao-ninh). Item 1 was a real correctness bug introduced by R-43; the rest were
ledger/doc/test-rigor gaps. All addressed below (R-49 through R-55).

### R-49. R-43's `pendingOwner()` probe doesn't exist on CCIP TokenPool (round-5 brng1151 [1])
**Status: FIXED.** R-43's pool-ownership idempotency probe in `TransferOwnership._handoff` checked `pool.pendingOwner() == multisig`, but CCIP `TokenPool` inherits `OwnerIsCreator → ConfirmedOwner → ConfirmedOwnerWithProposal` where `s_pendingOwner` is `private` — the typed-interface call would revert with empty returndata on a real pool. Removed `pendingOwner()` from the `ITokenPoolOwnable` interface and dropped the `pendingOwner == multisig` branch. Probe now: if `pool.owner() == multisig`, skip; else re-broadcast `transferOwnership(multisig)`. Re-broadcasting from the deployer while the deployer is still owner is harmless (overwrites `s_pendingOwner` with the same value); post-accept, the `owner == multisig` branch skips cleanly.

### R-50. Missing R-21 entry referenced by M-4 / R-29 (round-5 brng1151 [2])
**Status: FIXED.** M-4's "FIXED (superseded by R-21)", R-29's text, and the trust-model section all referenced R-21 as load-bearing, but the ledger jumped directly from R-20 to R-22. Backfilled R-21 between the round-2 follow-ups and round-3 brng1151 follow-ups, attributed to the Chainlink CCIP compliance audit (the Chainlink-compliance section near the end of this document already described the fix in detail).

### R-51. R-42 / R-44 tests reintroduce R-48's `run()`-bypass pattern (round-5 brng1151 [3])
- **Where:** `test/Script06Renounce.t.sol`, `test/Script08Verify.t.sol`.
- **Issue:** All 7 `Script06Renounce` tests call `harness.exposeAssertReadyToRenounce(...)`
  and all 4 `Script08Verify` tests call `h.exposeAssert(...)`. A regression that deleted
  the helper call from `RenounceDeployerAdmin.run()`, swapped its argument order, or
  swapped the `"outbound"`/`"inbound"` direction strings in `PostDeployVerify._checkRateLimits`
  would pass every test. R-48 explicitly accepted this pattern for Script04 with
  documented reasoning; R-42 / R-44 should be held to the same standard.
- **Status: ACCEPTED (R-48 reasoning extends).** Both `RenounceDeployerAdmin.run()` and
  `PostDeployVerify.run()` read `Helper.getConfig(block.chainid)` whose addresses are
  hardcoded placeholders (`address(0)`) for testnet/mainnet alike — exactly the
  Helper-injection limitation documented under R-48. A run()-level test would require
  the same refactor (Helper inversion of control) the team scoped out of this PR.
  Mitigation: the harness exposers call the same internal function the script calls,
  with the same signature, so an argument-order or string-direction regression in the
  helper itself is caught by these tests. A regression that bypasses the helper
  entirely (deleting the call from `run()`) is what's uncovered — the same blind
  spot as R-48. Tracked here so future work can address all three scripts together
  under one Helper-injection refactor.

### R-52. R-43 + R-45 paired fix only mirrored half (round-5 brng1151 [4])
**Status: FIXED.** R-45 switched `RenounceDeployerAdmin`'s pool lookup to `Deployments.tryReadAddress`, but `_handoff` still used `Deployments.readAddress(...)` for both `pool` and `wrappedON`, so operators following R-36's "delete the JSON entry to force redeploy" path got a cryptic `vm.parseJsonAddress` revert when re-running `make handoff`. Both lookups in `_handoff` switched to `tryReadAddress` with explicit `require(addr != address(0), …)` messages naming the script the operator needs to re-run first.

### R-53. R-46 status overstated the headline rewrite (round-5 brng1151 [5])
**Status: FIXED.** R-46's status claimed per-round disposition notes for R-42..R-48 but the actual headline tacked R-42 onwards on as a single addendum line. Headline rewritten with one bullet per round (R-1..R-13, R-14..R-20, R-21, R-22..R-30, R-31..R-41, R-42..R-48, R-49..R-55, plus R-56..R-58 added later) and a brief disposition note for each. Test-count summary moved to the bottom of the same block.

### R-54. CLAUDE.md self-contradicting test counts (round-5 brng1151 [6])
**Status: FIXED.** `CLAUDE.md` L83 said "99 tests + 4 stateful invariants" while L99 still read "41 mock-based tests (no RPC needed)". L99 updated to the current count; both lines also align with R-55's clarification.

### R-55. "99 tests + 4 stateful invariants" double-counts the invariants (round-5 bao-ninh)
**Status: FIXED.** The 4 `invariant_*` functions in `test/WrappedONInvariant.t.sol` are PART of the count `forge test` reports, not 4 additional tests on top. All three operator-doc references (`CLAUDE.md`, `README.md`, `RUNBOOK.md`) rewritten to the explicit breakdown "N tests (M unit/integration + 4 stateful invariants)" so the sum is unambiguous. `SECURITY.md` already correct (uses "Plus" to qualify iteration depth, not test count).

### R-56. `setCCIPAdmin` can produce an unreachable or self-cancelling pending slot (round-6 multi-agent review [1])
**Status: FIXED.** `setCCIPAdmin` in `src/WrappedON.sol` only guarded `msg.sender == s_ccipAdmin` and `newAdmin == address(0)`, letting two unsafe targets through: `newAdmin == address(this)` (writes an unreachable address — `acceptCCIPAdmin` requires `msg.sender == s_pendingCcipAdmin`, soft-locking the role until the current admin overwrites with a reachable address) and `newAdmin == s_ccipAdmin` (silently clobbers any in-flight pending proposal, e.g. vanishing a multisig's mid-accept handoff). Operational footgun during script-06 ceremony; no funds risk. Added `error InvalidCCIPAdmin()` and a guard rejecting both cases. Negative tests `test_SetCCIPAdminRevertsOnSelfProposal` and `test_SetCCIPAdminRevertsOnContractSelf` plus positive `test_SetCCIPAdminMayReProposePending` confirming idempotent re-propose of the existing pending address remains allowed.

### R-57. `withdraw(0)` silently emits spurious events (round-6 multi-agent review [2])
**Status: FIXED.** `deposit(0)` reverted with `ZeroAmount` but `withdraw(0)` had no matching guard, so a zero-amount call emitted spurious `Transfer(_, 0x0, 0)`, `safeTransfer(_, 0)`, and `Unwrapped(_, 0)` events with no state change — polluting drain-monitoring indexers. Added `if (amount == 0) revert ZeroAmount();` at the top of `withdraw`, mirroring `deposit`. New `test_WithdrawRevertsOnZero` covers it. Invariant handlers short-circuit when `cap == 0` and bound amounts to `[1, cap]`, so the stateful fuzz suite is unaffected.

### R-58. `supportsInterface` declared `pure` instead of `view` (round-6 multi-agent review [3])
**Status: FIXED.** `src/WrappedON.sol:215` narrowed `AccessControl.supportsInterface` (declared `view`) to `pure`. Solidity allows the narrowing and the current body is state-independent, but `pure` silently blocks any future base override that reads storage — a latent inheritance hazard. Previous "no action needed" disposition reversed. Changed to `public view override(AccessControl)`; no behaviour change, existing `test_SupportsInterface` passes unchanged.

---

## Chainlink CCIP compliance audit

Cross-checked the repo against `lib/ccip @ v2.17.0-ccip1.5.16` (the pinned CCIP 1.5.x ABI)
and Chainlink CCT documentation. Pin context: `script/Helper.sol` and `CLAUDE.md` state
this is deliberate — match the production CCIP 1.5.x ABI on ETH + BSC mainnet. CCIP 1.6.x
introduces an immutable `localTokenDecimals` ctor arg + 2-arg `applyChainUpdates(removed,
added)`; the 1.5.x pool deploys via this repo are operationally supported alongside 1.6.x
through the registry's per-pool addressing.

### Verified compliant

- **`WrappedON` selectors**: `mint(address,uint256)`, `burn(uint256)`, `burn(address,uint256)`,
  `burnFrom(address,uint256)`, `totalSupply`, `balanceOf`, `transfer`, `allowance`, `approve`,
  `transferFrom` — match the runtime `IBurnMintERC20` interface that
  `BurnMintTokenPool._burn` / `BurnMintTokenPoolAbstract.releaseOrMint` invoke. (See contract
  NatSpec for why `IBurnMintERC20` is not formally inherited — OZ-v5-vs-vendored-v4.8.3
  `IERC20` linearization conflict.)
- **`getCCIPAdmin`**: returns `s_ccipAdmin` — matches `IGetCCIPAdmin` exactly.
  `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin` will resolve correctly.
- **Pool constructors**: `BurnMintTokenPool(token, allowlist=[], rmnProxy, router)` (4-arg)
  and `LockReleaseTokenPool(token, allowlist=[], rmnProxy, acceptLiquidity=false, router)`
  (5-arg) — match the vendored 1.5.x signatures exactly.
- **`TokenPool.ChainUpdate` struct**: 6 fields (selector, allowed, remotePoolAddress,
  remoteTokenAddress, outbound limiter, inbound limiter) — match the 1.5.x layout, not the
  7-field 1.6+ form.
- **`applyChainUpdates(ChainUpdate[])`**: 1-arg form (not the 2-arg
  `(removed[], added[])` of 1.6+).
- **`getRemotePool(uint64) returns (bytes)`**: singular (not the plural `getRemotePools`
  of 1.6+).
- **Chain selectors**: ETH Mainnet `5_009_297_550_715_157_269`, BSC Mainnet
  `11_344_663_589_394_136_015`, Sepolia `16_015_286_601_757_825_753`, BSC Testnet
  `13_264_668_187_771_770_619` — all match the Chainlink CCIP directory.
- **Allowlist**: passed as `address[](0)` — open-mode (any sender accepted via Router).
- **Roles**: `MINTER_ROLE` + `BURNER_ROLE` granted to `BurnMintTokenPool` on ETH; nothing
  granted on BSC (LockReleaseTokenPool only locks/releases). Order: grant BEFORE registry
  setPool (script 03 → script 04). Required by Chainlink CCT spec.
- **Two-step token-admin handoff**: `TokenAdminRegistry.transferAdminRole` + `acceptAdminRole`
  used end-to-end. Plus our own two-step `setCCIPAdmin` + `acceptCCIPAdmin` on wON.
- **`setPool` precondition**: `IPoolV1(pool).isSupportedToken(localToken)` is checked by the
  registry; the vendored `TokenPool.isSupportedToken` returns `token == i_token` which is
  exactly our wON. Verified.
- **`acceptLiquidity = false`** on BSC pool. Disables `provideLiquidity`. Does NOT disable
  `setRebalancer` / `withdrawLiquidity` — this is the Chainlink CCT trust model documented
  as C-1. Confirmed against `LockReleaseTokenPool.sol` source.
- **RMN curse plumbing**: `cfg.rmnProxy` wired into pool ctor; `_validateLockOrBurn` runs
  curse check before any token operation. Negative test: `test_LockOrBurnRevertsWhenRMNCursed`.
- **Decimals**: 18/18 across ETH + BSC. wON ctor rejects mismatched `decimals()` via
  `DecimalsMismatch`. CCIP 1.5.x pools do not store `localTokenDecimals` on-chain — operators
  register 18/18 OFF-CHAIN via the CCIP directory metadata (see RUNBOOK).
- **`_validateLockOrBurn` / `_validateReleaseOrMint`**: inherited from `TokenPool`, never
  overridden. Per-chain rate-limit consumption, RMN curse check, chain-supported check, and
  source-pool address verification all run unchanged.

### Compliance gaps found and fixed

- **`script/07_UpdateRateLimits.s.sol` preflight (`R-21`)**. The CCIP protocol's
  `RateLimiter._validateTokenBucketConfig` requires:
  - When `isEnabled = true`: `rate > 0` AND `rate < capacity` (strict).
  - When `isEnabled = false`: `capacity == 0` AND `rate == 0`.

  The earlier preflight used `rate <= capacity` (non-strict), unconditionally required
  `capacity > 0`, and didn't reject `rate == 0`. Result: a config the preflight accepted
  could fail `_validateTokenBucketConfig` mid-broadcast (the exact mid-broadcast-revert
  failure mode M-4 was meant to prevent), AND the valid disabled-direction
  `(capacity=0, rate=0)` config was incorrectly blocked. Fix: new `_validateBucket`
  helper that mirrors CCIP's rule exactly; new `test/Script07Preflight.t.sol` (12 tests)
  fuzzes script preflight ↔ `RateLimiter._validateTokenBucketConfig` equivalence directly
  against the protocol code via the `CcipRateLimiterValidator` external wrapper (round-3
  review [9] — earlier draft compared against a hand-mirror of the rule).

### Best-practice items (not fixed, operational decision)

- **Rate-limit admin role**: `TokenPool` exposes `setRateLimitAdmin(address)` so the owner
  can delegate `setChainRateLimiterConfig` to a separate hot-key EOA. Chainlink CCT best
  practice recommends this so the cold-storage multisig isn't needed for routine rate-limit
  tuning. Currently the bridge does not delegate — multisig holds full owner authority.
  Operators may want to add a `setRateLimitAdmin(<hot-key>)` step post-handoff; documented
  in RUNBOOK.

### Operational items (out of scope of this audit)

- BSC ON CCIP-admin path resolution on private fork (H-4) — pre-mainnet probe.
- `script/Helper.sol` mainnet address placeholders (gated by `make precheck-helper`).
- Off-chain Chainlink directory registration: 18/18 decimals, CCIP-supported chains.

---

## Test suite total

`forge test --no-match-path 'test/fork/**'` → **102 tests pass**. Round growth:
- 79 after Chainlink-compliance pass.
- +9 in round-3 brng1151 follow-ups: 4 Script04 dispatch tests (including a
  structured-revert propagation test), 2 Script06 multisig-guard tests, 3 CCIP-validator
  wrapper spot-checks. (Earlier note in this document itemized 4+1+2+3=10; that
  double-counted the structured-revert test under "dispatch" AND "structured-revert".)
- +11 in round-4 brng1151 follow-ups: 7 Script06 renounce-precondition tests
  (`test/Script06Renounce.t.sol`), 4 Script08 rate-limit verifier tests
  (`test/Script08Verify.t.sol`).
- −1 from removing `test_ConstructorRevertsOnUnreadableDecimals` together with the
  R-20 try/catch + `NoDecimalsToken` mock (unreachable in production — canonical ON
  is a conformant `IERC20Metadata` on both chains).
- +4 in round-6 multi-agent review (R-56..R-58): 3 negative/positive tests for
  `setCCIPAdmin` guards (`SelfProposal`, `ContractSelf`, `MayReProposePending`) and 1
  for `withdraw(0)` (`WithdrawRevertsOnZero`).

Plus 4 stateful invariants × 256 runs × 500 calls each in `test/WrappedONInvariant.t.sol`
(128k assertions per invariant), including an `adversarialPoolBurn` selector that walks
the saturating-decrement branch (round-3 review [2]). Fork tests (`test/fork/*`) compile
and run against ETH_RPC / BSC_RPC.
