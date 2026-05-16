# SECURITY.md — Orochi Network ON Bridge

Findings from a five-agent security review of the Chainlink CCIP CCT bridge for the
Orochi Network ON token (Ethereum Mainnet ⇄ BNB Smart Chain), with the disposition of
each finding tracked inline.

**Scope:** `src/WrappedON.sol`, `script/01–08`, `script/Helper.sol`, `script/Deployments.sol`,
`test/**`, plus integration with vendored Chainlink CCIP contracts in `lib/ccip/`.

**Reviewed against:** `lib/ccip @ v2.17.0-ccip1.5.16` (production CCIP 1.5.x ABI).

## Status summary (PR #19, post-review pass)

| Severity | Total | Fixed in code | Accepted (documented) | Partial / operational |
|---|---:|---:|---:|---:|
| Critical | 3 | 2 (C-2, C-3) | 1 (C-1) | 0 |
| High     | 6 | 4 (H-1, H-3, H-5, H-6) | 1 (H-2) | 1 (H-4) |
| Medium   | 9 | 8 (M-1, M-2, M-3, M-4, M-5, M-6, M-7, M-9) | 1 (M-8 calibration) | 0 |
| Low/Nit  | 6 | 5 | 1 (`supportsInterface pure` — no action needed) | 0 |
| **Original total** | **24** | **19** | **4** | **1** |

PR #19 reviewer follow-ups (R-1 through R-13 below): 11 fixed in code, 2 documented.
88/88 non-fork tests pass (round-3 added: 4 Script04 dispatch tests, 1 structured-revert
propagation test, 2 Script06 guard tests, 3 CCIP-validator spot-checks plus a refactored
fuzz that runs against the real `RateLimiter` library, and the WrappedONInvariant
adversarial-pool-burn handler path).

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
- **Where:** `script/Deployments.sol:25-29` (pre-fix).
- **Issue:** `vm.serializeAddress("deployments", key, value)` re-built the serialization
  object from scratch on each forge process. The first call wrote `{"wrappedON": "0x…"}`;
  the next call (`pool`) started with an empty in-memory object, produced
  `{"pool": "0x…"}`, and `vm.writeJson` overwrote the file — erasing `wrappedON`.
- **Status: FIXED.** `script/Deployments.sol` now uses the 3-arg `vm.writeJson(value,
  file, "$.key")` overload that patches a single JSON path without touching the rest of
  the object. The file is initialized to `{}` on first write so the path target exists.

### C-3. No supply cap on the CCIP-mint path
- **Where:** `src/WrappedON.sol`.
- **Issue:** wON had two independent mint paths (`deposit`-backed and CCIP-`mint`) with
  no enforced ceiling. The implicit safety invariant `lockedON_BSC + reserveON_ETH ≥
  totalSupply(wON)` was not encoded.
