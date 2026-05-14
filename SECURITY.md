# SECURITY.md — Orochi Network ON Bridge

Findings from a five-agent security review of the Chainlink CCIP CCT bridge for the
Orochi Network ON token (Ethereum Mainnet ⇄ BNB Smart Chain).

**Scope:** `src/WrappedON.sol`, `script/01–08`, `script/Helper.sol`, `script/Deployments.sol`,
`test/**`, plus integration with vendored Chainlink CCIP contracts in `lib/ccip/`.

Findings are grouped by severity. Each entry: file:line — issue — impact — fix.

---

## Critical (mainnet-blocking)

### C-1. `acceptLiquidity = false` does NOT disable `withdrawLiquidity` on the BSC pool
- **Where:** `lib/ccip/contracts/src/v0.8/ccip/pools/LockReleaseTokenPool.sol:122-130`;
  documentation comment in `script/02_DeployPools.s.sol:38`; CLAUDE.md.
- **Issue:** `i_acceptLiquidity` only gates `provideLiquidity`. `withdrawLiquidity` requires
  only `msg.sender == s_rebalancer`, and `setRebalancer` is `onlyOwner`. The project
  documentation claims this is "permanently disabled (footgun removed)" — that is **wrong**.
- **Impact:** After ownership handoff, the BSC multisig can call
  `setRebalancer(multisig); withdrawLiquidity(100M)` and drain every locked ON token,
  leaving all CCIP-minted wON on Ethereum unbackable.
- **Fix:** Choose one:
  1. Deploy a thin subclass of `LockReleaseTokenPool` that reverts `setRebalancer`,
     `withdrawLiquidity`, and `transferLiquidity`. This contradicts the "no subclassing"
     rule in `CLAUDE.md` — explicitly justify the exception.
  2. Update `CLAUDE.md` and the script comment to honestly describe the trust model:
     "The BSC multisig has full custody of the locked-ON reserve via the rebalancer hook."

### C-2. `Deployments.writeAddress` silently destroys prior JSON entries
- **Where:** `script/Deployments.sol:25-29`.
- **Issue:** `vm.serializeAddress("deployments", key, value)` re-builds the serialization
  object from scratch each forge process. The first call writes `{"wrappedON": "0x…"}`.
  The next call (`pool`) starts with an empty in-memory object, produces
  `{"pool": "0x…"}`, and `vm.writeJson` overwrites the file — erasing `wrappedON`.
- **Impact:** Downstream scripts (04, 05, 06, 08) read `wrappedON` and get `address(0)`
  or a parse error. Live deployments can silently configure the system against the
  wrong addresses if the operator doesn't notice.
- **Fix:** Use the three-argument `vm.writeJson` overload that writes a single key at a
  JSON path without touching the rest of the object:
  ```solidity
  vm.writeJson(vm.toString(value), file, string.concat(".", key));
  ```

### C-3. No global supply cap on wON
- **Where:** `src/WrappedON.sol`.
- **Issue:** wON has two independent mint paths (`deposit`-backed and CCIP-`mint`)
  with no enforced ceiling. The implicit safety invariant
  `lockedON_BSC + reserveON_ETH ≥ totalSupply(wON)` is not encoded.
- **Impact:** A holder can wrap >100M ETH-side ON (canonical max on BSC is 100M),
  bridge 100M wON to BSC, and the BSC pool — which can lock at most 100M — cannot
  service further redemptions from that direction. Combined with C-1, this becomes a
  fund-loss path.
- **Fix:** Enforce a hard cap in `mint`/`deposit`, e.g. `totalSupply() + amount <= 600M`
  matching the canonical ON supply on Ethereum.

---

## High

### H-1. `RenounceDeployerAdmin` doesn't verify the multisig holds `DEFAULT_ADMIN_ROLE`
- **Where:** `script/06_TransferOwnership.s.sol:96-97`.
- **Issue:** The only pre-renounce guard is that the deployer itself still has the role,
  plus a meaningless slot-0 sanity probe. If the multisig grant failed silently or the
  `MULTISIG` env var was wrong, the contract is left admin-less and permanently
  unmanageable (no upgrades by design).
