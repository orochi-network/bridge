# wON Auto-Unwrap + Permissionless Deposit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make wON auto-unwrap to native ON on covered BSC→ETH CCIP arrivals, and make `deposit` permissionless — shipped in one new (redeployed) `WrappedON`.

**Architecture:** Both behaviors live in the single custom contract `src/WrappedON.sol`; CCIP pools stay stock. `mint` (called by the stock `BurnMintTokenPool` on arrival) delivers native ON from the reserve when it fully covers the amount (all-or-nothing), else mints wON as today. `deposit` drops its role gate. The `LIQUIDITY_MANAGER_ROLE` is removed entirely. The contract is non-upgradeable and the on-chain instance is clean (no holders/reserve), so this ships via a fresh ETH-side redeploy + a BSC lane re-wire.

**Tech Stack:** Foundry (forge), Solidity 0.8.34, CCIP 1.6.1 (`lib/chainlink-ccip`), OZ contracts 5.6.1.

## Global Constraints

- Solidity `0.8.34`, optimizer 200, `evm_version = cancun`.
- Keep `src/WrappedON.sol` the ONLY custom contract; do NOT subclass the stock CCIP pools.
- No Claude attribution in commits or PRs.
- Run `make fmt` before each commit; `make test` must stay green (130-test mock suite; fork tests self-skip without RPC).
- All-or-nothing auto-unwrap: deliver native ON only when `ON.balanceOf(wON) >= amount`; never partial.
- Auto-unwrap mints 0 wON and MUST NOT touch `ccipMintHeadroomUsed`.
- Safety invariant must hold: `lockedON_BSC + reserveON_ETH >= totalSupply(wON)`.

---

## File structure

- `src/WrappedON.sol` — contract changes (deposit gate removal, role removal, auto-unwrap in `mint`, new event).
- `script/06_TransferOwnership.s.sol`, `script/08_PostDeployVerify.s.sol` — drop role grant/renounce/verify.
- `test/WrappedON.t.sol` — unit tests (deposit permissionless; new auto-unwrap tests).
- `test/WrappedONInvariant.t.sol` — handler + invariant accounting for auto-unwrap.
- `test/PoolRoundtrip.t.sol`, `test/fork/Fork_ETH.t.sol` — pool-level auto-unwrap coverage.
- `test/Script06Renounce.t.sol`, `test/Script08Verify.t.sol` — drop role assertions.
- `CLAUDE.md`, `README.md`, `RUNBOOK.md`, `docs/ARCHITECTURE.md`, `SECURITY.md`, `STATE.md` — docs + security record + redeploy runbook.

---

## Task 1: Permissionless deposit + remove `LIQUIDITY_MANAGER_ROLE`

Because `forge` compiles the whole project, the role constant cannot be removed in isolation — every referencing file changes in this one task so the build stays green.

**Files:**
- Modify: `src/WrappedON.sol`
- Modify: `script/06_TransferOwnership.s.sol`, `script/08_PostDeployVerify.s.sol`
- Modify: `test/WrappedON.t.sol`, `test/WrappedONInvariant.t.sol`, `test/Script06Renounce.t.sol`, `test/Script08Verify.t.sol`

**Interfaces:**
- Produces: `WrappedON.deposit(uint256)` callable by any address; `LIQUIDITY_MANAGER_ROLE` no longer exists.

- [ ] **Step 1: Contract — make `deposit` permissionless and delete the role**

In `src/WrappedON.sol`:

Delete the role constant (the `LIQUIDITY_MANAGER_ROLE` block, currently lines 70-76):
```solidity
    /// @notice Gates `deposit` (the wrap path). SECURITY: M3 (#25) — ...
    bytes32 public constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
```

In the constructor, delete the grant (currently lines 155-157):
```solidity
        // M3 (#25): seed the reserve manager. ...
        _grantRole(LIQUIDITY_MANAGER_ROLE, admin);
```