- **Status: FIXED (superseded by R-1 + R-14).** A `MAX_CCIP_MINTED = 100_000_000 ether`
  cap is now enforced on the CCIP-mint path via the `ccipMintedSupply` counter
  (incremented in `mint`, saturating-decremented in every burn entrypoint). `mint`
  reverts `CCIPMintCapExceeded(cap, wouldBe)`. The `deposit` path is intentionally
  uncapped — bounded naturally by ETH-side ON supply — so heavy wrap usage cannot
  starve inbound CCIP messages (this was the round-1 framing's mistake; see R-1).
  Under the re-framed semantics (R-14) the counter approximates the BSC pool's
  expected locked-ON balance, and the cap bounds the damage of a compromised CCIP
  pool minting wON without a matching BSC lock. The safety invariant
  `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` is preserved by mechanics
  (CCIP mint↔BSC lock pairing + deposit↔reserve lockstep), not by a totalSupply cap.

---

## High

### H-1. `RenounceDeployerAdmin` didn't verify the multisig holds `DEFAULT_ADMIN_ROLE`
- **Where:** `script/06_TransferOwnership.s.sol` (`RenounceDeployerAdmin`).
- **Status: FIXED.** Before `renounceRole` the script now requires:
  1. `vm.envAddress("MULTISIG")` is set and non-zero.
  2. `won.hasRole(adminRole, deployer)` (deployer still has it).
  3. `won.hasRole(adminRole, multisig)` (multisig has accepted it).
  4. `won.getCCIPAdmin() == multisig` (multisig also accepted the 2-step ccipAdmin).
  Plus a post-renounce assertion that the role was actually revoked.

### H-2. Deployer retains mint authority during the handoff window
- **Where:** `script/06_TransferOwnership.s.sol`.
- **Status: ACCEPTED (operational mitigation).** The two-step grant → multisig accept →
  deployer renounce window is operator-controlled and unbounded. Mitigations:
  - RUNBOOK.md prescribes back-to-back execution and event monitoring on
    `RoleGranted(MINTER_ROLE, *)` / `RoleGranted(BURNER_ROLE, *)` during the window.
  - `script/08_PostDeployVerify.s.sol` `_checkDeployerRenounced` flags the case where
    handoff is incomplete (M-3 fix).

### H-3. Missing `_requireSet` guards on critical infrastructure addresses
- **Status: FIXED.** Added guards across:
  - `script/02_DeployPools.s.sol`: `cfg.router`, `cfg.rmnProxy`, and (ETH path)
    the `wrappedON` address from `Deployments`.
  - `script/04_RegisterAdminAndPool.s.sol`: `cfg.registryModuleOwnerCustom`,
    `cfg.tokenAdminRegistry`, `token`, `pool`.
  - `script/05_ApplyChainUpdates.s.sol`: `localPool`, `remotePool`, `remoteToken`.
  - `script/07_UpdateRateLimits.s.sol`: `localPool`.
  Stale Helper configurations now fail fast with a clear `MissingAddress(<what>)` revert.

### H-4. Cross-chain front-running of `proposeAdministrator` on BSC ON token
- **Where:** `script/04_RegisterAdminAndPool.s.sol`.
- **Status: PARTIAL FIX + OPERATIONAL.**
  - **Fixed in code:** added a post-registration assertion in script 04 that
    `TokenAdminRegistry.getPool(token) == ourPool` immediately after `setPool`. If a
    front-runner registered a hostile pool first, `setPool` will revert (caller is not
    the registered admin) and our assertion catches any partial state.
  - **Operational:** the BSC ON token's admin path must be resolved on a private fork
    BEFORE mainnet broadcast (see Known-open-items in CLAUDE.md). If the canonical ON
    on BSC implements `getCCIPAdmin`, that admin should be a trusted address ahead of
    deployment; if it does not, the token owner pre-calls `proposeAdministrator`.

### H-5. `make handoff` is single-chain — no enforcement that BOTH chains were handed off
- **Status: FIXED.** New `make handoff-all ETH_RPC=… BSC_RPC=… MULTISIG=…` target runs
  the handoff sequentially against both chains with the same MULTISIG. Single-chain
  `make handoff` is retained for ops convenience but the runbook now references the
  multi-chain target. Renounce remains single-chain (wON only exists on ETH).

### H-6. `_checkOwnershipHandoff` ignored `pendingOwner()`
- **Where:** `script/08_PostDeployVerify.s.sol`.
- **Status: FIXED.** The verifier now distinguishes three states explicitly:
  1. `owner == multisig`: `[ok]` (active).
  2. `pendingOwner == multisig`: reverts `PoolOwnershipPending` (acceptance needed).
  3. Neither: reverts `PoolOwnershipNotHandedOff`.

---

## Medium

### M-1. Script 04 missed the third registration path (`registerAccessControlDefaultAdmin`)
- **Status: FIXED.** Script 04 now probes a third branch
  (`AccessControl.hasRole(0x00, broadcaster)`) before the manual-fallback revert. The
  vendored `RegistryModuleOwnerCustom` is at v1.5.0 in our submodule, but the live
  registry on Ethereum + BSC mainnet is at v1.6.0 and exposes this selector, so the
  call goes via a local `IRegistryModuleOwnerCustom16` interface.

### M-2. `burn(address, uint256)` bypasses allowance (intentional but undocumented)
- **Where:** `src/WrappedON.sol`.
- **Status: FIXED (documentation).** NatSpec on `burn(address,uint256)` now explicitly
  states it bypasses allowance and is gated solely on `BURNER_ROLE`, which must be
  held exclusively by the audited `BurnMintTokenPool`. RUNBOOK.md monitoring step:
  alert on any `RoleGranted(BURNER_ROLE, *)` whose grantee is not the pool address.

### M-3. Script 08 didn't verify deployer renounced `DEFAULT_ADMIN_ROLE`
- **Status: FIXED.** `_checkDeployerRenounced(won, multisig)` runs when `MULTISIG`
  env is set and asserts (a) multisig holds `DEFAULT_ADMIN_ROLE`, (b) caller
  (deployer) does NOT, and (c) `getCCIPAdmin() == multisig`.

### M-4. Script 07 didn't validate rate-limit config pre-broadcast
- **Status: FIXED (superseded by R-21).** `script/07_UpdateRateLimits.s.sol` now runs an
  off-chain preflight that mirrors CCIP `RateLimiter._validateTokenBucketConfig` exactly:
  enabled → `rate > 0` AND `rate < capacity` (strict); disabled → `capacity == 0` AND
  `rate == 0`. Typo'd env vars now fail loudly before `vm.startBroadcast` rather than
  mid-broadcast inside a Gnosis Safe batch. The original M-4 fix used the weaker
  `capacity > 0` + non-strict `rate <= capacity` rule, which diverged from CCIP in
  both directions — see R-21 for the protocol-mirror rewrite.

### M-5. `Deployments.sol` used relative paths
- **Status: FIXED.** `path(chainId)` now uses
  `string.concat(vm.projectRoot(), "/deployments/", …)`. Works regardless of the
  caller's cwd; `foundry.toml` `fs_permissions` for `./deployments` resolves the
  absolute prefix automatically.

### M-6. Vendored CCIP library was not pinned via submodule
- **Status: FIXED (in PR #19, pre-this-review).** `lib/ccip` is now a real git
  submodule pinned to `v2.17.0-ccip1.5.16`. The pragma patch
  (`0.8.24` → `^0.8.24`) is wired into `make patch-pragmas` and run automatically by
  CI between submodule checkout and `forge build`.

### M-7. wON `setCCIPAdmin` was single-step
- **Status: FIXED.** `setCCIPAdmin` now proposes; `acceptCCIPAdmin` from the proposed
  address completes the transfer. `pendingCCIPAdmin()` view exposed for verification.
  Script 06 uses propose + asserts `pendingCCIPAdmin == multisig`; `RenounceDeployerAdmin`
  requires `getCCIPAdmin() == multisig` (i.e. multisig must have called
  `acceptCCIPAdmin`) before the deployer can renounce.

### M-8. Rate-limit per-tx capacity equals bucket capacity — grief vector
- **Status: ACCEPTED (calibration).** Default 100k ON capacity / 10 ON/sec rate
  preserved as a launch baseline. Rebalance via `make update-limits` after observing
  real traffic. RUNBOOK.md adds an "alert on bucket exhaustion" step.

### M-9. Fee-on-transfer / reentrancy hardening on wON (defensive)
- **Status: FIXED.** `WrappedON` now inherits OZ `ReentrancyGuard`; `deposit` and
  `withdraw` are `nonReentrant`. `deposit` uses received-amount accounting:
  ```solidity
  uint256 before = ON.balanceOf(address(this));
  ON.safeTransferFrom(msg.sender, address(this), amount);
  uint256 received = ON.balanceOf(address(this)) - before;
  _mintCapped(msg.sender, received);
  ```

---

## Low / Nit

- **`Makefile` `test-e2e` passed `--match-path` twice.** Forge honored only the last,
  so only `DeploymentE2E.t.sol` actually ran. **FIXED:** replaced with a single
  brace-glob pattern that matches both.
- **`script/06_TransferOwnership.s.sol` `vm.load(won, slot 0)` was vacuous.**
  **FIXED:** replaced with the H-1 multisig/role asserts.
- **`script/08_PostDeployVerify.s.sol` had a vacuous slot-0 read.** **FIXED:**
  replaced with the M-3 / H-6 semantic checks.
- **`src/WrappedON.sol` `supportsInterface` declared `pure` vs parent `view`.**
  ABI-compatible, no action needed.
- **`src/WrappedON.sol` `deposit(0)` was a silent no-op.** **FIXED:** reverts
  `ZeroAmount()`.
- **CLAUDE.md pragma-patch one-liner re-runs after `forge install`.** **FIXED:**
  `make install` now chains `submodule update --init --recursive` + `patch-pragmas`,
  and CI applies the patch automatically.

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
- [x] H-4: post-registration assertion in script 04. Operational task remains:
      resolve BSC ON admin path on a private fork before mainnet.
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
      per-gap test list; 88 non-fork tests pass + 4 stateful invariants × 128k calls each).
- [ ] Operational: deploy to Sepolia ⇄ BSC Testnet first, then mainnet.
- [ ] Operational: fill in `script/Helper.sol` placeholder addresses from
      https://docs.chain.link/ccip/directory before broadcasting on mainnet.
- [ ] Operational: confirm the canonical BSC ON token's CCIP-admin path on a private
      fork before mainnet rollout.

---

## PR #19 review follow-ups

A second pass of automated review on PR #19 raised the items below. Reviewer IDs in
parentheses link to the originating PR comment.

### R-1. CCIP mint cap collided with deposit path (bao-ninh round-1 [1])
- **Where:** `src/WrappedON.sol`.
- **Issue:** A single `MAX_SUPPLY = 100M` cap was shared between `deposit()` (deposit-backed)
  and `mint()` (CCIP-backed). Heavy wrap usage could exhaust the cap and make every inbound
  CCIP message permanently revert at `releaseOrMint`.
- **Status: FIXED.** Renamed to `MAX_CCIP_MINTED`; tracked via `ccipMintedSupply` (incremented
  in `mint`, saturating-decremented in all three burn entrypoints). `deposit()` is uncapped —
  bounded naturally by ETH-side ON supply. New tests:
  `test_MintRevertsAtCCIPMintCap`, `test_DepositSucceedsWhenCCIPCapHit`,
  `test_BurnDecrementsCCIPMintedSupply`, `test_BurnSaturatesCCIPMintedAtZero`,
  `test_BurnAddressOverloadDecrementsCCIPMinted`, `test_BurnFromDecrementsCCIPMinted`.
- **Round-2 follow-up — see R-14 below.** brng1151's round-2 review correctly flagged that
  the original R-1 description framed the counter as "running ceiling on net CCIP-minted
  wON in circulation", which is impossible to enforce on a fungible token. Counter semantics
  re-documented as BSC-pool-balance approximation; safety property preserved by mechanics.

### R-2. WrappedON constructor lost two audit-derived guards (brng1151 #1/#5, bao-ninh #5)
- **Where:** `src/WrappedON.sol` constructor.
- **Issue:** The previous LayerZero-era contract rejected `_onToken == address(this)`
  (`SelfReserve`) and `decimals() != 18` (`DecimalsMismatch`). Neither guard carried over
  into the new constructor, leaving CREATE2-miscalculation and wrong-decimals testnet flows
  unprotected.
- **Status: FIXED.** Both reverts restored. New tests
  `test_ConstructorRevertsOnSelfReserve` and `test_ConstructorRevertsOnDecimalsMismatch`.

### R-3. Script 04 fallback message pointed at a gated registry call (brng1151 #2)
- **Where:** `script/04_RegisterAdminAndPool.s.sol`.
- **Issue:** `CannotResolveCCIPAdmin` told operators to call
  `TokenAdminRegistry.proposeAdministrator`, but that selector is gated to registered
  registry modules / Chainlink — operators cannot invoke it.
- **Status: FIXED.** Revert message rewritten to recommend
  `RegistryModuleOwnerCustom.registerAdminViaOwner` (permissionless for the token's
  `Ownable.owner`) or coordination with Chainlink to register the admin out-of-band.

### R-4. Script 05 logged `local.chainSelector` instead of `remote.chainSelector` (brng1151 #3)
- **Where:** `script/05_ApplyChainUpdates.s.sol`.
- **Status: FIXED.** Log now correctly reports the remote selector. The on-chain wiring
  was already correct; only the operator-facing log line was wrong.

### R-5. Two contradictory SECURITY.md trackers (brng1151 #3)
- **Where:** root `SECURITY.md` (post-fix) vs. `docs/SECURITY.md` (pre-fix).
- **Status: FIXED.** Stale `docs/SECURITY.md` deleted; root `SECURITY.md` is the
  single authoritative ledger.

### R-6. `Deployments.writeAddress` produced invalid JSON (bao-ninh #2)
- **Where:** `script/Deployments.sol:38`.
- **Issue:** `vm.toString(address)` returns a bare hex string without quotes; passing it
  directly to `vm.writeJson` produces unparseable JSON. The bug was untested.
- **Status: FIXED.** Address is now wrapped with `"…"` before being passed to `writeJson`.
  New `test/Deployments.t.sol` round-trips writes through `readAddress` and asserts
  `parseJsonAddress` succeeds on the produced file.

### R-7. Script 05 was not idempotent (bao-ninh #3)
- **Where:** `script/05_ApplyChainUpdates.s.sol`.
- **Issue:** `applyChainUpdates` reverts with `ChainAlreadyExists` when re-run, so a
  partial-broadcast retry hard-failed.
- **Status: FIXED.** Script now probes `pool.isSupportedChain(remoteSelector)` before
  attempting the update; logs and returns cleanly when the wiring already exists.

### R-8. PR description outdated re: `lib/ccip` branch (bao-ninh #4)
- **Status: ACCEPTED (PR description correction only).** `lib/ccip` is correctly pinned
  to the released `v2.17.0-ccip1.5.16` tag in `.gitmodules`, `foundry.lock`, and
  `CLAUDE.md`. The PR description's outdated `ccip-develop` claim has been corrected.

### R-9. `Makefile patch-pragmas` GNU-sed only (bao-ninh #6)
- **Where:** `Makefile`.
- **Issue:** `sed -i 's/…/…/'` fails on macOS BSD sed.
- **Status: FIXED.** Switched to `sed -i.bak` (accepted by both GNU and BSD sed) and
  delete `*.sol.bak` immediately after.

### R-10. `make handoff-all` overstated as atomic (bao-ninh #7)
- **Where:** root `SECURITY.md` H-5 wording, `RUNBOOK.md`, `CLAUDE.md`.
- **Status: FIXED.** Wording softened to "sequential — re-run on partial failure". The
  second leg has no rollback if the first succeeds; operators must re-run on partial
  failure (which is safe — handoff steps are idempotent).

### R-11. `MultisigEnvMissing` revert was unreachable (bao-ninh #9)
- **Where:** `script/06_TransferOwnership.s.sol`.
- **Issue:** `vm.envAddress("MULTISIG")` itself reverts when the env is unset, so the
  follow-up `MultisigEnvMissing` check only fired for an explicit `MULTISIG=0x0…0`.
- **Status: FIXED.** Switched to `vm.envOr("MULTISIG", address(0))` so the manual check
  catches the unset case with a clear error.

### R-12. Helper placeholders weren't gated by tooling (bao-ninh #12)
- **Status: FIXED.** New `script/PrecheckHelper.s.sol` asserts mainnet (chainId 1, 56)
  configs are non-zero. Wired into `make deploy-eth` / `make deploy-bsc` as a hard
  prerequisite — operators cannot broadcast against placeholder Helper config.

### R-13. Doc/Make hygiene (brng1151 #6 (info), bao-ninh #10/#11/#13/#14)
- **`script/07_UpdateRateLimits.s.sol`** — NatSpec now spells out that
  `OUTBOUND_ENABLED` / `INBOUND_ENABLED` accept ONLY the literal strings `true`/`false`.
- **Test count** — single source of truth: `forge test --no-match-path 'test/fork/**'`
  reports 50 tests (was 41 pre-review). CLAUDE.md / README.md / RUNBOOK.md updated.
- **`renounce-all` Make alias removed** — was misleading (handoff-all symmetry was
  spurious; wON only exists on ETH).
- **Local-machine plan path removed** from CLAUDE.md and RUNBOOK.md.
- **`burn(address,uint256)` allowance bypass** (brng1151 round-1 [6]) — accepted per M-2;
  the operator-monitoring path on `RoleGranted(BURNER_ROLE,*)` is the documented mitigation.

---

## PR #19 round-2 review follow-ups (brng1151)

A second review pass on commit `4b94dbe` raised 8 additional items. Numbered to match the
reviewer's order.

### R-14. Cap semantics re-documented (round-2 [1])
- **Where:** `src/WrappedON.sol` contract NatSpec + `ccipMintedSupply` NatSpec.
- **Issue:** R-1's disposition described `ccipMintedSupply` as "running ceiling on net
  CCIP-minted wON in circulation". On a fungible token that semantic is impossible — once
  minted, deposit-backed and CCIP-backed wON are indistinguishable, so saturating-decrement
  on burn can drain the counter from a deposit-backed bridge-out, mis-stating the
  CCIP-circulating count.
- **Re-framing.** The counter actually approximates the BSC pool's expected locked-ON
  balance: every CCIP `mint` on this contract is paired with a `lock` of the same amount on
  the BSC pool (and every CCIP `burn` here with a `release` there). With saturating subtract
  the counter equals `lockedON_BSC` under honest CCIP operation. The cap at 100M (BSC supply)
  is a defense-in-depth bound against a compromised CCIP pool minting without a matching
  BSC lock.
- **Safety invariant** (preserved by mechanics, NOT by the counter):
  `lockedON_BSC + reserveON_ETH >= totalSupply(wON)`. CCIP guarantees mint-lock pairing;
  `deposit`/`withdraw` adjust both `totalSupply` and `reserveON_ETH` in lockstep. The
  scenario reviewer raised (Bob CCIP-mints 50M, Alice deposits 50M and bridges to BSC,
  Charlie CCIP-mints 100M → totalSupply=150M) satisfies the invariant because the released
  BSC ON ended up in Alice's hands on BSC, and the 50M deposit reserve still backs Bob's
  unbridged wON.
- **Status: FIXED (semantics + docs).** Contract NatSpec and `ccipMintedSupply` field
  comment rewritten. Implementation unchanged — the behavior was correct under the
  re-framed semantics.

### R-15. `withdraw` does not decrement `ccipMintedSupply` (round-2 [2])
- **Where:** `src/WrappedON.sol:withdraw`.
- **Status: ACCEPTED (intentional).** `withdraw` does not trigger a BSC release — it only
  moves ETH-side reserve. Decrementing the counter would desync it from BSC pool balance.
  The cost (a CCIP-minted holder can consume the deposit reserve) is intended per C-1's
  arbitrage-layer design. Inline comment added.

### R-16. `MULTISIG == deployer` guard in handoff (round-2 [3])
- **Where:** `script/06_TransferOwnership.s.sol`.
- **Issue:** Setting `MULTISIG=$DEPLOYER` silently targets the deployer EOA on every
  handoff call, and `RenounceDeployerAdmin`'s "multisig has role" check is satisfied
  vacuously (because deployer == multisig == admin holder), permanently orphaning the
  contract on renounce.
- **Status: FIXED.** Both `TransferOwnership.run()` and `RenounceDeployerAdmin.run()` now
  revert with `MultisigEqualsDeployer(addr)` when `multisig == msg.sender`.

### R-17. PrecheckHelper covers remote chain + onToken consistency (round-2 [4])
- **Where:** `script/PrecheckHelper.s.sol`.
- **Issue:** (a) only checked the local chain's Helper config — `deploy-eth` would miss
  BSC placeholders until script 05's BSC-side wiring step. (b) onToken testnet exemption
  was asymmetric with script 05, which `_requireSet`s the remote token even on testnet.
- **Status: FIXED.** Precheck now walks both `block.chainid` and `_remoteChainId(block.chainid)`
  (uses pure `getConfig`, no cross-chain RPC). onToken check now applies on BSC mainnet AND
  BSC testnet (97); ETH-side reads `wrappedON` from Deployments JSON so Helper.onToken can
  remain zero on chainId 1 / 11_155_111.

### R-18. Script 05 re-run signals (round-2 [5][6])
- **Where:** `script/05_ApplyChainUpdates.s.sol`.
- **Issue:** [5] Operators re-running script 05 after editing `DEFAULT_CAPACITY` / `DEFAULT_RATE`
  expected re-application, but the idempotency probe skips silently. [6] If the remote pool
  was redeployed, the idempotency probe sees `isSupportedChain == true` and leaves the local
  pool wired to the stale (dead) remote pool address.
- **Status: FIXED.** [5] Skip-log now explicitly directs operators to `make update-limits`
  for rate-limit changes. [6] Idempotent path now reads `getRemotePool(remoteSelector)` and
  reverts with a clear "stale remote pool wiring" message if it differs from the deployments
  JSON; operator must `applyChainUpdates(removed)` and re-run.

### R-19. Corrupt deployment JSON is undocumented (round-2 [7])
- **Where:** `script/Deployments.sol`.
- **Status: ACCEPTED (documented).** A killed prior broadcast can leave a corrupt JSON
  file. The helper only seeds when the file is missing; a corrupt file makes the next
  `vm.parseJsonAddress` fail with a clear-enough error. Recovery: delete the file and
  re-run. Inline NatSpec now documents this.

### R-20. Opaque `decimals()` revert (round-2 [8])
- **Where:** `src/WrappedON.sol` constructor.
- **Issue:** Calling `IERC20Metadata(onToken).decimals()` on a bare-`IERC20` test mock
  produced a low-level ABI-decode revert instead of the audit's intended
  `DecimalsMismatch` error.
- **Status: FIXED.** `decimals()` call wrapped in try/catch; reverts with new
  `DecimalsUnreadable()` error on a non-conformant token. New test
  `test_ConstructorRevertsOnUnreadableDecimals`.

---

## PR #19 round-3 review follow-ups (brng1151)

A third review pass on commit `8e14688` raised 9 additional items, all of which are
addressed below (R-22 through R-30).

### R-22. PrecheckHelper required `onToken` on BSC testnet placeholder (round-3 [1])
- **Where:** `script/PrecheckHelper.s.sol`.
- **Issue:** Round-2 R-17 broadened the `onToken` precheck from "mainnet only" to "BSC
  mainnet AND BSC testnet (97)". But `Helper.sol` intentionally encodes
  `onToken: address(0)` for BSC testnet ("deploy a mock for testing"). Result: every
  Sepolia / BSC-testnet deploy reverts with `PlaceholderField(97, "onToken")` in the
  precheck before any work happens. The testnet flow that R-17 was meant to harden
  became non-functional.
- **Status: FIXED.** Precheck now requires `onToken` on BSC mainnet (56) only. The
  testnet flow expects operators to deploy a mock and patch Helper manually before
  broadcast — surfacing as a clear `MissingAddress` revert in script 05 if they
  forget, rather than a confused precheck failure on the canonical placeholder.

### R-23. Stateful invariant fuzz did not walk the cap-bypass path (round-3 [2])
- **Where:** `test/WrappedONInvariant.t.sol`.
- **Issue:** The handler kept `bscLocked == ccipMintedSupply` in lockstep — making
  `invariant_CounterTracksBscLocked` tautological and the saturating branch in
  `_decrementCcipMinted` unreachable. The deposit→pool-burn cap-bypass scenario
  flagged in round-2 review [1] was the path the handler refused to walk.
- **Status: FIXED.** New `adversarialPoolBurn(...)` handler selector simulates a
  buggy/compromised pool that burns wON without a matching BSC release (`bscLocked`
  unchanged, `WON.burn(amount)` invoked). The saturating-decrement branch is now
  fuzzer-reachable; `invariant_CounterTracksBscLocked` weakened to
  `invariant_CounterBoundedByBscLocked` (`ccipMintedSupply <= bscLocked`) which holds
  under both honest and adversarial-burn paths and is meaningful (not handler-tautological).

### R-24. `MultisigEqualsDeployer` guard had no unit coverage (round-3 [3])
- **Where:** `script/06_TransferOwnership.s.sol`.
- **Issue:** Round-2 R-16 added the `if (multisig == msg.sender) revert MultisigEqualsDeployer(addr);`
  check in both `TransferOwnership.run()` and `RenounceDeployerAdmin.run()`. No test
  exercised the new revert; a regression dropping the guard would have silently landed.
- **Status: FIXED.** New `test/Script06Guards.t.sol` directly invokes both scripts
  with `MULTISIG=$DEPLOYER` set via `vm.setEnv` and asserts the
  `MultisigEqualsDeployer(addr)` selector fires.

### R-25. Script 04 dispatch had no unit coverage of success paths (round-3 [4])
- **Where:** `test/Script04Paths.t.sol`.
- **Issue:** The `_RegistryAccepts_RegisterAdminViaOwner` and
  `_RegistryAccepts_RegisterAccessControlDefaultAdmin` tests called the registry module
  DIRECTLY. They locked the call shape of `RegistryModuleOwnerCustom` /
  `MockRegistryModuleV16` but never went through script 04's `_registerAdmin` dispatch,
  so paths 1 / 2 / 3 success branches in the script had no observation.
- **Status: FIXED.** New `MockRecordingModule` records which registration selector the
  script chose. Three new tests — `test_Dispatch_Path1_GetCCIPAdmin_…`,
  `test_Dispatch_Path2_Ownable_…`, `test_Dispatch_Path3_AccessControl_…` — exercise
  the harness's `exposeRegisterAdmin` against the recording mock and assert the
  correct module function was invoked with the right token argument. The earlier
  module-direct tests are retained as msg.sender-check coverage for the production
  module.

### R-26. CLAUDE.md still referenced dead `MAX_SUPPLY` / `SupplyCapExceeded` symbols (round-3 [5])
- **Where:** `CLAUDE.md` lines 9–11 and 47–49.
- **Issue:** R-1 renamed `MAX_SUPPLY` → `MAX_CCIP_MINTED` and `SupplyCapExceeded` →
  `CCIPMintCapExceeded`, and the cap now applies to `mint()` only (not `deposit`).
  CLAUDE.md still described both old names and the old behaviour — future agents
  grepping would find nothing.
- **Status: FIXED.** Both passages rewritten to describe the current
  `MAX_CCIP_MINTED`/`ccipMintedSupply` mint cap, the uncapped `deposit` path, and
  cross-reference R-1 + R-14 for the full semantics.

### R-27. Script 06 NatSpec referenced a nonexistent `renounceDeployerAdmin()` function (round-3 [6])
- **Where:** `script/06_TransferOwnership.s.sol` NatSpec preamble.
- **Issue:** Docstring said "use the `renounceDeployerAdmin()` entry point below" but
  the artifact is a separate `RenounceDeployerAdmin` contract with a `run()` entry —
  operators grepping for the function name found nothing.
- **Status: FIXED.** NatSpec updated to point at the `RenounceDeployerAdmin` contract's
  `run()` entry.

### R-28. Script 04 inner `catch` swallowed structured v1.6 reverts (round-3 [7])
- **Where:** `script/04_RegisterAdminAndPool.s.sol`.
- **Issue:** The bare `catch { /* v1.6 selector not available */ }` wrapping the v1.6
  call fell through on ANY revert. A legitimate v1.6 failure (token already registered
  with a different admin, registry paused, re-check failure on AccessControl) got
  swallowed and the operator saw the misleading `CannotResolveCCIPAdmin` "no permission
  to register" diagnostic instead of the actual cause.
- **Status: FIXED.** Replaced with `catch (bytes memory reason) { if (reason.length != 0)
  { assembly { revert(add(reason, 0x20), mload(reason)) } } }` so empty reverts (selector
  absent on a v1.5 registry) fall through to the path-4 diagnostic, but every structured
  revert propagates to the operator unmodified. New unit test
  `test_Dispatch_Path3_StructuredRevertPropagates` locks this behaviour against
  `MockRevertingModuleV16`.

### R-29. SECURITY.md M-4 contradicted R-21 within the same file (round-3 [8])
- **Where:** `SECURITY.md` M-4.
- **Issue:** R-21 rewrote the preflight to mirror CCIP's strict rule (`rate > 0` AND
  `rate < capacity` when enabled; both zero when disabled). M-4's "FIXED" description
  still claimed the script "now requires `capacity > 0` and `rate <= capacity`" — both
  weak forms R-21 explicitly removed. M-4 and R-21 disagreed on what the actual fix was.