- **Fix:** Before `renounceRole`, require:
  ```solidity
  address multisig = vm.envAddress("MULTISIG");
  require(won.hasRole(adminRole, multisig), "multisig does not hold admin role");
  ```

### H-2. Deployer retains mint authority during the handoff window
- **Where:** `script/06_TransferOwnership.s.sol`.
- **Issue:** Between `TransferOwnership` (grants multisig the admin role) and
  `RenounceDeployerAdmin` (deployer renounces), the deployer EOA still holds
  `DEFAULT_ADMIN_ROLE` and can `grantRole(MINTER_ROLE, attacker)` to mint unlimited
  wON. The window is operator-controlled and unbounded.
- **Fix:** Batch grant + multisig accept + deployer renounce within the same
  operational window. Monitor `RoleGranted(MINTER_ROLE, *)` and
  `RoleGranted(BURNER_ROLE, *)` events during the window and alert on anything
  granted to anyone other than the BurnMintTokenPool address.

### H-3. Missing `_requireSet` guards on critical infrastructure addresses
- **Where:**
  - `script/02_DeployPools.s.sol:25-27` — `cfg.rmnProxy`, `cfg.router` (ETH path)
  - `script/04_RegisterAdminAndPool.s.sol:44-47` — `cfg.registryModuleOwnerCustom`,
    `cfg.tokenAdminRegistry`
  - `script/05_ApplyChainUpdates.s.sol:27-48` — `localPool`, `remotePool`, `remoteToken`;
    note `abi.encode(address(0))` for `remotePool` bypasses the `length == 0` check
    in `applyChainUpdates`.
  - `script/07_UpdateRateLimits.s.sol:27` — `localPool`
- **Issue:** Contradicts CLAUDE.md's promise that "scripts call `_requireSet` on every
  address they consume, so a stale Helper fails fast with a `MissingAddress` revert."
- **Impact:** Stale Helper configurations produce confusing `ZeroAddressNotAllowed`
  reverts deep in the call (or, for the encoded zero address, silent acceptance of an
  invalid remote pool wiring).
- **Fix:** Add `_requireSet` for every consumed address before `vm.startBroadcast()`.

### H-4. Cross-chain front-running of `proposeAdministrator` on BSC ON token
- **Where:** `script/04_RegisterAdminAndPool.s.sol`.
- **Issue:** When the BSC ON token exposes neither `getCCIPAdmin` nor `Ownable.owner`,
  the script reverts and asks the token owner to call `proposeAdministrator` manually.
  No post-registration assertion checks that
  `TokenAdminRegistry.getPool(token) == ourPool` before script 05 broadcasts. If the
  BSC ON token has `getCCIPAdmin()` returning an attacker-controlled address, the
  attacker registers as admin and points the registry at a hostile pool.
- **Fix:** Resolve the BSC ON CCIP-admin path on a private fork **before** mainnet
  broadcast. Add a post-registration assertion in script 05 that the registry's
  administrator and pool match what we expect.

### H-5. `make handoff` is single-chain — no enforcement that BOTH chains were handed off
- **Where:** `Makefile:94-99`; `RUNBOOK.md` §3.1.
- **Issue:** The Makefile target takes a single `RPC=` and broadcasts against one chain.
  An operator who forgets the second chain leaves the deployer EOA as `Ownable` owner
  on that side, with full `applyChainUpdates` / `setChainRateLimiterConfig` authority.
- **Fix:** Add a `handoff-all` target that requires both `ETH_RPC` and `BSC_RPC` and
  runs both broadcasts in sequence with the same `MULTISIG`.