Change `deposit`'s signature — remove the modifier and update the M3 NatSpec line:
```solidity
    /// @notice Pulls `amount` ON and mints wON to `msg.sender` (1:1). Permissionless.
    /// @dev Received-amount accounting keeps the wrap exact under fee-on-transfer variants
    ///      (defensive; canonical ON is plain ERC20). `nonReentrant` guards against future
    ///      hook-bearing tokens. Uncapped — bounded by ETH-side ON supply; independent of
    ///      `MAX_CCIP_MINTED` so heavy wrap usage can't starve inbound CCIP.
    /// @dev WON-14: also rejects `received == 0` after the transfer (see existing rationale).
    function deposit(uint256 amount) external nonReentrant {
```
(Keep the body unchanged.)

- [ ] **Step 2: Scripts — drop role grant/renounce/verify**

In `script/06_TransferOwnership.s.sol`:
- In `_handoff`, delete the LIQUIDITY_MANAGER_ROLE grant block (currently lines 158-167, the `// M3 (#25): hand the reserve-manager role...` comment through the `else { won.grantRole(liquidityRole, multisig); ... }`).
- In `RenounceDeployerAdmin.run`, delete the `liquidityRole` local + its renounce (currently lines 250, 254-258) and simplify the post-checks (lines 261-263) to:
```solidity
        require(!won.hasRole(adminRole, deployer), "renounce failed: deployer still has role");
        console.log("Deployer", deployer, "renounced DEFAULT_ADMIN_ROLE on wON");
```
- In `_assertReadyToRenounce`, delete the LIQUIDITY_MANAGER_ROLE precondition (currently the `// M3 (#25): the renounce below drops...` comment + the `require(won.hasRole(won.LIQUIDITY_MANAGER_ROLE(), multisig), ...)` at lines 290-299).

In `script/08_PostDeployVerify.s.sol`, `_checkDeployerRenounced` (currently lines 336-355): delete the LIQUIDITY_MANAGER_ROLE block (the `// M3 (#25)...` comment + `liquidityRole` local + both `RoleMissing`/`RoleNotRenounced` checks at 342-348) and the two LIQUIDITY_MANAGER_ROLE `console.log` lines (353, 355). Keep the DEFAULT_ADMIN_ROLE and ccipAdmin checks.

- [ ] **Step 3: Unit tests — deposit permissionless**

In `test/WrappedON.t.sol`:
- In `setUp` delete the role-grant lines (155-156):
```solidity
        // M3 (#25): deposit is gated to LIQUIDITY_MANAGER_ROLE; alice is the test depositor.
        won.grantRole(won.LIQUIDITY_MANAGER_ROLE(), alice);
```
- Delete these now-obsolete tests entirely: `test_DepositSucceedsWithLiquidityManagerRole` (227-241), `test_ConstructorGrantsLiquidityManagerRoleToAdmin` (245-248), `test_AdminCanRevokeLiquidityManagerRole` (251-261).
- Replace `test_DepositRevertsWithoutLiquidityManagerRole` (211-224) with a permissionless test:
```solidity
    /// @notice Issue 2: `deposit` is permissionless — any holder with ON + approval can wrap.
    function test_DepositPermissionlessForAnyCaller() public {
        vm.prank(alice);
        on.transfer(bob, 50 ether);
        vm.startPrank(bob);
        on.approve(address(won), 50 ether);
        won.deposit(50 ether);
        vm.stopPrank();
        assertEq(won.balanceOf(bob), 50 ether);
        assertEq(on.balanceOf(address(won)), 50 ether);
    }
```
- In `test_DepositRevertsOnReceivedZero` (183-196) delete the role-grant lines (188-192):
```solidity
        bytes32 lmRole = nullWon.LIQUIDITY_MANAGER_ROLE();
        vm.prank(admin);
        nullWon.grantRole(lmRole, address(this));
```
- In `test_DepositReentrancyGuardFires` (894-916) delete the role grant (898-902).
- In `test_WithdrawReentrancyGuardFires` (924+) delete the role grant (928-933). (alice deposits permissionlessly.)

- [ ] **Step 4: Invariant + script tests — drop role references**

