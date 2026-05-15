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

PR #19 reviewer follow-ups (R-1 through R-13 below): 11 fixed in code, 2 documented. 50/50
non-fork tests pass.

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

### C-3. No global supply cap on wON
- **Where:** `src/WrappedON.sol`.
- **Issue:** wON had two independent mint paths (`deposit`-backed and CCIP-`mint`) with
  no enforced ceiling. The implicit safety invariant `lockedON_BSC + reserveON_ETH ≥
  totalSupply(wON)` was not encoded.
- **Status: FIXED.** Hard cap `MAX_SUPPLY = 100_000_000 ether` enforced via a single
  `_mintCapped` helper that both `deposit` and `mint` route through. Reverts
  `SupplyCapExceeded(cap, wouldBe)`. 100M = canonical ON supply on BSC = the absolute
  upper bound on what the bridge can ever reflect onto Ethereum.

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

### M-4. Script 07 didn't validate `rate ≤ capacity` and non-zero capacity pre-broadcast
- **Status: FIXED.** `script/07_UpdateRateLimits.s.sol` now requires
  `capacity > 0` and `rate <= capacity` for both inbound and outbound BEFORE
  `vm.startBroadcast`. Typo'd env vars now fail loudly off-chain.

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
   CCIP `mint` / CCIP `burn` against a real `WrappedON`, with a simulated BSC pool balance,
   and continuously asserts the audit safety invariant
   `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` — plus three companion invariants:
   counter tracks BSC balance, counter stays within `MAX_CCIP_MINTED`, and reserve ≤
   cumulative deposits. 4 invariants × 256 runs × 500 calls each (= 128k calls per
   invariant) all pass with zero reverts.
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
7. **Fork tests don't assert non-zero `rate` / `capacity`.** An `isEnabled=true`
   limiter with zero rate silently blocks all transfers.
8. **Script 04's `registerAdminViaOwner` and the new `registerAccessControlDefaultAdmin`
   paths** are not simulated; only the `getCCIPAdmin` branch is.

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
- [ ] Add the 8 open test-coverage items above — at minimum #1 (reserve invariant
      fuzz) and #2 (renounce-before-accept negative test).
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

## Test suite total (post round-2)

`forge test --no-match-path 'test/fork/**'` → 51 tests pass (added
`test_ConstructorRevertsOnUnreadableDecimals`).