### H-6. `_checkOwnershipHandoff` ignores `pendingOwner()`
- **Where:** `script/08_PostDeployVerify.s.sol:133-140`.
- **Issue:** Between `transferOwnership` and the multisig's `acceptOwnership`, the
  script logs `[ok]` if `owner == multisig` but doesn't flag the in-flight pending
  state. The verification can pass even when ownership transfer was never accepted.
- **Fix:** Also probe `pendingOwner()` and distinguish "active" vs "pending":
  ```solidity
  if (owner == multisig) { console.log("[ok] pool.owner() == multisig"); return; }
  (bool ok2, bytes memory d2) =
      pool.staticcall(abi.encodeWithSignature("pendingOwner()"));
  address pending = (ok2 && d2.length == 32) ? abi.decode(d2, (address)) : address(0);
  require(pending == multisig, "neither owner nor pendingOwner is multisig");
  ```

---

## Medium

### M-1. Script 04 misses the third registration path (`registerAccessControlDefaultAdmin`)
- **Where:** `script/04_RegisterAdminAndPool.s.sol:56-75`.
- **Issue:** The vendored `RegistryModuleOwnerCustom` 1.6 exposes a third registration
  path — for tokens that use OZ `AccessControl.DEFAULT_ADMIN_ROLE`. The script probes
  only `getCCIPAdmin` and `Ownable.owner` before reverting with
  `CannotResolveCCIPAdmin`. BSC-deployed tokens commonly use OZ `AccessControl`.
- **Fix:** Add a probe leg before the revert:
  ```solidity
  try AccessControl(token).hasRole(0x00, broadcaster) returns (bool has) {
      if (has) { module.registerAccessControlDefaultAdmin(token); return; }
  } catch { }
  ```

### M-2. `burn(address, uint256)` bypasses allowance (intentional but undocumented)
- **Where:** `src/WrappedON.sol:89-91`.
- **Issue:** The `burn(address, uint256)` overload calls `_burn` directly with no
  allowance check. Any holder of `BURNER_ROLE` can burn arbitrary balances. This
  matches `IBurnMintERC20` semantics but is dangerous if `BURNER_ROLE` ever leaks
  outside the audited pool.
- **Fix:** Add a `@dev` NatSpec line stating "Does NOT check allowance — `BURNER_ROLE`
  must be held exclusively by the audited `BurnMintTokenPool`." Enforce in the
  operations runbook and verification script.

### M-3. Script 08 doesn't verify deployer renounced `DEFAULT_ADMIN_ROLE`
- **Where:** `script/08_PostDeployVerify.s.sol:125-131`.
- **Issue:** `_checkWonRoles` confirms the pool has `MINTER_ROLE` and `BURNER_ROLE` but
  never checks `!won.hasRole(DEFAULT_ADMIN_ROLE, deployer)`. The most security-critical
  post-condition has no programmatic check.
- **Fix:** Add a `_checkDeployerRenounced(deployer, multisig)` helper:
  ```solidity
  require(!won.hasRole(adminRole, deployer), "deployer still has admin role");
  require(won.hasRole(adminRole, multisig), "multisig missing admin role");
  ```

### M-4. Script 07 doesn't validate `rate ≤ capacity` and non-zero capacity pre-broadcast
- **Where:** `script/07_UpdateRateLimits.s.sol:29-38`.
- **Issue:** A typo'd env var (`OUTBOUND_RATE > OUTBOUND_CAPACITY`) causes the on-chain
  call to revert mid-broadcast. Inside a Gnosis Safe batch this fails the whole batch
  with no clear diagnostic.
- **Fix:** Pre-flight assertions before `vm.startBroadcast()`:
  ```solidity
  require(outbound.capacity > 0, "OUTBOUND_CAPACITY must be > 0");
  require(outbound.rate <= outbound.capacity, "OUTBOUND rate > capacity");
  require(inbound.capacity > 0, "INBOUND_CAPACITY must be > 0");
  require(inbound.rate <= inbound.capacity, "INBOUND rate > capacity");
  ```