In `test/WrappedONInvariant.t.sol`:
- Delete the `getActors()` helper + its comment (70-74) — it becomes unused.
- In `setUp` delete the role-grant block (294-302, the `// M3 (#25)...` comment through the `for` loop that grants `lmRole` to each actor).

In `test/Script06Renounce.t.sol`:
- In `setUp` delete the `won.grantRole(won.LIQUIDITY_MANAGER_ROLE(), multisig);` (line 100) and adjust the comment on 97.
- Delete the partial-renounce test that expects `"multisig does NOT hold LIQUIDITY_MANAGER_ROLE yet (re-run TransferOwnership)"` (the function at ~147-157).

In `test/Script08Verify.t.sol`:
- Delete the two LIQUIDITY_MANAGER_ROLE tests (the `RoleNotRenounced("LIQUIDITY_MANAGER_ROLE", deployer)` partial-renounce test ~271-294 and the `RoleMissing("LIQUIDITY_MANAGER_ROLE", multisig)` test ~298-318). Any remaining `liquidityRole` setup in the surviving renounce-success test (line 253) must also be removed.

- [ ] **Step 5: Run the suite**

Run: `make fmt && make test`
Expected: PASS (130 tests). If any test still references `LIQUIDITY_MANAGER_ROLE`, the build fails to compile — grep `git grep -n LIQUIDITY_MANAGER_ROLE -- ':!docs' ':!*.md'` must return only removed-in-docs hits (none in `src/`, `script/`, `test/`).

- [ ] **Step 6: Commit**

```bash
git add src/ script/ test/
git commit -m "feat(won): make deposit permissionless, remove LIQUIDITY_MANAGER_ROLE"
```

---

## Task 2: Auto-unwrap native ON in `mint`

**Files:**
- Modify: `src/WrappedON.sol`
- Test: `test/WrappedON.t.sol`

**Interfaces:**
- Consumes: `WrappedON.mint(address,uint256)` (MINTER_ROLE), `WrappedON.ON`, `ccipMintHeadroomUsed`.
- Produces: `event CCIPAutoUnwrapped(address indexed account, uint256 amount)`; `mint` delivers native ON when `ON.balanceOf(this) >= amount`.

- [ ] **Step 1: Write the failing tests**

Add to the mint section of `test/WrappedON.t.sol`:
```solidity
    /// @notice Issue 1: reserve fully covers the CCIP arrival → mint() delivers native ON,
    ///         mints 0 wON, leaves the cap counter untouched.
    function test_MintAutoUnwrapsWhenReserveCovers() public {
        vm.startPrank(alice);
        on.approve(address(won), 100 ether);
        won.deposit(100 ether); // reserve = 100 ON, alice holds 100 wON
        vm.stopPrank();

        uint256 bobOnBefore = on.balanceOf(bob);
        uint256 supplyBefore = won.totalSupply();

        vm.expectEmit(true, false, false, true);
        emit WrappedON.CCIPAutoUnwrapped(bob, 40 ether);
        vm.prank(pool);
        won.mint(bob, 40 ether);

        assertEq(on.balanceOf(bob), bobOnBefore + 40 ether, "bob got native ON");
        assertEq(won.balanceOf(bob), 0, "no wON minted to bob");
        assertEq(won.totalSupply(), supplyBefore, "totalSupply unchanged");
        assertEq(won.ccipMintHeadroomUsed(), 0, "cap counter untouched");
        assertEq(on.balanceOf(address(won)), 60 ether, "reserve drained by 40");
    }

    /// @notice Issue 1: boundary — reserve == amount → full auto-unwrap.
    function test_MintAutoUnwrapsAtExactReserve() public {
        vm.startPrank(alice);
        on.approve(address(won), 50 ether);
        won.deposit(50 ether);
        vm.stopPrank();

        vm.prank(pool);
        won.mint(bob, 50 ether);

        assertEq(on.balanceOf(bob), 50 ether, "exact reserve delivered as ON");
        assertEq(won.balanceOf(bob), 0);
        assertEq(won.totalSupply(), 50 ether, "only alice's deposit-wON exists");
        assertEq(won.ccipMintHeadroomUsed(), 0);
    }

    /// @notice Issue 1: reserve < amount → falls back to minting wON (all-or-nothing).
    function test_MintMintsWonWhenReserveInsufficient() public {
        vm.startPrank(alice);
        on.approve(address(won), 30 ether);
        won.deposit(30 ether);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true);
        emit WrappedON.CCIPMinted(bob, 100 ether, 100 ether);
        vm.prank(pool);
        won.mint(bob, 100 ether);

        assertEq(won.balanceOf(bob), 100 ether, "wON minted (no partial unwrap)");
        assertEq(on.balanceOf(bob), 0, "no ON delivered");
        assertEq(on.balanceOf(address(won)), 30 ether, "reserve untouched");
        assertEq(won.ccipMintHeadroomUsed(), 100 ether, "cap counter incremented");
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-test "test_MintAutoUnwraps|test_MintMintsWonWhenReserveInsufficient" -vvv`
Expected: FAIL — `CCIPAutoUnwrapped` is undeclared / the covered-reserve cases mint wON instead of delivering ON.

