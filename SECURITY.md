# SECURITY.md — Orochi Network ON Bridge

Findings from a five-agent security review of the Chainlink CCIP CCT bridge for the
Orochi Network ON token (Ethereum Mainnet ⇄ BNB Smart Chain), with the disposition of
each finding tracked inline.

**Scope:** `src/WrappedON.sol`, `script/01–08`, `script/Helper.sol`, `script/Deployments.sol`,
`test/**`, plus integration with vendored Chainlink CCIP contracts in `lib/ccip/`.

**Reviewed against:** `lib/ccip @ v2.17.0-ccip1.5.16` (production CCIP 1.5.x ABI).

## Status summary (PR #19, commit 0233f30)

| Severity | Total | Fixed in code | Accepted (documented) | Partial / operational |
|---|---:|---:|---:|---:|
| Critical | 3 | 2 (C-2, C-3) | 1 (C-1) | 0 |
| High     | 6 | 4 (H-1, H-3, H-5, H-6) | 1 (H-2) | 1 (H-4) |
| Medium   | 9 | 8 (M-1, M-2, M-3, M-4, M-5, M-6, M-7, M-9) | 1 (M-8 calibration) | 0 |
| Low/Nit  | 6 | 5 | 1 (`supportsInterface pure` — no action needed) | 0 |
| **Total** | **24** | **19** | **4** | **1** |

CI status (`feat/ccip-bridge`): Build & test ✓, Slither static analysis ✓ (`naming-convention`
excluded for the deliberate `IERC20 public immutable ON`). 41/41 non-fork tests pass.

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

1. **Reserve invariant never directly asserted.** No test reads `wrapBackedSupply`
   (which is not a state variable today) and checks against `ON.balanceOf(WrappedON)`
   after mixed deposit/mint/withdraw/burn sequences.
2. **No test for `renounceRole` before multisig accepts.** Now caught at runtime by
   `RenounceDeployerAdmin` (H-1 fix), but still worth a negative test.
3. **No rate-limit bucket-exhaustion test.** Limits are configured but never driven
   to their cap.
4. **No negative test for script 04's "neither admin path" revert.**
5. **BSC pool ownership handoff has zero unit coverage.** `test_E2E_OwnershipHandoff`
   tests only the ETH-side pool.
6. **No fuzz tests anywhere.** A minimal `testFuzz_DepositWithdrawRoundtrip(uint128)`
   would catch any 1:1 accounting drift, and a fuzz around `MAX_SUPPLY` would catch
   off-by-one regressions on the cap.
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
