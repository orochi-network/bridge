# Production Deployment Runbook — ON Bridge

This walks the deploy + handoff sequence end to end. Run on **testnet first** (Sepolia ⇄ BSC Testnet), then mainnet. Most steps are idempotent — scripts 03 (role grants), 04 (registry), 05 (chain wiring), and 06 (handoff + renounce) either no-op or fast-fail when re-run. Scripts 01 and 02 are also idempotent **on a chain that already has a `deployments/<chainId>.json` entry for the artifact**: they skip + log rather than re-deploying. To force a redeploy, delete the corresponding entry from `deployments/<chainId>.json`.

---

## 0. Pre-flight (one-time)

### 0.1 Fill in CCIP infrastructure addresses

Edit `script/Helper.sol` for **each chain** you'll deploy on. The address fields are intentional `address(0)` placeholders; fill them in from the [CCIP directory](https://docs.chain.link/ccip/directory):

- `router`
- `rmnProxy`
- `tokenAdminRegistry`
- `registryModuleOwnerCustom`
- `linkToken`

Chain selectors are already committed and should not need changes.

**Directory lookup.** Open the [CCIP directory](https://docs.chain.link/ccip/directory),
select the **Mainnet** (or Testnet) tab and the target network (e.g. *Ethereum*,
*BNB Smart Chain*). Each network page lists the **Router**, **RMN/ARM proxy**,
**TokenAdminRegistry**, **RegistryModuleOwnerCustom**, **LINK token**, and the
**chain selector**. Copy those into the matching `chainId` branch of `Helper.sol`.
Cross-check the chain selector against the constant already committed there.

**Validate before broadcasting (issue #21).** Two layered checks:

```bash
make precheck-helper RPC=<target>   # pure: every Helper address for this chain + its remote is non-zero
make validate-config RPC=<target>   # live: staticcalls each address on-chain to confirm it is the
                                    #       expected CCIP contract (typeAndVersion), that the router
                                    #       supports the remote lane (chain selector is real), and that
                                    #       LINK / canonical-ON look right. Reverts listing any mismatch.
```

`validate-config` is view-only and never broadcasts. Run it once per chain after
filling `Helper.sol`; a green result means the addresses point at genuine CCIP
infrastructure on the target network before you spend gas.

### 0.2 Confirm the BSC ON token admin path

The deployer needs to be able to register as admin for the canonical ON on BSC (`0x0e4F6209eD984b21EDEA43acE6e09559eD051D48`). `script/04_RegisterAdminAndPool.s.sol` probes four paths in order:

1. `IGetCCIPAdmin.getCCIPAdmin()` returns the deployer — script auto-uses `registerAdminViaGetCCIPAdmin`.
2. `Ownable.owner()` returns the deployer — script auto-uses `registerAdminViaOwner`.
3. OZ `AccessControl.hasRole(DEFAULT_ADMIN_ROLE, deployer)` on the v1.6 registry path — script auto-uses `registerAccessControlDefaultAdmin`.
4. None of the above — the script reverts with a `CannotResolveCCIPAdmin` diagnostic. Recovery requires either (a) the token's `Ownable.owner` calling `RegistryModuleOwnerCustom.registerAdminViaOwner(token)` themselves, or (b) coordinating with Chainlink to register the admin out-of-band. After admin is set, re-run script 04 — `acceptAdminRole` and `setPool` are idempotent.

**Required: validate the path against live BSC state BEFORE broadcasting (`TEST-7` — legacy audit tag H-4).** The MEV / front-running window on `TokenAdminRegistry.proposeAdministrator` is closed if you already know the path resolves to a permissionless on-chain branch (1, 2, or 3); it stays open if recovery has to go through path 4.

One-command probe (issue #22) — runs the same path resolution as script 04, read-only, no broadcast:

```bash
DEPLOYER=0x<your deployer EOA> make validate-bsc-admin RPC=<bsc rpc>
# testnet: point at your mock ON — BSC_ON=0x<mock> DEPLOYER=0x<eoa> make validate-bsc-admin RPC=<bsc_testnet rpc>
```

It prints each path and, with `DEPLOYER` set, reverts on the path-4 fallthrough so it can gate a deploy. The raw `cast` equivalents below remain for manual checks.

> **Confirmed live result (BSC mainnet `0x0e4F…1D48`, probed 2026-06-01):** the canonical ON token resolves to **path 4** *for any deployer* — `getCCIPAdmin()` is absent, `owner()` returns the **zero address** (ownership renounced, so `registerAdminViaOwner` is unusable — there is no owner to call it), and OZ `AccessControl.hasRole` is absent. **Script 04 will revert (`CannotResolveCCIPAdmin`) on BSC mainnet.** CCIP-admin registration for the BSC ON token therefore requires coordinating with Chainlink (the `TokenAdminRegistry` owner) to register the administrator out-of-band *before* the BSC deploy — there is no permissionless on-chain branch available. Re-confirm with `make validate-bsc-admin` at deploy time in case the token's ownership/roles change. See SECURITY `TEST-7`.

Use `cast call` to read each path's discriminator against the live BSC RPC and compare against the deployer EOA. This is purely read-only — no fork, no broadcast, no key needed. Script 04's path probes test whether **the broadcaster** is the admin holder, so the question to answer here is "would `$DEPLOYER_ADDR` match any of paths 1/2/3?" (an earlier draft of this section used `anvil --fork-url` with a well-known anvil pre-funded key, but the anvil key isn't `$DEPLOYER_ADDR`, so on a fork the script always fell through to path-4 regardless of which path the real deployer would have hit on mainnet — invalidating the mitigation goal):

```bash
DEPLOYER_ADDR=$(cast wallet address --account deployer)   # your deployer EOA
BSC_ON=0x0e4F6209eD984b21EDEA43acE6e09559eD051D48

# Path 1 — does the token expose getCCIPAdmin() and does it return the deployer?
cast call $BSC_ON 'getCCIPAdmin()(address)' --rpc-url $BSC_RPC 2>&1 || echo "selector absent (path 1 unavailable)"

# Path 2 — is the token Ownable and is owner() the deployer?
cast call $BSC_ON 'owner()(address)' --rpc-url $BSC_RPC 2>&1 || echo "selector absent (path 2 unavailable)"

# Path 3 — does the token use OZ AccessControl, and does the deployer hold DEFAULT_ADMIN_ROLE?
cast call $BSC_ON 'hasRole(bytes32,address)(bool)' \
    0x0000000000000000000000000000000000000000000000000000000000000000 \
    $DEPLOYER_ADDR --rpc-url $BSC_RPC 2>&1 || echo "selector absent (path 3 unavailable)"
```

Compare the path-1 / path-2 returns to `$DEPLOYER_ADDR` (case-insensitive) and check path-3 for `true`. If any of the three matches, script 04 will land on that branch on mainnet — no front-running window. If none match, the path-4 fallthrough is your reality: coordinate recovery with the ON token owner (so they call `RegistryModuleOwnerCustom.registerAdminViaOwner(token)` for you) or Chainlink (out-of-band admin set) *before* mainnet broadcast — do not run script 04 against mainnet hoping it works.

**Also confirm BSC ON has no mint capability (OPS-29).** The bridge's `MAX_CCIP_MINTED = 100M` assumes the canonical BSC ON supply is fixed at 100M. If BSC ON has a minter and supply ever exceeds 100M, the cap becomes an asymmetric ceiling: excess BSC ON can be locked but cannot reflect to ETH (`mint` reverts `CCIPMintCapExceeded`), permanently stranding users with the surplus.

```bash
# Probe likely mint surfaces. Each is expected to revert ("selector absent") on a
# correctly fixed-supply ERC20.
cast call $BSC_ON 'mint(address,uint256)' $DEPLOYER_ADDR 1 --rpc-url $BSC_RPC 2>&1 || echo "no mint(address,uint256) — good"
cast call $BSC_ON 'owner()(address)' --rpc-url $BSC_RPC 2>&1 || echo "no Ownable owner — owner-gated mint surface absent"
# Spot the current totalSupply against the documented 100M:
cast call $BSC_ON 'totalSupply()(uint256)' --rpc-url $BSC_RPC
```

If any mint surface is present and gated to an address that could plausibly mint more, halt the deployment — the cap-vs-supply relationship is load-bearing for the entire CCIP-7 / cap-replenishment safety story.

**Auto-unwrap on BSC→ETH arrivals.** When a BSC→ETH CCIP message arrives, `WrappedON.mint`
first checks whether `ON.balanceOf(wON) >= amount` (the ETH-side reserve). If so, it
transfers native ON directly to the receiver (all-or-nothing) and emits `CCIPAutoUnwrapped`
without incrementing `ccipMintHeadroomUsed` — the receiver gets canonical ETH ON, not wON.
If the reserve does not cover the full amount, it falls through to the standard wON mint
path. Operators should expect `CCIPAutoUnwrapped` events during normal operation whenever
the reserve holds sufficient ON; this is expected and benign.

**Incident response: an inbound CCIP message reverting with `CCIPMintCapExceeded`.** The mint
cap makes `WrappedON.mint` — and therefore the offRamp's `releaseOrMint` — revert once
`ccipMintHeadroomUsed + amount > MAX_CCIP_MINTED`. Treat this as a **deliberate fail-safe trip,
not a transient.** CCIP will surface the message as failed-execution and allow manual
re-execution, but the retry calls the same `mint` and will keep reverting until
`ccipMintHeadroomUsed` drops below the cap (i.e. until matching wON is burned/bridged out on
ETH). Under honest operation this is unreachable: only 100M ON exists on BSC,
`ccipMintHeadroomUsed ≈ lockedON_BSC ≤ 100M`, and burns saturating-decrement the counter. So a
live `CCIPMintCapExceeded` on an inbound message means one of: (a) BSC ON supply exceeded
100M (OPS-29 above — the surplus is stranded by design), or (b) the ETH pool minted without
a matching BSC lock (compromise/bug — the cap is the circuit-breaker that stopped it). In
both cases do **not** treat the stuck message as a delivery bug to force through; page the
on-call rotation and reconcile `ccipMintHeadroomUsed` against
`IERC20(ON).balanceOf(BSC_LockReleaseTokenPool)` before any manual re-execution.

### 0.3 Environment

Copy `.env.example` → `.env` and fill in:

```bash
ETH_RPC=https://...
SEPOLIA_RPC=https://...
BSC_RPC=https://...
BSC_TESTNET_RPC=https://...
ETHERSCAN_API_KEY=...
BSCSCAN_API_KEY=...
```

Then `source .env`.

**Key-handling note:** signing is via a Foundry encrypted keystore account, so no raw private key is ever passed on the CLI or stored in `.env`. Create the keystore once with `cast wallet import deployer --interactive`; the `make deploy-*` / `make update-limits` targets then sign with `--account deployer` (override with `ACCOUNT=<name>`) and forge prompts for the keystore password per broadcast. The deployer EOA holds critical authority throughout the handoff window.

### 0.4 Build & test locally

```bash
make build
make test                 # all 130 non-fork tests (126 unit/integration + 4 stateful invariants) must pass
make fmt-check
```

### 0.5 Verify external documentation links (issue #20)

Chainlink restructures `docs.chain.link` periodically — pages move and the old
URLs 404 silently (this happened to the legacy
`/ccip/concepts/cross-chain-token/{token-pools,tokens,registration-and-administration}`
paths). Before tagging a release, confirm every Chainlink URL referenced in the
tracked docs and scripts still resolves:

```bash
make check-links          # curls each https://docs.chain.link/... URL; exits non-zero on any non-200
```

If a link fails, find the current page from the [CCIP docs](https://docs.chain.link/ccip)
and update the referencing source file. This check is network-dependent and is
deliberately **not** part of PR CI (it would be flaky); treat it as a release gate.

---

## 1. Testnet deployment

### 1.0 Deploy a mock ON token (testnet only — OPS-23)

`script/Helper.sol` intentionally leaves `onToken: address(0)` for Sepolia (chainid `11_155_111`) and BSC testnet (chainid `97`), because there is no canonical ON deployed on those chains. Scripts 01 / 02 `_requireSet` the `onToken` field, so without a stand-in the documented `make deploy-eth RPC=sepolia` / `make deploy-bsc RPC=bsc_testnet` flows revert immediately with `MissingAddress("onToken (...)")`.

Before running the deploy targets on testnet, deploy a simple `MockERC20("Orochi Network (Testnet)", "ON", 18)` and patch `script/Helper.sol` with its address on the matching chainid branch:

```bash
# Example: deploy your own MockERC20 (use `forge create`, your existing mock, or any
# OZ ERC20Mock). The exact deploy mechanism is intentionally out of scope — testnet
# deploys are not bridge-funds-bearing.
forge create test/mocks/MockON.sol:MockON \
    --rpc-url sepolia \
    --account deployer \
    --constructor-args "Orochi Network (Testnet)" "ON"
# Take the printed Deployed-to address and patch `script/Helper.sol` so the
# chainid 11_155_111 / 97 branch returns it under `onToken`. Then proceed to §1.1.
```

This step is a no-op on mainnet — Helper's `1` / `56` branches already point at the canonical addresses. (`OPS-23` tracks a future `script/00_DeployMockON.s.sol` that automates this; until then it's a manual step.)

### 1.1 Ethereum (Sepolia)

```bash
make deploy-eth RPC=sepolia
```

This runs 01 → 02 → 03 → 04 → 05 in sequence. Writes addresses to `deployments/11155111.json`.

### 1.2 BSC (testnet)

```bash
make deploy-bsc RPC=bsc_testnet
```

Runs 02 → 04 → 05. (01 and 03 are skipped — wON only exists on ETH.) Writes `deployments/97.json`.

### 1.3 Verify both sides

```bash
make verify-eth RPC=sepolia
make verify-bsc RPC=bsc_testnet
```

Script 08 (`PostDeployVerify`) is view-only and reverts loudly on any wiring mismatch. Expect all green checkmarks.

### 1.4 Smoke test via CCIP Explorer

1. Send 1 ON BSC Testnet → Sepolia via the CCIP Explorer UI (or scripted `IRouterClient.ccipSend`).
2. Confirm on https://ccip.chain.link/ that the message is delivered and the recipient on Sepolia receives 1 wON.
3. (Optional) On Sepolia, call `wON.withdraw(1 ether)` — fails unless reserve has 1 ON, which is expected for an unfunded testnet wrapper.
4. Reverse direction. Wrap 1 ON on Sepolia via `wON.deposit`, bridge to BSC Testnet, confirm 1 native ON received.

---

## 2. Mainnet deployment

### 2.1 Re-verify infrastructure addresses

CCIP infrastructure addresses on mainnet can change. Re-confirm against the [CCIP directory](https://docs.chain.link/ccip/directory) and update `Helper.sol` if needed, then re-run `make validate-config RPC=<mainnet>` (see §0.1) so the live staticcall check passes against mainnet before broadcasting.

### 2.2 Calibrate rate limits

Default in script 05 is 100,000 ON capacity + 10 ON/sec (~864k/day). Confirm with ops or adjust the constants in `script/05_ApplyChainUpdates.s.sol` before broadcasting.

### 2.3 Deploy

```bash
make deploy-eth RPC=eth
make deploy-bsc RPC=bsc
```

### 2.4 Verify

```bash
make verify-eth RPC=eth
make verify-bsc RPC=bsc
```

### 2.5 Mainnet smoke test

Bridge a small amount in each direction. Use a private wallet — this confirms the lane works under production conditions. Document the test transaction hashes.

---

## 3. Ownership handoff to multisig

Once the bridge is verified on mainnet, hand off control to the operations multisig (Gnosis Safe recommended).

### 3.1 Begin handoff (deployer EOA)

```bash
make handoff-all ETH_RPC=eth BSC_RPC=bsc MULTISIG=0x<safe-address>
```

The single target runs the handoff sequentially against both chains with the same multisig — preventing the half-handed-off-on-one-chain footgun (legacy audit tag H-5, now operational mitigation only — no current ledger entry). For single-chain handoffs (e.g. during testnet dry runs) use `make handoff RPC=<chain> MULTISIG=…`.

Each per-chain invocation:
- Calls `pool.transferOwnership(multisig)` (two-step Ownable).
- (ETH only) Grants wON `DEFAULT_ADMIN_ROLE` to the multisig and proposes the new CCIP admin (two-step — multisig must call `acceptCCIPAdmin`). The deployer renounces `DEFAULT_ADMIN_ROLE` in 3.4. Note: `deposit` is permissionless — there is no `LIQUIDITY_MANAGER_ROLE` to grant or manage.
- Calls `TokenAdminRegistry.transferAdminRole(token, multisig)` (two-step).

**Minimize the handoff window (`DEP-3` + `CCIP-1` — legacy audit tags H-2 + C-1).** Between the grant in 3.1 and the multisig accepts in 3.2, the deployer EOA still holds:
- wON `DEFAULT_ADMIN_ROLE` on ETH → admin authority over `MINTER_ROLE` / `BURNER_ROLE` (a compromised deployer key can grant `MINTER_ROLE` to an attacker and mint unbacked wON).
- `Ownable` ownership of the BSC `LockReleaseTokenPool` → can call `setRebalancer(attacker)` → `withdrawLiquidity` and drain the locked-ON reserve (the `CCIP-1` trust-model surface; the multisig isn't yet the owner until 3.2 BSC `acceptOwnership`).

To reduce exposure:

1. Have the multisig signers staged and ready before running `make handoff-all`.
2. Queue the 3.2 accept transactions in the Safe UI immediately after 3.1 completes — **all of them**, both chains. The BSC handoff completes when the multisig accepts `pool.acceptOwnership` in 3.2 (BSC has no separate renounce step; `make renounce` in 3.4 only renounces wON `DEFAULT_ADMIN_ROLE` on ETH).
3. Run `make renounce` (3.4) as soon as 3.2 + 3.3 confirm. Aim for hours, not days, between grant and renounce on ETH; the BSC window closes earlier (at 3.2 acceptance).
4. **Monitor while the handoff is in flight on both chains.** ETH-side: page on `RoleGranted(MINTER_ROLE, *)` / `RoleGranted(BURNER_ROLE, *)` on wON whose grantee is not the BurnMintTokenPool. BSC-side: page on `LiquidityRemoved(*, *)` and `OwnershipTransferRequested(*, *)` on the LockReleaseTokenPool, plus the `RebalancerSet(oldRebalancer, newRebalancer)` event (CCIP 1.6.1 emits this on every `setRebalancer` call — subscribe to the log; no calldata trace needed). See [Trust model](#trust-model-bsc-reserve-custody) for the full monitoring table.

### 3.2 Multisig accepts (from the Safe UI / SDK)

Queue these transactions on the multisig:

| Chain | Transaction |
|---|---|
| ETH   | `pool.acceptOwnership()` on the BurnMintTokenPool |
| ETH   | `registry.acceptAdminRole(wON)` on TokenAdminRegistry |
| ETH   | `wON.acceptCCIPAdmin()` (completes the two-step CCIP admin transfer) |
| BSC   | `pool.acceptOwnership()` on the LockReleaseTokenPool |
| BSC   | `registry.acceptAdminRole(ON_BSC)` on TokenAdminRegistry |

**Verify each transaction before signing** (SECURITY: OPS-10). Each of these accepts moves
custody-grade authority, especially the BSC `pool.acceptOwnership` (controls `setRebalancer`
→ `withdrawLiquidity` over the entire locked-ON reserve). Before any signer signs:

1. Confirm the **target address** in the Safe UI's transaction preview matches the address
   recorded in `deployments/<chainId>.json` (`pool`, `wrappedON`) on the corresponding chain.
2. Use the Safe UI's **built-in simulation** (or [Tenderly](https://tenderly.co)) to
   simulate each transaction. Look for the expected state changes:
   `acceptOwnership` flips `owner` to the multisig; `acceptAdminRole` flips the registry
   administrator; `acceptCCIPAdmin` flips `getCCIPAdmin()` to the multisig.
3. After all accepts have executed, run `MULTISIG=0x.. make verify-eth RPC=eth` and the
   BSC equivalent to programmatically confirm the post-state.

A typo'd target won't be caught by the multisig threshold itself — `acceptOwnership` on
the wrong pool just reverts ("not pending owner") and burns gas, but a structurally
similar surface (e.g. another deployed pool the deployer accidentally referenced) would
silently land. Simulation is the only step that catches this before signatures.

### 3.3 Re-verify with `MULTISIG` env var set

```bash
MULTISIG=0x<safe-address> make verify-eth RPC=eth
MULTISIG=0x<safe-address> make verify-bsc RPC=bsc
```

This adds an ownership-handoff check: `pool.owner() == multisig` on each chain.

### 3.4 Deployer renounces wON admin role (ETH only)

After 3.2 + 3.3 confirm the multisig holds every role:

```bash
make renounce RPC=eth MULTISIG=0x<safe-address>
```

The script now pre-asserts (`DEP-3` — legacy audit tag H-1):
- Multisig holds `DEFAULT_ADMIN_ROLE` on wON.
- Multisig is `getCCIPAdmin()` (i.e. it called `acceptCCIPAdmin`).
- The deployer still holds the role at call time.

Then calls `won.renounceRole(DEFAULT_ADMIN_ROLE, deployer)`. After this point, only the multisig can grant/revoke wON roles. `deposit` is permissionless — no liquidity-manager role exists. **Do not skip this step.**

---

## 4. Post-launch operations

### 4.1 Updating rate limits

```bash
# Pre-handoff (deployer still owns the pool):
make update-limits RPC=eth \
    OUTBOUND_CAPACITY=200000000000000000000000 \
    OUTBOUND_RATE=20000000000000000 \
    INBOUND_CAPACITY=200000000000000000000000 \
    INBOUND_RATE=20000000000000000

# Post-handoff (delegated rateLimitAdmin via §4.1.1, or any account other than the deployer):
CALLER_FLAGS='--account ratelimit-admin' \
make update-limits RPC=eth \
    OUTBOUND_CAPACITY=200000000000000000000000 \
    OUTBOUND_RATE=20000000000000000 \
    INBOUND_CAPACITY=200000000000000000000000 \
    INBOUND_RATE=20000000000000000
```

(All values in wei. Above = 200,000 cap, 0.02 ON/sec rate.) Caller must be the pool owner (the multisig) or the rate-limit admin. SECURITY: OPS-2 — `make update-limits` falls back to the deployer keystore account (`--account deployer`) only when `CALLER_FLAGS` is unset; after handoff the deployer is unauthorised on the pool and the transaction would revert. Either set `CALLER_FLAGS` to a delegated credential (preferred) or queue the equivalent `setChainRateLimiterConfig` call from the multisig directly.

**CCIP validation rules** (mirror these — the preflight in script 07 enforces them so a mid-broadcast revert is impossible):
- `isEnabled = true` requires `rate > 0` AND `rate < capacity` (strict — `rate == capacity` is rejected).
- `isEnabled = false` requires `capacity == 0` AND `rate == 0` (the only valid disabled-state).

### 4.1.1 Optional: delegate rate-limit admin

Chainlink CCT best practice (per https://docs.chain.link/ccip/concepts/best-practices/evm) is to limit privileges by assigning specific roles like the `rateLimitAdmin` rather than full owner access. `TokenPool.setRateLimitAdmin(addr)` (`onlyOwner`) designates a separate address that can call `setChainRateLimiterConfig` without being the pool owner. Operators may want to do this once post-handoff so a hot-key EOA can tune rate limits without going through the cold-storage multisig each time:

```solidity
// Multisig action:
pool.setRateLimitAdmin(<hot-key-address>);
```

Pool ownership and reserve custody (BSC `setRebalancer`) remain with the multisig. Only rate-limit config delegation moves to the hot key.

### 4.2 Responding to an RMN curse

If RMN curses the lane, all transfers automatically halt. There is no operator-side action needed beyond:
1. Confirm via the [CCIP Explorer](https://ccip.chain.link/) that the curse is active.
2. Coordinate with Chainlink ops to resolve the underlying incident.
3. Once uncursed, transfers resume automatically.

### 4.3 Migration / re-deploy

These contracts are non-upgradeable. To replace a pool:
1. Deploy new pool with the same wON / ON token.
2. Multisig: `wON.grantRole(MINTER_ROLE, newPool)` + `BURNER_ROLE` (ETH side).
3. Multisig: `registry.setPool(token, newPool)` on the affected chain.
4. Multisig: `applyChainUpdates` on the new pool to link the remote.
5. Drain the old pool. The locked-ON reserve on the BSC `LockReleaseTokenPool` is movable by the pool owner via `setRebalancer` → `withdrawLiquidity` (see [Trust model](#trust-model-bsc-reserve-custody) below). Either rebalance manually under multisig governance, or — preferred — plan migrations such that net positions are zero before swapping so no reserve movement is needed.

### 4.4 Stuck or delayed ETH→BSC transfers (insufficient BSC liquidity)

**This is the QuillAudits M2 scenario** (SECURITY: CCIP-2 / M2). An ETH→BSC
transfer burns wON on Ethereum the moment the source message is accepted; the
matching ON is only released on BSC when CCIP executes `releaseOrMint` on the
BSC `LockReleaseTokenPool`. That release is a plain `ON.safeTransfer` out of the
pool's own balance, so if the pool's releasable ON balance is below the transfer
amount the **destination execution reverts on insufficient liquidity** and the
message does not complete. The Ethereum burn has already happened, so the user's
value is *in flight*, not lost — it completes once liquidity is restored and the
message is re-executed. The aggregate invariant
`lockedON_BSC + reserveON_ETH >= totalSupply(wON)` holds throughout.

Because the Ethereum contracts cannot read BSC balances synchronously (see
[Trust model](#trust-model-bsc-reserve-custody)), there is **no on-chain fix on
the Ethereum side** — this is enforced operationally.

**Prevention (at launch and on every rate-limit change):**
- Size the **ETH→BSC (BSC-inbound) rate-limit** bucket so its capacity never
  exceeds the BSC pool's releasable ON balance minus a safety buffer — the
  outbound burst the ETH side will accept must be releasable on BSC. This is the
  asymmetry `CCIP-2` warns about; do not leave limits symmetric if BSC liquidity
  is thin. Tune via `make update-limits` (§4.1).
- Keep the §3 monitoring alert live: page when
  `BSC_ON.balanceOf(BSC_LockReleaseTokenPool)` falls below the configured ETH→BSC
  rate-limit capacity plus buffer.

**Recovery (a transfer is already stuck):**
1. Confirm on the [CCIP Explorer](https://ccip.chain.link/) — a stuck ETH→BSC
   message shows the destination execution failing on an insufficient-liquidity
   revert.
2. Replenish the BSC pool. **`provideLiquidity` is disabled on this deployment**
   (CCIP 1.6.1 has no `acceptLiquidity` flag; with no rebalancer set, the call
   reverts `Unauthorized`), so the rebalancer path cannot be used. Restore
   releasable liquidity by transferring ON **directly to
   the BSC `LockReleaseTokenPool` address** from the operator reserve / multisig:
   `releaseOrMint` and `withdrawLiquidity` both read the pool's raw `balanceOf`,
   so a direct ERC-20 transfer is immediately releasable and remains withdrawable
   later. (Organic BSC→ETH bridging also refills the pool.)
3. Re-run the message via CCIP [manual execution](https://docs.chain.link/ccip/concepts/manual-execution)
   from the Explorer once liquidity is present; the pending `releaseOrMint` then
   succeeds and the receiver gets their ON.
4. Post-incident: lower the ETH→BSC rate-limit capacity (§4.1) so accepted
   outbound volume cannot again outrun BSC liquidity.

---

## Trust model: BSC reserve custody

Chainlink's `LockReleaseTokenPool` is built around a trusted-operator pattern. After ownership handoff, the BSC pool's `owner` (the ops multisig) can:

- Call `setRebalancer(addr)` (`onlyOwner`) — designates which address may move the locked-ON reserve.
- The designated rebalancer can call `provideLiquidity(amount)` and `withdrawLiquidity(amount)` (both revert `Unauthorized` unless `msg.sender == s_rebalancer`). `transferLiquidity(from, amount)` is `onlyOwner`, but it only PULLS liquidity *into* this pool from a `from` pool that has set this pool as its rebalancer (it calls `from.withdrawLiquidity`) — it cannot extract this pool's own reserve. CCIP 1.6.1 removed the `acceptLiquidity` flag, and we deploy with **no rebalancer set**, so the locked-ON reserve is not movable out by anyone until the owner calls `setRebalancer`.

This means the multisig effectively has custody of the BSC-side locked-ON reserve. This is the **documented Chainlink CCT pattern** for `LockReleaseTokenPool` and is intentional.

**Required monitoring** (set up an off-chain alert before mainnet handoff):

| Event / call | Where | Severity |
|---|---|---|
| `LiquidityRemoved(remover, amount)` | BSC pool | **Critical** |
| `LiquidityAdded(provider, amount)` | BSC pool | High |
| `RebalancerSet(oldRebalancer, newRebalancer)` event (CCIP 1.6.1 — `setRebalancer`) | BSC pool | **Critical** |
| `RateLimitAdminSet(rateLimitAdmin)` event (CCIP 1.6.1 — `setRateLimitAdmin`; OPS-28) | both pools | High |
| `OwnershipTransferRequested` / `OwnershipTransferred` | BSC pool | **Critical** |
| `RouterUpdated(oldRouter, newRouter)` (CCIP-13) | both pools | **Critical** |
| `RemotePoolSet(selector, oldRemote, newRemote)` (CCIP-14) | both pools | **Critical** |
| `ChainAdded` / `ChainRemoved` / `ChainConfigured` (CCIP-14) | both pools | High |
| `RoleGranted(MINTER_ROLE, *)` where grantee ≠ ETH pool | wON | **Critical** |
| `RoleGranted(BURNER_ROLE, *)` where grantee ≠ ETH pool | wON | **Critical** |
| `RoleAdminChanged(role, prev, new)` on `MINTER_ROLE`/`BURNER_ROLE` (OPS-30; forward-compat) | wON | High |
| `CCIPAdminTransferProposed` / `CCIPAdminTransferred` | wON | High |
| `AdministratorTransferRequested` / `AdministratorTransferred` (registry — OPS-28) | TokenAdminRegistry | High |
| `CCIPMinted` cumulative > BSC `IERC20(ON).balanceOf(LockReleaseTokenPool)` | wON ↔ BSC pool | **Critical** |
| `BSC_ON.balanceOf(BSC pool)` < ETH→BSC rate-limit capacity + buffer (M2 / CCIP-2 — stuck-transfer precursor; see §4.4) | BSC pool ↔ ETH pool config | High |
| `CCIPAdminProposalCancelled` | wON | High |
| Outbound / inbound rate-limit bucket exhausted | both pools | Medium |

**Rationale for the post-handoff additions (round-8 review):**

- `RouterUpdated` (CCIP-13) — `TokenPool.setRouter(addr)` is `onlyOwner`. A compromised
  multisig can swap `s_router` to attacker-controlled logic; `_onlyOnRamp` /
  `_onlyOffRamp` then defer to the new router's `getOnRamp` / `isOffRamp`, opening both
  `lockOrBurn` (drains BSC reserve) and `releaseOrMint` (mints unbacked wON up to cap).
  Direct analog of `setRebalancer` for routing.
- `RemotePoolSet` (CCIP-14) — alters the source-pool keccak the destination uses to
  validate inbound mints. Door to forged-source mints if compromised.
- `ChainAdded` / `ChainRemoved` / `ChainConfigured` (CCIP-14) — rate-limit reset / new
  selector wired in. Less catastrophic than RouterUpdated/RemotePoolSet but worth a page.
- `RateLimitAdminSet(rateLimitAdmin)` event (OPS-28) — `onlyOwner`; CCIP 1.6.1 emits this
  on `setRateLimitAdmin`, so subscribe to the log. §4.1.1 recommends delegating to a hot key,
  so this is a legitimate operational call — but it should be a signal you can correlate with
  a multisig action you know about.
- `AdministratorTransferRequested`/`Transferred` on `TokenAdminRegistry` (OPS-28) — the
  registry sibling of `CCIPAdminTransferProposed`/`Transferred` on wON; previously only
  the wON half was monitored.
- `RoleAdminChanged` on `MINTER_ROLE`/`BURNER_ROLE` (OPS-30) — forward-compat. wON does
  not currently expose `_setRoleAdmin` externally (OZ AccessControl 5.x internal), so
  not an active vector — but if a future redeploy ever does, the monitor is in place.

**Note on `ccipMintHeadroomUsed` monitoring** (SECURITY: WON-3 / CCIP-7). CCIP pairs every
BSC `lock`/`release` 1:1 with an Ethereum `mint`/`burn`, so the ON locked on BSC *via CCIP*
equals the wON minted on Ethereum *via CCIP* — but that equality is enforced by Chainlink
(the DON + RMN), not by the wON contract: **Ethereum cannot read the BSC pool's balance.**
The contract-side `ccipMintHeadroomUsed` counter (renamed from `ccipMintedSupply` per M1 / #23)
is only a *local* proxy for that off-chain figure; it saturating-decrements on burns of
deposit-backed wON, so it can drift below the true BSC exposure. Source the cross-chain risk
signal from `IERC20(ON).balanceOf(BSC_LockReleaseTokenPool)` as the authoritative
locked-balance read; treat `ccipMintHeadroomUsed` as a useful local indicator but not the
ground truth for "how much value is in flight."

Source the events in `lib/chainlink-ccip/chains/evm/contracts/pools/LockReleaseTokenPool.sol` and `src/WrappedON.sol`. Page the on-call rotation on Critical lines.

## Appendix: file references

- Deployments JSON: `deployments/<chainId>.json` — written by 01 & 02, read by 03/04/05/06/08.
- Contracts: `src/WrappedON.sol` (only custom contract).
- Scripts: `script/01..08_*.s.sol`, `script/Helper.sol`, `script/Deployments.sol`.
- Tests: `test/WrappedON.t.sol` (unit), `test/PoolRoundtrip.t.sol` (pool wiring), `test/DeploymentE2E.t.sol` (full sequence simulation), `test/Deployments.t.sol` (deployment-artifact JSON round-trip).