- [ ] **Step 3: Implement auto-unwrap in the contract**

In `src/WrappedON.sol`, add the event near the other events (after `CCIPMinted`):
```solidity
    /// @notice Emitted by `mint` when the wrap reserve fully covers a CCIP arrival and native
    ///         ON is delivered instead of minting wON (issue #1). Mints 0 wON; cap untouched.
    event CCIPAutoUnwrapped(address indexed account, uint256 amount);
```

Replace the body of `mint` (currently lines 221-235) with:
```solidity
    function mint(address account, uint256 amount) external onlyRole(MINTER_ROLE) nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }
        // Auto-unwrap (issue #1, all-or-nothing): if the wrap reserve fully covers this CCIP
        // arrival, deliver native ON and mint 0 wON. The cap counter is untouched (nothing
        // minted); the safety invariant holds because BSC lock += amount and reserve -= amount
        // net out. A compromised pool can thus also drain the reserve — see SECURITY.
        uint256 reserve = ON.balanceOf(address(this));
        if (reserve >= amount) {
            ON.safeTransfer(account, amount);
            emit CCIPAutoUnwrapped(account, amount);
            return;
        }
        uint256 wouldBe = ccipMintHeadroomUsed + amount;
        if (wouldBe > MAX_CCIP_MINTED) {
            revert CCIPMintCapExceeded(MAX_CCIP_MINTED, wouldBe);
        }
        ccipMintHeadroomUsed = wouldBe;
        _mint(account, amount);
        emit CCIPMinted(account, amount, wouldBe);
    }
```
Update the `mint` NatSpec to note the auto-unwrap branch.

- [ ] **Step 4: Run to verify pass**

Run: `forge test --match-test "test_MintAutoUnwraps|test_MintMintsWonWhenReserveInsufficient" -vvv`
Expected: PASS. Then `make test` — all green (existing mint/cap tests run with reserve=0 so they keep minting wON unchanged).

- [ ] **Step 5: Commit**

```bash
git add src/WrappedON.sol test/WrappedON.t.sol
git commit -m "feat(won): auto-unwrap native ON on covered BSC->ETH arrivals"
```

---

## Task 3: Invariant test — auto-unwrap accounting

**Files:**
- Modify: `test/WrappedONInvariant.t.sol`

**Interfaces:**
- Consumes: handler ghost vars `totalDeposited`, `totalWithdrawn`, `bscLocked`.
- Produces: handler ghost var `totalAutoUnwrapped`.

- [ ] **Step 1: Add the auto-unwrap ghost var + handler accounting**

In the handler contract, declare alongside the other ghost vars:
```solidity
    uint256 public totalAutoUnwrapped;
```