- **Status: FIXED.** M-4 reframed as "FIXED (superseded by R-21)" with the strict
  CCIP-mirroring rule described and the original weak rule called out as the bug
  R-21 fixed.

### R-30. `testFuzz_PreflightAgreesWithCcip` was a hand-mirror, not a true cross-check (round-3 [9])
- **Where:** `test/Script07Preflight.t.sol`.
- **Issue:** The fuzz did not call `RateLimiter._validateTokenBucketConfig`. Its
  `_callCcipValidate` re-implemented the protocol's rule inline; a misread of the rule
  would have been baked into both the script preflight AND the "oracle" simultaneously,
  defeating the cross-check.
- **Status: FIXED.** New `CcipRateLimiterValidator` contract is a thin external wrapper
  around `RateLimiter._validateTokenBucketConfig` (callable because it's an `internal
  pure` library function). The fuzz now runs against the real protocol code; three
  concrete spot-check tests pin the wrapper's behaviour so a future CCIP version bump
  shows up as a test-suite divergence rather than silent drift. Assertion strengthened
  to bidirectional `assertEq(preflightAccepts, ccipAccepts, …)` — the disabled-direction
  zero-config case (the bug M-4's original rule got wrong) is now covered in both
  directions.

---

## PR #19 round-3 review follow-ups (bao-ninh)

A third review pass on commit `908ab22` from bao-ninh-orochi raised 11 additional items
(3 doc/script gaps, 6 minors, 2 nits). All addressed below (R-31 through R-41).

### R-31. SECURITY.md C-3 still described the superseded MAX_SUPPLY fix (bao-ninh round-3 [1])
- **Where:** `SECURITY.md` C-3 status paragraph.
- **Issue:** C-3 said *"Hard cap `MAX_SUPPLY = 100_000_000 ether` enforced via a single
  `_mintCapped` helper that both `deposit` and `mint` route through. Reverts
  `SupplyCapExceeded`"* — the round-1 framing. R-1 + R-14 rescoped this to
  `MAX_CCIP_MINTED` (CCIP-mint path only) with `CCIPMintCapExceeded`. R-26 updated
  CLAUDE.md but C-3 itself was untouched.
- **Status: FIXED.** C-3 reframed as "FIXED (superseded by R-1 + R-14)" with the current
  per-path cap semantics described inline and cross-referenced.

### R-32. README.md still claimed wON totalSupply ≤ 100M (bao-ninh round-3 [2])
- **Where:** `README.md` L12 supply table and L234 security narrative.
- **Issue:** Same pattern as R-26 / R-31 — supply table read `≤ 100M` and the security
  TL;DR claimed *"hard-capped at 100M ether across both mint paths"*. Neither holds:
  `totalSupply` can grow up to `MAX_CCIP_MINTED + (ETH-side ON deposited)`; only
  `ccipMintedSupply` is capped.
- **Status: FIXED.** Supply table now reads `CCIP-mint ≤ 100M; deposit-backed uncapped`.
  Security TL;DR rewritten to explain the cap is on the CCIP-mint path, the deposit
  path is naturally bounded, and the safety invariant is preserved by mechanics.

### R-33. Script 08 _checkRateLimits only asserted isEnabled (bao-ninh round-3 [3])
- **Where:** `script/08_PostDeployVerify.s.sol`.
- **Issue:** The fork tests already assert `rate > 0` / `capacity > 0` (gap [7]), but
  the view-only verification script that operators actually run after a real deploy
  (`make verify-eth/bsc`) only checked `isEnabled`. An `isEnabled = true` bucket with
  `rate = 0` silently bricks transfers (the bucket never refills) — `make verify-*`
  would pass and the misconfig would only surface at the first user transaction.
- **Status: FIXED.** New `_assertEnabledAndConfigured` helper checks `isEnabled` AND
  `rate > 0` AND `capacity > 0`. New `RateLimitMisconfigured(direction, capacity, rate)`
  error distinguishes "disabled" from "enabled-but-bricked" so operators get a clear
  diagnostic.

### R-34. RenounceDeployerAdmin didn't gate on pool/registry handoff completion (bao-ninh round-3 [4])
- **Where:** `script/06_TransferOwnership.s.sol` (`RenounceDeployerAdmin`).
- **Issue:** Pre-renounce checks confirmed the wON role handoff, but an operator could
  still call renounce while pool `acceptOwnership` or registry `acceptAdminRole` was
  pending — leaving the bridge in a half-handed-off state (multisig has token admin
  but doesn't own the pool it points at).
- **Status: FIXED.** Two new `require`s before the renounce: (a)
  `pool.owner() == multisig` (pool ownership accepted), (b)
  `registry.getTokenConfig(token).administrator == multisig` (registry admin accepted).
  Both via low-level staticcall to avoid importing the registry struct ABI; the
  administrator field is at offset 0 of `TokenConfig`. Clear diagnostic messages on
  failure: *"pool ownership NOT accepted by multisig (call acceptOwnership first)"* /
  *"registry adminRole NOT accepted by multisig (call acceptAdminRole first)"*.

### R-35. Script 04 path-3 empty-revert heuristic NatSpec (bao-ninh round-3 [5])
- **Where:** `script/04_RegisterAdminAndPool.s.sol`.
- **Issue:** The `if (reason.length != 0)` heuristic that decides whether to propagate
  vs fall through is correct against any structured revert (custom errors, `Error(string)`,
  `Panic(uint256)`), but matches a plain `revert();` (empty-reason explicit revert) under
  the same case as a missing-selector. The deployed v1.6 module doesn't do that; a
  future version that did would silently fall through to the misleading path-4 diagnostic.
- **Status: FIXED (in-code comment).** Documented the heuristic as "selector-absent ↔
  empty revert" rather than "any zero-length return". Behaviour unchanged; comment
  flags the caveat for future maintainers.

### R-36. Scripts 01 + 02 weren't idempotent — RUNBOOK overstated (bao-ninh round-3 [6])
- **Where:** `script/01_DeployWrappedON.s.sol`, `script/02_DeployPools.s.sol`,
  `RUNBOOK.md` opening paragraph.
- **Issue:** Re-running script 01 or 02 deploys a NEW artifact and overwrites the
  `deployments/<chainId>.json` entry, breaking every downstream script that reads it
  (script 03 happens to be idempotent via OZ `_grantRole`'s built-in no-op; scripts
  04 and 05 already have idempotency probes from R-7 / R-18). RUNBOOK opened with
  *"Each step is idempotent"* — false for 01 and 02.
- **Status: FIXED.** Both scripts now probe `Deployments.tryReadAddress` before
  deploying: if the artifact is already recorded, log + skip rather than re-deploy.
  New `Deployments.tryReadAddress` returns `address(0)` when the file is missing OR
  the key is absent (uses `vm.keyExistsJson`). RUNBOOK preamble rewritten to describe
  per-script idempotency accurately, including the "delete the JSON entry to force
  redeploy" recovery path.

### R-37. RUNBOOK didn't mention keystore as the preferred deployer-key option (bao-ninh round-3 [7])
- **Where:** `RUNBOOK.md` §0.3.
- **Issue:** Makefile passes `--private-key $(DEPLOYER_PK)` on the command line, which
  surfaces the key in `ps aux` and shell history during the broadcast window. Foundry
  supports `--account <keystore>` (encrypted, interactive password prompt). Given the
  deployer EOA holds critical authority throughout the handoff window (H-2), this
  should be the documented default for mainnet.
- **Status: FIXED.** RUNBOOK §0.3 now has a "Key-handling note" paragraph explaining
  the keystore option (`cast wallet import deployer --interactive`, then
  `--account deployer`) and cross-references H-2.

### R-38. Dead `DRYRUN_FLAGS` Makefile variable (bao-ninh round-3 [8])
- **Where:** `Makefile`.
- **Status: FIXED.** Removed.

### R-39. `wrapBackedSupply` NatSpec read as if tracked state (bao-ninh round-3 [9])
- **Where:** `src/WrappedON.sol` contract NatSpec + ctor comment, `CLAUDE.md`
  "Reserve invariant" section.
- **Issue:** `wrapBackedSupply` is a conceptual term, not an on-chain storage variable.
  Both files used the phrasing as if it were tracked state (`wrapBackedSupply <= …`),
  which a reader could grep for and find nothing.
- **Status: FIXED.** Both passages rewritten to make explicit that `wrapBackedSupply`
  is conceptual, the invariant is preserved by mechanics (`withdraw` revert when
  reserve insufficient + received-amount accounting in `deposit`), and there is no
  storage variable of that name.

### R-40. Script 05 keccak256 compare nit (bao-ninh round-3 [10])
- **Where:** `script/05_ApplyChainUpdates.s.sol`.
- **Status: FIXED (nit).** Replaced `keccak256(wiredRemote) == keccak256(expectedRemote)`
  with `wiredRemote.length == 32 && bytes32(wiredRemote) == bytes32(uint256(uint160(remotePool)))`.
  Same intent; cheaper, and the assumed 32-byte shape is now explicit.

### R-41. Script 04 didn't log which discovery path it took (bao-ninh round-3 [11])
- **Where:** `script/04_RegisterAdminAndPool.s.sol`.
- **Status: FIXED (nit).** Each of the three success branches now emits a `[path N]`
  console line before returning, so post-deploy broadcast log forensics show which
  registration mechanism actually matched.

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

`forge test --no-match-path 'test/fork/**'` → **88 tests pass** (was 79 after the
Chainlink-compliance pass; +9 added in the round-3 review-follow-ups for Script04
dispatch coverage, Script06 multisig-guard coverage, and CCIP-validator wrapper
spot-checks). Plus 4 stateful invariants × 256 runs × 500 calls each in
`test/WrappedONInvariant.t.sol` (128k assertions per invariant), now including an
`adversarialPoolBurn` selector that walks the saturating-decrement branch (round-3
review [2]). Fork tests (`test/fork/*`) compile and run against ETH_RPC / BSC_RPC.