### M-5. `Deployments.sol` uses relative paths
- **Where:** `script/Deployments.sol:16`.
- **Issue:** `./deployments/<chainId>.json` resolves from `vm.projectRoot()` only when
  forge is invoked without `--project-root` from the repo root. CI environments or
  scripts invoked from elsewhere will fail to find the file. `vm.readFile` returns an
  empty string and `vm.parseJsonAddress` reverts mid-broadcast.
- **Fix:** Use `string.concat(vm.projectRoot(), "/deployments/", …)` for absolute paths.

### M-6. Vendored CCIP library is not pinned via submodule
- **Where:** `lib/ccip/`.
- **Issue:** ~281 pragma lines were manually patched from `0.8.24` to `^0.8.24`. The
  patch is documented in CLAUDE.md as a `sed` one-liner re-run after `forge install`.
  Without a submodule pin or CI guard, anyone running `forge update` (or a future
  maintainer who doesn't realize lib is vendored) can silently change the audited
  artifact.
- **Fix:** Convert to a real git submodule pinned to a specific Chainlink CCIP release
  tag, and document the pragma patch as a tracked diff. Add a CI check that fails if
  any `lib/ccip/**/*.sol` has a pragma mismatch.

### M-7. wON `setCCIPAdmin` is independent of `DEFAULT_ADMIN_ROLE` and single-step
- **Where:** `src/WrappedON.sol:100-109`; `script/06_TransferOwnership.s.sol:67`.
- **Issue:** `s_ccipAdmin` is rotated only by the current `s_ccipAdmin`. After script 06
  the multisig holds both, but a typo in `MULTISIG` instantly hands CCIP admin to the
  wrong address with no recovery path. Additionally, the deployer could call
  `setCCIPAdmin(deployer)` between handoff and renounce, regaining the registry-level
  admin role.
- **Fix:** Add a 2-step `setCCIPAdmin` / `acceptCCIPAdmin` pattern. In script 06, after
  `won.setCCIPAdmin(multisig)`, assert `won.getCCIPAdmin() == multisig`.

### M-8. Rate-limit per-tx capacity equals bucket capacity — grief vector
- **Where:** `script/05_ApplyChainUpdates.s.sol`; `script/07_UpdateRateLimits.s.sol`.
- **Issue:** Default bucket = 100k ON capacity, 10 ON/sec refill. A single bridge tx can
  drain the entire bucket, blocking other users for ~3 hours until refill. Not a
  fund-loss issue but a real liveness/UX risk.
- **Fix:** Calibrate `capacity` / `rate` against expected traffic. Document expected
  daily volume in `RUNBOOK.md`. Consider an off-chain monitor that alerts on bucket
  exhaustion.

### M-9. Fee-on-transfer / reentrancy hardening on wON (defensive)
- **Where:** `src/WrappedON.sol:63-75`.
- **Issue:** `deposit` mints `amount` of wON regardless of actual tokens received. If
  the ON contract ever introduces a transfer fee, `wrapBackedSupply` exceeds the
  actual reserve. Reentrancy via ERC777-style hooks is theoretically possible if ON
  is ever replaced. The canonical ON at `0x33f6…59d` is a plain ERC20, so this is
  defensive.
- **Fix:** Add `nonReentrant` on `deposit` / `withdraw`. Use received-amount accounting:
  ```solidity
  uint256 before = ON.balanceOf(address(this));
  ON.safeTransferFrom(msg.sender, address(this), amount);
  uint256 received = ON.balanceOf(address(this)) - before;
  _mint(msg.sender, received);
  ```

---

## Low / Nit

- **`Makefile:47` — `test-e2e` passes `--match-path` twice.** Forge honors only the last,
  so only `DeploymentE2E.t.sol` actually runs. Use a regex:
  `--match-path 'test/(PoolRoundtrip|DeploymentE2E).t.sol'`.
- **`script/08_PostDeployVerify.s.sol:97` — `vm.load(won, bytes32(0))` is vacuous.**
  Slot 0 in `ERC20` is the `_balances` mapping pointer (always zero). Replace with
  `won.totalSupply() > 0 || won.ON() != address(0)`.
- **`src/WrappedON.sol:113` — `supportsInterface` declared `pure` vs parent `view`.**
  ABI-compatible, no action needed.
- **`src/WrappedON.sol:63` — `deposit(0)` is a silent no-op that emits `Wrapped(_, 0)`.**
  Wastes gas and clutters event indexers. Add a `require(amount > 0, …)`.
- **CLAUDE.md pragma-patch one-liner re-runs after `forge install`.** Idempotent today
  but brittle — add `make install` that runs the patch automatically.

---

## Test coverage gaps (priority order)

1. **Reserve invariant never directly asserted.** No test reads `wrapBackedSupply`
   (which is not even a state variable today) and checks against
   `ON.balanceOf(WrappedON)` after mixed deposit/mint/withdraw/burn sequences.
2. **No test for `renounceRole` before multisig accepts.** The single most dangerous
   operator misorder is not exercised.
3. **No rate-limit bucket-exhaustion test.** Limits are configured but never driven
   to their cap.
4. **No negative test for script 04's "neither admin path" revert.** CLAUDE.md
   promises a clear revert message; not exercised in the suite.
5. **BSC pool ownership handoff has zero coverage.** `test_E2E_OwnershipHandoff`
   tests only the ETH-side pool.
6. **No fuzz tests anywhere.** A minimal `testFuzz_DepositWithdrawRoundtrip(uint128)`
   would catch any 1:1 accounting drift.
7. **Fork tests don't assert non-zero `rate` / `capacity`.** An `isEnabled=true`
   limiter with zero rate silently blocks all transfers.
8. **Script 04's `registerAdminViaOwner` path** is not simulated; only the
   `getCCIPAdmin` branch is.

---

## Verified correct (do not re-flag in future reviews)

- `BurnMintTokenPool` / `LockReleaseTokenPool` constructor args.
- `applyChainUpdates` struct layout — `remotePoolAddresses` as `bytes[]` of
  `abi.encode(address)`, `remoteTokenAddress` as `bytes`.
- Chain selectors: ETH Mainnet `5_009_297_550_715_157_269`, BSC Mainnet
  `11_344_663_589_394_136_015` — match the canonical Chainlink CCIP directory.
- wON correctly implements the runtime `IBurnMintERC20` interface; selectors match
  what `BurnMintTokenPool._burn` and `releaseOrMint` invoke.
- Decimals (18/18) and `localTokenDecimals` config are consistent.
- `SafeERC20` is used throughout for ON interactions.
- Donation of ON to the wON contract is benign — only the reserve grows; extra ON
  cannot be extracted without burning wON.

---

## Pre-mainnet action checklist

- [ ] Resolve C-1: either subclass `LockReleaseTokenPool` to neuter
      `withdrawLiquidity` / `setRebalancer`, or update documentation to honestly
      describe the multisig trust model.
- [ ] Fix C-2: `Deployments.writeAddress` JSON corruption.
- [ ] Add C-3: global supply cap on wON.
- [ ] Add H-1 guard: multisig must hold `DEFAULT_ADMIN_ROLE` before deployer renounces.
- [ ] Add H-3 `_requireSet` calls across scripts 02 / 04 / 05 / 07.
- [ ] Add H-4 post-registration assertion in script 04; resolve BSC ON admin path on
      private fork.
- [ ] Add H-5 `handoff-all` Makefile target.
- [ ] Add H-6 `pendingOwner()` probe in script 08.
- [ ] Add the 8 test-coverage items above — at minimum #1 and #2.
- [ ] Convert `lib/ccip` to a pinned submodule with a tracked pragma-patch diff.