Replace `ccipMint` (currently 112-124) with:
```solidity
    function ccipMint(uint256 actorSeed, uint256 amount) external {
        address user = _actor(actorSeed);
        uint256 cap = WON.MAX_CCIP_MINTED();
        uint256 headroom = cap - WON.ccipMintHeadroomUsed();
        if (headroom == 0) {
            return;
        }
        amount = _boundAmt(amount, headroom);
        // Simulated BSC lock — caps at BSC supply (MAX_CCIP_MINTED).
        bscLocked += amount;
        // Auto-unwrap (issue #1): if the reserve fully covers the arrival, mint() delivers
        // native ON from the reserve instead of minting wON. Track the reserve outflow so
        // invariant_ReserveMatchesNetDeposits stays exact.
        if (ON.balanceOf(address(WON)) >= amount) {
            totalAutoUnwrapped += amount;
        }
        vm.prank(POOL);
        WON.mint(user, amount);
    }
```

- [ ] **Step 2: Update the reserve invariant**

Replace `invariant_ReserveMatchesNetDeposits` (currently 372-379) with:
```solidity
    function invariant_ReserveMatchesNetDeposits() public view {
        uint256 reserve = onToken.balanceOf(address(won));
        assertEq(
            reserve,
            handler.totalDeposited() - handler.totalWithdrawn() - handler.totalAutoUnwrapped(),
            "invariant: reserve != deposits - withdrawals - auto-unwraps"
        );
    }
```
(The other three invariants are unaffected: `invariant_BackingCoversSupply` holds because lock +N and reserve −N cancel; `invariant_CounterBoundedByBscLocked` holds because auto-unwrap grows `bscLocked` without touching the counter; the cap invariant is untouched.)

- [ ] **Step 3: Run**

Run: `forge test --match-path 'test/WrappedONInvariant.t.sol' -vvv`
Expected: PASS (4 invariants over the handler actions, now including auto-unwrap).

- [ ] **Step 4: Commit**

```bash
git add test/WrappedONInvariant.t.sol
git commit -m "test(won): cover auto-unwrap in the stateful invariants"
```

---

## Task 4: Pool-level + fork auto-unwrap coverage

**Files:**
- Modify: `test/PoolRoundtrip.t.sol`, `test/fork/Fork_ETH.t.sol`

**Interfaces:**
- Consumes: `ethPool.releaseOrMint(...)`, `won.deposit`, mock `on`.

- [ ] **Step 1: Add a pool-level auto-unwrap test**

In `test/PoolRoundtrip.t.sol`, after `test_BscToEth_LockAndMint`, add (mirrors that test but seeds the reserve so the arrival auto-unwraps to native ON):
```solidity
    /// @notice Issue 1: when wON holds enough ON reserve, a BSC→ETH arrival delivers native
    ///         ON to the receiver (auto-unwrap) instead of minting wON.
    function test_BscToEth_AutoUnwrapWhenReserveCovers() public {
        uint256 amount = 1000 ether;

        // Seed the ETH reserve: alice deposits 1000 ON into wON (permissionless deposit).
        vm.startPrank(alice);
        onEth.approve(address(won), amount);
        won.deposit(amount);
        vm.stopPrank();
        uint256 supplyBefore = won.totalSupply();
        uint256 carolOnBefore = onEth.balanceOf(carol);

        Pool.ReleaseOrMintInV1 memory inMint = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(carol),
            remoteChainSelector: BSC_SELECTOR,
            receiver: carol,
            sourceDenominatedAmount: amount,
            localToken: address(won),
            sourcePoolAddress: abi.encode(address(bscPool)),
            sourcePoolData: "",
            offchainTokenData: ""
        });
        vm.prank(ethOffRamp);
        Pool.ReleaseOrMintOutV1 memory outMint = ethPool.releaseOrMint(inMint);

        assertEq(outMint.destinationAmount, amount);
        assertEq(onEth.balanceOf(carol), carolOnBefore + amount, "carol got native ON");
        assertEq(won.balanceOf(carol), 0, "no wON minted to carol");
        assertEq(won.totalSupply(), supplyBefore, "totalSupply unchanged (auto-unwrap)");
        assertEq(won.ccipMintHeadroomUsed(), 0, "cap untouched");
    }
```
NOTE: confirm the exact fixture names while editing (`onEth` vs `on`, presence of a `carol` actor, and whether `sourcePoolData` must equal a prior `outLock.destPoolData`). If the suite uses `on` for the ETH token or has no `carol`, adapt to the existing names; if `releaseOrMint` requires non-empty `sourcePoolData`, run `test_BscToEth_LockAndMint`'s lock first to obtain it (as that test does). The existing `test_BscToEth_LockAndMint` (reserve=0) stays unchanged and still mints wON.

