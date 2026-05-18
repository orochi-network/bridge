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

### 0.2 Confirm the BSC ON token admin path

The deployer needs to be able to register as admin for the canonical ON on BSC (`0x0e4F6209eD984b21EDEA43acE6e09559eD051D48`). Three possibilities, in order:

1. `IGetCCIPAdmin.getCCIPAdmin()` returns the deployer — script auto-uses `registerAdminViaGetCCIPAdmin`.
2. `Ownable.owner()` returns the deployer — script auto-uses `registerAdminViaOwner`.
3. Neither — the **current** ON token owner must call `TokenAdminRegistry.proposeAdministrator(token, deployer)` from their wallet, then re-run script 04, which will succeed at `acceptAdminRole` / `setPool`.

Check ahead of time which path applies.

### 0.3 Environment

Copy `.env.example` → `.env` and fill in:

```bash
ETH_RPC=https://...
SEPOLIA_RPC=https://...
BSC_RPC=https://...
BSC_TESTNET_RPC=https://...
DEPLOYER_PK=0x...
ETHERSCAN_API_KEY=...
BSCSCAN_API_KEY=...
```

Then `source .env`.

**Key-handling note:** the Makefile passes `--private-key $(DEPLOYER_PK)` on the command line, which means the key is visible in `ps aux` and shell history while the broadcast is running. For mainnet broadcasts prefer Foundry's encrypted keystore (`cast wallet import deployer --interactive`, then run scripts with `--account deployer` instead of `--private-key`). The deployer EOA holds critical authority throughout the handoff window — see SECURITY.md H-2.

### 0.4 Build & test locally

```bash
make build
make test                 # all 99 non-fork tests (95 unit/integration + 4 stateful invariants) must pass
make fmt-check
```

---

## 1. Testnet deployment

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

CCIP infrastructure addresses on mainnet can change. Re-confirm against the [CCIP directory](https://docs.chain.link/ccip/directory) and update `Helper.sol` if needed.

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

The single target runs the handoff sequentially against both chains with the same multisig — preventing the half-handed-off-on-one-chain footgun (audit H-5). For single-chain handoffs (e.g. during testnet dry runs) use `make handoff RPC=<chain> MULTISIG=…`.

Each per-chain invocation:
- Calls `pool.transferOwnership(multisig)` (two-step Ownable).
- (ETH only) Grants wON `DEFAULT_ADMIN_ROLE` to the multisig and proposes the new CCIP admin (two-step — multisig must call `acceptCCIPAdmin`).
- Calls `TokenAdminRegistry.transferAdminRole(token, multisig)` (two-step).

**Monitor while the handoff is in flight.** During the grant→accept→renounce window, the deployer EOA still holds `MINTER_ROLE`/`BURNER_ROLE` admin authority (audit H-2). Watch for unexpected `RoleGranted` events on wON — see [Trust model](#trust-model-bsc-reserve-custody).

### 3.2 Multisig accepts (from the Safe UI / SDK)

Queue these transactions on the multisig:

| Chain | Transaction |
|---|---|
| ETH   | `pool.acceptOwnership()` on the BurnMintTokenPool |
| ETH   | `registry.acceptAdminRole(wON)` on TokenAdminRegistry |
| ETH   | `wON.acceptCCIPAdmin()` (completes the two-step CCIP admin transfer) |
| BSC   | `pool.acceptOwnership()` on the LockReleaseTokenPool |
| BSC   | `registry.acceptAdminRole(ON_BSC)` on TokenAdminRegistry |

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

The script now pre-asserts (audit H-1):
- Multisig holds `DEFAULT_ADMIN_ROLE` on wON.
- Multisig is `getCCIPAdmin()` (i.e. it called `acceptCCIPAdmin`).
- The deployer still holds the role at call time.

Then calls `won.renounceRole(DEFAULT_ADMIN_ROLE, deployer)`. After this point, only the multisig can grant/revoke wON roles. **Do not skip this step.**

---

## 4. Post-launch operations

### 4.1 Updating rate limits

```bash
make update-limits RPC=eth \
    OUTBOUND_CAPACITY=200000000000000000000000 \
    OUTBOUND_RATE=20000000000000000 \
    INBOUND_CAPACITY=200000000000000000000000 \
    INBOUND_RATE=20000000000000000
```

(All values in wei. Above = 200,000 cap, 0.02 ON/sec rate.) Caller must be the pool owner (the multisig) or the rate-limit admin. From the multisig, queue the equivalent `setChainRateLimiterConfig` call.

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

---

## Trust model: BSC reserve custody

Chainlink's `LockReleaseTokenPool` is built around a trusted-operator pattern. After ownership handoff, the BSC pool's `owner` (the ops multisig) can:

- Call `setRebalancer(addr)` (`onlyOwner`) — designates which address may move the locked-ON reserve.
- The designated rebalancer can call `provideLiquidity(amount)` (only when `acceptLiquidity=true`; we deploy with `false`, so this path is blocked) and `withdrawLiquidity(amount)` / `transferLiquidity(from, amount)`.

This means the multisig effectively has custody of the BSC-side locked-ON reserve. This is the **documented Chainlink CCT pattern** for `LockReleaseTokenPool` and is intentional. See `SECURITY.md` C-1 for the full discussion.

**Required monitoring** (set up an off-chain alert before mainnet handoff):

| Event / call | Where | Severity |
|---|---|---|
| `LiquidityRemoved(remover, amount)` | BSC pool | **Critical** |
| `LiquidityAdded(provider, amount)` | BSC pool | High |
| `setRebalancer(addr)` calldata trace | BSC pool | **Critical** |
| `OwnershipTransferRequested` / `OwnershipTransferred` | BSC pool | **Critical** |
| `RoleGranted(MINTER_ROLE, *)` where grantee ≠ ETH pool | wON | **Critical** |
| `RoleGranted(BURNER_ROLE, *)` where grantee ≠ ETH pool | wON | **Critical** |
| `CCIPAdminTransferProposed` / `CCIPAdminTransferred` | wON | High |
| Outbound / inbound rate-limit bucket exhausted | both pools | Medium |

Source the events in `lib/ccip/contracts/src/v0.8/ccip/pools/LockReleaseTokenPool.sol` and `src/WrappedON.sol`. Page the on-call rotation on Critical lines.

## Appendix: file references

- Deployments JSON: `deployments/<chainId>.json` — written by 01 & 02, read by 03/04/05/06/08.
- Contracts: `src/WrappedON.sol` (only custom contract).
- Scripts: `script/01..08_*.s.sol`, `script/Helper.sol`, `script/Deployments.sol`.
- Tests: `test/WrappedON.t.sol` (unit), `test/PoolRoundtrip.t.sol` (pool wiring), `test/DeploymentE2E.t.sol` (full sequence simulation), `test/Deployments.t.sol` (deployment-artifact JSON round-trip).
