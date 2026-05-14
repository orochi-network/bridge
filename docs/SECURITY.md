# Security Findings — ON Bridge

Tracker for issues raised by the multi-agent CCIP compliance & security review (5 expert reviewers, 2026-05-12). Severity reflects pre-mainnet impact, not exploit complexity.

**Legend:** `[ ]` open · `[x]` fixed · `[~]` in progress · `[-]` won't fix (justify in notes)

---

## CRITICAL — block mainnet rollout

### [ ] C-1 — `wrapBackedSupply` is never tracked; CCIP minters can drain depositor reserve
- **Files:** `src/WrappedON.sol:63-75`
- **Reported by:** WrappedON security review, cross-chain attack surface review, test coverage review (3 independent confirmations)
- **Issue:** The documented invariant `wrapBackedSupply <= ON.balanceOf(WrappedON)` has no on-chain enforcement. `withdraw` checks the raw `ON.balanceOf(this)`, not the wrap-backed portion. A CCIP-minted wON holder can call `withdraw` and drain a wrap-depositor's reserve, leaving the depositor unable to redeem their own native ON.
- **Exploit trace:** Alice `deposit(100)` → reserve=100, supply=100. CCIP pool `mint(bob, 50)` → reserve=100, supply=150. Bob `withdraw(50)` → reserve=50. Alice `withdraw(100)` → reverts. Bob has redeemed against Alice's collateral.
- **Fix:** Add `uint256 public wrapBackedSupply`. Increment in `deposit`, decrement in `withdraw`. Gate `withdraw` on `wrapBackedSupply >= amount` (equivalent to `ON.balanceOf(this) - ccipMintedSupply >= amount`).
- **Verification:** Add the Foundry invariant test from MUST-ADD #1 below.

### [ ] C-2 — `RenounceDeployerAdmin` safety guard is always-true
- **Files:** `script/06_TransferOwnership.s.sol:97`
- **Reported by:** Deployment scripts review
- **Issue:** `vm.load(won, bytes32(0))` reads OZ ERC20's `_name` slot, which is non-zero from deployment forward. The check passes unconditionally and provides zero protection against running `make renounce` before the multisig has accepted ownership.
- **Fix:** Replace the slot-0 check with an actual capability check:
  ```solidity
  address multisig = vm.envAddress("MULTISIG");
  require(won.hasRole(adminRole, multisig), "multisig does not hold admin role yet");
  ```
- **Verification:** Add test #7 below (premature-renounce scenario).