- [ ] **Step 2: Add a fork auto-unwrap test**

In `test/fork/Fork_ETH.t.sol`, after `test_Fork_ETH_BscToEth_Mint`, add a sibling that seeds the reserve via `deal` and asserts native ON delivery:
```solidity
    /// @notice Issue 1 (fork): a covered BSC→ETH arrival delivers native ON, not wON.
    function test_Fork_ETH_BscToEth_AutoUnwrap() public {
        uint256 amount = 1000 ether;
        deal(ON_ETH, address(won), amount); // seed the wrap reserve with native ON

        uint256 supplyBefore = won.totalSupply();
        // Reuse the same ReleaseOrMintInV1 construction as test_Fork_ETH_BscToEth_Mint,
        // delivering to a fresh receiver; assert native ON instead of wON:
        address rcv = makeAddr("autoUnwrapReceiver");
        // ... build in1 exactly as in test_Fork_ETH_BscToEth_Mint but with receiver: rcv ...
        // vm.prank(ethOffRamp); ethPool.releaseOrMint(in1);
        // assertEq(IERC20(ON_ETH).balanceOf(rcv), amount);
        // assertEq(won.balanceOf(rcv), 0);
        // assertEq(won.totalSupply(), supplyBefore);
    }
```
Fill the `releaseOrMint` input by copying the exact `ReleaseOrMintInV1` struct from `test_Fork_ETH_BscToEth_Mint` (lines ~127-160), changing only `receiver` to `rcv`. Keep the assertions shown.

- [ ] **Step 3: Run**

Run: `make test-e2e` (PoolRoundtrip runs without RPC). Fork test self-skips without `ETH_RPC`; optionally `make test-fork ETH_RPC=<url> BSC_RPC=<url>`.
Expected: PASS / fork self-skip.

- [ ] **Step 4: Commit**

```bash
git add test/PoolRoundtrip.t.sol test/fork/Fork_ETH.t.sol
git commit -m "test(won): pool + fork coverage for auto-unwrap"
```

---

## Task 5: Docs + security record

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `RUNBOOK.md`, `docs/ARCHITECTURE.md`, `SECURITY.md`

- [ ] **Step 1: CLAUDE.md** — rewrite the two affected bullets:
  - "Roles on wON" (line 35): drop `LIQUIDITY_MANAGER_ROLE` entirely; keep MINTER/BURNER → pool and DEFAULT_ADMIN_ROLE handoff.
  - "Reserve invariant (wON)" #1 (line 43): `deposit(amount)` is **permissionless** (anyone wraps ON→wON); remove the M3/#25 role-gating sentence.
  - Add to the wON description: "On BSC→ETH, `mint` auto-unwraps — delivers native ON when the reserve fully covers the amount (all-or-nothing), else mints wON."
  - Line 48 (CCIP mint cap): remove "`LIQUIDITY_MANAGER_ROLE`-gated"; `deposit` is permissionless and uncapped.

- [ ] **Step 2: docs/ARCHITECTURE.md** — update the roles table (156-157: remove the `LIQUIDITY_MANAGER_ROLE` row; in `DEFAULT_ADMIN_ROLE` row drop it from the grant/revoke list), the function table (166: `deposit` access = "anyone"), and the `deposit` prose (49, 256). Add an auto-unwrap note to the BSC→ETH flow description.

- [ ] **Step 3: README.md** — line 251: remove the "`deposit` wrap path is gated to `LIQUIDITY_MANAGER_ROLE`" clause; state `deposit` is permissionless. Add a one-line note that BSC→ETH arrivals auto-unwrap to native ON when the reserve covers them.

- [ ] **Step 4: RUNBOOK.md** — lines 255, 321: remove the `LIQUIDITY_MANAGER_ROLE` grant/renounce from the handoff (§3) and renounce (§3.4) descriptions. Add an auto-unwrap note where the BSC→ETH flow is described.