### [ ] C-3 — Rate-limit capacity covers only 0.1% of BSC supply
- **Files:** `script/05_ApplyChainUpdates.s.sol:20-21`
- **Reported by:** Cross-chain attack surface review, CCIP compliance review
- **Issue:** `DEFAULT_CAPACITY = 100_000 ether`, `DEFAULT_RATE = 10 ether`. The BSC `LockReleaseTokenPool` holds up to 100M ON. A compromised CCIP messaging layer or remote ETH pool can drain 100,000 ON immediately, then 864,000 ON/day. The inline `TODO "calibrate from production traffic"` acknowledges this is not production-ready. The `rate > capacity` ratio also means the bucket caps at capacity in practice, making the effective cap 100,000 ON per burst.
- **Fix:** Set initial capacity to a value the team is willing to lose in one incident (suggested: 10,000–25,000 ON). Make values environment-overridable like script 07. Consider asymmetric inbound vs outbound limits — see M-7.
- **Verification:** Add rate-limit exhaustion tests (MUST-ADD #5).

---

## HIGH

### [ ] H-1 — `Deployments.writeAddress` wipes the JSON file on every call
- **Files:** `script/Deployments.sol:25-29`
- **Reported by:** Deployment scripts review
- **Issue:** `vm.serializeAddress("deployments", key, value)` only writes one key per call. Running script 02 (writes `"pool"`) after script 01 (wrote `"wrappedON"`) overwrites the file with `{"pool": "0x..."}`, losing `"wrappedON"`. Script 05 then reads stale/missing data.
- **Fix:**
  ```solidity
  function writeAddress(uint256 chainId, string memory key, address value) internal {
      vm.writeJson(vm.toString(value), path(chainId), string.concat(".", key));
  }
  ```

### [ ] H-2 — Missing `_requireSet` guards on pool constructor args
- **Files:** `script/02_DeployPools.s.sol:25-39`
- **Issue:** `cfg.rmnProxy` and `cfg.router` passed to `BurnMintTokenPool` / `LockReleaseTokenPool` constructors without `_requireSet`. If Helper.sol still has placeholder zeros at broadcast time, the pool is permanently misconfigured (constructor args are immutable).
- **Fix:** Add `_requireSet(cfg.router, "router")` and `_requireSet(cfg.rmnProxy, "rmnProxy")` before each pool deployment.

### [ ] H-3 — Missing `_requireSet` guards in admin registration
- **Files:** `script/04_RegisterAdminAndPool.s.sol:44-47`
- **Issue:** `cfg.registryModuleOwnerCustom` and `cfg.tokenAdminRegistry` consumed without zero checks. Calls to `address(0)` silently succeed with empty return data; `acceptAdminRole` and `setPool` become no-ops. The token never gets a registered admin and CCIP message execution will revert at runtime.
- **Fix:** Add `_requireSet` calls at the top of `run()` before `vm.startBroadcast()`.

### [ ] H-4 — Missing `_requireSet` on `remoteToken` in chain wiring
- **Files:** `script/05_ApplyChainUpdates.s.sol:29`
- **Issue:** On BSC, `_remoteTokenAddress` falls through to `remote.onToken`, which is `address(0)` for the Sepolia testnet config. `abi.encode(address(0))` is written as the remote token. `applyChainUpdates` doesn't validate the bytes, so this succeeds silently — CCIP then presents the wrong destination token to the OffRamp.
- **Fix:** Add `_requireSet(remoteToken, "remoteToken")` after the address is resolved.

### [ ] H-5 — `setCCIPAdmin` is single-step; typo permanently bricks CCIP admin
- **Files:** `src/WrappedON.sol:104-109`
- **Reported by:** WrappedON security review, cross-chain attack surface review
- **Issue:** `s_ccipAdmin` controls registration of wON in `TokenAdminRegistry` via `registerAdminViaGetCCIPAdmin`. A typo during multisig handoff permanently locks out the legitimate admin with no recovery path — the contract is non-upgradeable and `DEFAULT_ADMIN_ROLE` has no power over `s_ccipAdmin`.
- **Fix:** Two-step pattern matching OZ `Ownable2Step`:
  ```solidity
  address public pendingCcipAdmin;
  function proposeCCIPAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) { ... }
  function acceptCCIPAdmin() external { require(msg.sender == pendingCcipAdmin, ...); ... }
  ```

### [ ] H-6 — No reentrancy guard on `deposit`/`withdraw`
- **Files:** `src/WrappedON.sol:63-75`
- **Issue:** Not exploitable against the current ON token (standard ERC20, no hooks), but the absence of `nonReentrant` on functions that read external balance, mutate supply, and then call `safeTransfer` is fragile by design. Auditors will flag this regardless.
- **Fix:** Inherit OZ `ReentrancyGuard` and apply `nonReentrant` to `deposit` and `withdraw`.

### [ ] H-7 — Post-handoff verification silently skips BSC `acceptOwnership` check
- **Files:** `script/08_PostDeployVerify.s.sol:67,133-140`; `Makefile:85`
- **Issue:** `_checkOwnershipHandoff` only validates when `MULTISIG` env var is set. The Makefile target doesn't require it. Result: a BSC pool ownership handoff that was never accepted goes undetected; RUNBOOK step 3.3 reports false-green.
- **Fix:** Make `verify-post-handoff` Makefile target require `MULTISIG`:
  ```makefile
  verify-post-handoff:
      @test -n "$(MULTISIG)" || (echo "MULTISIG required"; exit 1)
      MULTISIG=$(MULTISIG) forge script script/08_PostDeployVerify.s.sol --rpc-url $(RPC)
  ```
- Also assert `TokenAdminRegistry.getTokenConfig(token).administrator` matches expected address (deployer pre-handoff, multisig post-handoff).

---

## MEDIUM

### [ ] M-1 — `DEFAULT_ADMIN_ROLE` can re-grant `MINTER_ROLE` to anyone post-handoff
- **Files:** `src/WrappedON.sol:35-36`
- **Issue:** OZ `AccessControl` permits `DEFAULT_ADMIN_ROLE` to grant `MINTER_ROLE` to any address. A compromised multisig can mint unlimited wON. The "MINTER_ROLE only goes to the pool" constraint in CLAUDE.md is documentation, not on-chain enforcement.
- **Fix options:** (a) Override `_grantRole` to revert when granting `MINTER_ROLE`/`BURNER_ROLE` to non-pool addresses; (b) make pool address immutable and enforce in `mint`/`burn` directly; (c) document the trust assumption explicitly in NatSpec.

### [ ] M-2 — `burn(address, uint256)` bypasses allowance and appears unused
- **Files:** `src/WrappedON.sol:89-91`
- **Issue:** The two-argument `burn` overload destroys tokens from any account without an allowance check. The actual `BurnMintTokenPool` v1.5.1 only calls `burn(uint256)` (single-argument, self-burn). The two-argument overload is a footgun if `BURNER_ROLE` is ever misgranted.
- **Fix:** Either remove the two-argument overload (preferred — confirm via pool source first) or add explicit NatSpec warning that allowance is bypassed.

### [ ] M-3 — `proposeAdministrator` fallback path has no companion script
- **Files:** `script/04_RegisterAdminAndPool.s.sol:72`
- **Issue:** When BSC ON exposes neither `getCCIPAdmin` nor `Ownable`, script 04 reverts and instructs the operator to have the token owner call `proposeAdministrator` manually. After that, `acceptAdminRole` + `setPool` must still happen, but there's no companion script entry point and the revert message says "re-run skipping registration" — no such flag exists.
- **Fix:** Add `runPostPropose()` entry point that skips `_registerAdmin` and only calls `acceptAdminRole` + `setPool`. Update the revert message to point at it.

### [ ] M-4 — E2E test does not exercise script 04's auto-detection branches
- **Files:** `test/DeploymentE2E.t.sol:149-154`
- **Issue:** The test uses the `proposeAdministrator` fallback path. Production script 04 tries `getCCIPAdmin` first, then `Ownable.owner`. The auto-detection branches (option 1 and option 2) are never exercised.
- **Fix:** Add a second E2E variant where `onBsc` is deployed by `deployer` so `Ownable.owner() == deployer`, exercising the auto-detection path script 04 will actually use on mainnet.

### [ ] M-5 — Script 05 reads remote artifact with no existence guard
- **Files:** `script/05_ApplyChainUpdates.s.sol:28`; `script/Deployments.sol`
- **Issue:** `vm.readFile` throws an opaque Forge error if the artifact file doesn't exist. Running ETH script 05 before BSC has been deployed reverts mid-broadcast with a confusing message.
- **Fix:** Add `require(vm.exists(file), "Missing artifact — deploy remote chain first")` in `Deployments.readAddress`.

### [ ] M-6 — Rate limit defaults are hardcoded with TODO and no mainnet gate
- **Files:** `script/05_ApplyChainUpdates.s.sol:17-21`
- **Issue:** Unlike script 07 (env-driven), script 05 hardcodes capacity/rate. Forgetting to update them before mainnet broadcast goes live as-is.
- **Fix:** Read from environment with defaults; at minimum, `require(block.chainid != 1 && block.chainid != 56 || values overridden)` gate.

### [ ] M-7 — Rate limits are symmetric but exposure is asymmetric
- **Files:** `script/05_ApplyChainUpdates.s.sol`
- **Issue:** Inbound and outbound limits are identical, but a compromised ETH pool (unbounded wON mint) and a compromised BSC pool (drain of 100M locked ON) carry very different downside. BSC inbound is the last line of defense against ETH-side key compromise.
- **Fix:** Set BSC inbound capacity conservatively (5k–10k ON initially), increase gradually based on production traffic.

### [ ] M-8 — BSC pool starts empty; ETH→BSC direction reverts at launch
- **Files:** `RUNBOOK.md` (documentation gap)
- **Issue:** `acceptLiquidity=false` means the pool can never be pre-funded. The first user must bridge BSC→ETH; ETH→BSC is unavailable until then. Not currently documented in user-facing materials.
- **Fix:** Document explicitly in RUNBOOK.md and any user-facing materials.

### [ ] M-9 — `supportsInterface` may diverge from CCIP pool's vendored IERC20
- **Files:** `src/WrappedON.sol:27-31,114`
- **Issue:** The contract uses CCIP-vendored `IBurnMintERC20` for the interface ID computation but inherits OZ v5's `IERC20`. Current `BurnMintTokenPool` (1.5.1) doesn't introspect `supportsInterface`, so not a deployment blocker — but future pool versions or third-party integrators may, and would see `false`.
- **Fix:** Document explicitly as an accepted risk for future pool upgrades.

---

## LOW

### [ ] L-1 — Zero-amount `deposit`/`withdraw` succeed and emit misleading events
- **Files:** `src/WrappedON.sol:63-75`
- **Fix:** `if (amount == 0) revert ZeroAmount();` at the top of both.

### [ ] L-2 — `console.log` prints wrong chain selector
- **Files:** `script/05_ApplyChainUpdates.s.sol:51`
- **Issue:** Logs `local.chainSelector` where `remote.chainSelector` was intended. No functional impact; misleading operator output.
- **Fix:** Replace `local.chainSelector` with `remote.chainSelector`.

### [ ] L-3 — `make test-e2e` silently skips PoolRoundtrip tests
- **Files:** `Makefile:46`
- **Issue:** Forge only honors the last `--match-path` flag. CI may show green while roundtrip tests aren't running.
- **Fix:** `--match-path 'test/{PoolRoundtrip,DeploymentE2E}.t.sol'` or run `make test`.

### [ ] L-4 — Renounce script doesn't verify multisig has accepted pool ownership
- **Files:** `script/06_TransferOwnership.s.sol:89-104`
- **Issue:** Only checks deployer holds wON `DEFAULT_ADMIN_ROLE`. Pool `Ownable` and `TokenAdminRegistry` admin role can still be pending.
- **Fix:** Add read-only `require(ITokenPoolOwnable(pool).owner() == multisig, ...)` before renouncing.

### [ ] L-5 — Script 03 re-run emits spurious `RoleGranted` events
- **Files:** `script/03_GrantRoles.s.sol:18-20`
- **Issue:** OZ `grantRole` is a silent no-op if role already held but still emits the event. Mildly misleading audit trail. Not a code change — clarify RUNBOOK idempotency wording.

### [ ] L-6 — Chain selectors duplicated in tests instead of referencing Helper
- **Files:** `test/PoolRoundtrip.t.sol:41-42`, `test/DeploymentE2E.t.sol:39-40`
- **Fix:** Reference `Helper.ETH_MAINNET_SELECTOR` and `Helper.BSC_MAINNET_SELECTOR` directly.

### [ ] L-7 — Operational: pool redeploy without coordinated `applyChainUpdates` silently breaks bridge
- **Files:** `RUNBOOK.md`
- **Fix:** Document the dual-chain coordination requirement.

---

## Test Coverage Gaps

### MUST-ADD before mainnet

- [ ] **T-1** Foundry invariant test for the reserve property (random interleaving of `deposit`/`withdraw`/`mint`/`burn`). Required to validate C-1's fix.
- [ ] **T-2** Fork tests against real BSC ON token (`0x0e4F6209eD984b21EDEA43acE6e09559eD051D48`) resolving the CLAUDE.md open item: which admin-registration branch does the token expose?
- [ ] **T-3** Zero-amount `deposit`/`withdraw` edge cases (pins the design decision from L-1).
- [ ] **T-4** `supportsInterface(type(IBurnMintERC20).interfaceId) == true` assertion.
- [ ] **T-5** Rate-limit exhaustion: `lockOrBurn` revert when amount > capacity; refill behavior over time.

### SHOULD-ADD

- [ ] **T-6** `setCCIPAdmin` event emission assertion.
- [ ] **T-7** Premature-renounce scenario: deployer renounces before multisig accepts pool ownership → confirm no-admin state is detectable.
- [ ] **T-8** Non-BURNER caller cannot use `burn(address, uint256)` even with full allowance.
- [ ] **T-9** Stray `ON.transfer(address(won), x)` does not mint wON and does not allow overclaiming.
- [ ] **T-10** `releaseOrMint` with wrong source-pool address is rejected.

### NICE-TO-HAVE

- [ ] **T-11** `provideLiquidity` on BSC pool reverts (pins `acceptLiquidity=false` permanence).
- [ ] **T-12** Sequential `withdraw` then `deposit` in same block preserves accounting.
- [ ] **T-13** `RenounceDeployerAdmin` script with deployer-role-already-renounced fails clearly.

---

## Confirmed-correct (no action needed)

- Stock pool usage (no subclassing of `BurnMintTokenPool` / `LockReleaseTokenPool`).
- `acceptLiquidity = false` on BSC pool (`02_DeployPools.s.sol:38`).
- `localTokenDecimals = 18` consistent on both pools.
- Chain selectors `ETH_MAINNET_SELECTOR = 5009297550715157269`, `BSC_MAINNET_SELECTOR = 11344663589394136015`.
- `block.chainid` dispatch covers mainnet/testnet pairs and reverts on unsupported chains (anvil chainid 31337 included).
- `vm.startBroadcast` placement: view calls outside, state changes inside.
- CCIP-delegated concerns (replay, message ordering, idempotency) correctly not re-implemented in this repo.
- No decimal scaling needed (both tokens 18 decimals).

---

## Review provenance

Five expert agents (2026-05-12 review):
1. CCIP protocol compliance
2. WrappedON contract security
3. Deployment & operations security
4. Cross-chain attack surface
5. Test coverage & invariant adequacy

C-1, H-2/H-3/H-4, and H-5 were independently identified by multiple reviewers — treat as highest confidence.