- [ ] **Step 5: SECURITY.md** — update M3 (#25) entry (around 270-275): set **Status: REVERSED (2026-06-23) by product decision** — `deposit` is permissionless again; the `LIQUIDITY_MANAGER_ROLE` was removed. Keep the original description as history. Add two short notes (new IDs or appended to the trust-model section):
  - Permissionless deposit: wON supply / ETH→BSC redemption pressure is bounded only by ETH-side ON supply + CCIP pool rate limits.
  - Auto-unwrap reserve-drain: `mint` can move native ON out of the reserve, so a compromised `MINTER_ROLE` pool can drain the reserve in addition to minting wON (accepted under the trusted-pool model).

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md README.md RUNBOOK.md docs/ARCHITECTURE.md SECURITY.md
git commit -m "docs(won): permissionless deposit + auto-unwrap; reverse M3/#25"
```

---

## Task 6: Redeploy / re-wire runbook + STATE note

The contract change is complete; this records the operator steps for the fresh ETH redeploy + BSC lane re-wire (actual broadcasts are operator-run post-merge, keystore-signed, deployer in control).

**Files:**
- Modify: `RUNBOOK.md`, `STATE.md`

- [ ] **Step 1: RUNBOOK.md** — add a "Redeploy (new wON)" subsection capturing:
  1. ETH: `make deploy-eth RPC=eth` deploys new wON + new `BurnMintTokenPool`, grants roles, registers the new wON CCIP admin + `setPool`, wires the BSC remote (scripts 01→05).
  2. BSC: re-wire the ETH lane of the existing `LockReleaseTokenPool` — remove the old ETH-lane config and add the new ETH pool (`remotePoolAddresses`) + new wON (`remoteTokenAddress`), same rate limits (script 05 re-run). Do NOT re-run BSC script 04 (avoids the path-4 blocker).
  3. Optional: `setPool(oldWON, address(0))` to deregister the orphaned old wON in `TokenAdminRegistry`.
  4. `make verify-eth` / `make verify-bsc`.

- [ ] **Step 2: STATE.md** — add a dated note that wON was redeployed for auto-unwrap + permissionless deposit; mark the deployed-contracts table addresses as pending update post-broadcast (the new wON + new ETH pool addresses get filled in after the deploy).

- [ ] **Step 3: Commit**

```bash
git add RUNBOOK.md STATE.md
git commit -m "docs(ops): redeploy + BSC re-wire runbook for new wON"
```

---

## Task 7: Final verification gate

- [ ] **Step 1: Full suite + format**

Run: `make fmt-check && make test`
Expected: `make test` green (130 tests). If `fmt-check` fails, run `make fmt` and amend.

- [ ] **Step 2: Confirm no stray role references in code**

Run: `git grep -n "LIQUIDITY_MANAGER_ROLE" -- 'src' 'script' 'test'`
Expected: no output.

- [ ] **Step 3: Confirm the build**

Run: `forge build`
Expected: exit 0.

---

## Self-review notes

- **Spec coverage:** auto-unwrap in `mint` (Task 2); permissionless deposit + role removal (Task 1); invariant accounting (Task 3); pool/fork coverage (Task 4); docs + M3 reversal + reserve-drain note (Task 5); clean redeploy + BSC re-wire (Task 6). All spec sections mapped.
- **Cap semantics:** auto-unwrap leaves `ccipMintHeadroomUsed` untouched (Task 2 Step 3) — matches the spec.
- **Build-green ordering:** the role constant is removed across all referencing files in one task (Task 1) so the project always compiles.
- **Existing-test stability:** existing mint/cap/burn tests and `test_BscToEth_LockAndMint` run with reserve=0, so they keep minting wON unchanged; auto-unwrap is covered by new tests that first seed the reserve.
- **Type consistency:** new symbols — `event CCIPAutoUnwrapped(address indexed,uint256)`, handler `uint256 public totalAutoUnwrapped` — are referenced consistently across Tasks 2-4.
