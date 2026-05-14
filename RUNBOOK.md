# Production Deployment Runbook — ON Bridge

This walks the deploy + handoff sequence end to end. Run on **testnet first** (Sepolia ⇄ BSC Testnet), then mainnet. Each step is idempotent — re-running a script that already executed will either fast-fail with a clear error (`AlreadyRegistered`, `MissingAddress`, etc.) or no-op.

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

### 0.4 Build & test locally

```bash
make build
make test                 # all 26 tests must pass
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
make handoff RPC=eth MULTISIG=0x<safe-address>
make handoff RPC=bsc MULTISIG=0x<safe-address>
```

Each invocation:
- Calls `pool.transferOwnership(multisig)` (two-step).
- (ETH only) Grants wON `DEFAULT_ADMIN_ROLE` to the multisig and sets CCIP admin to the multisig.
- Calls `TokenAdminRegistry.transferAdminRole(token, multisig)` (two-step).

### 3.2 Multisig accepts (from the Safe UI / SDK)

Queue these transactions on the multisig:

| Chain | Transaction |
|---|---|
| ETH   | `pool.acceptOwnership()` on the BurnMintTokenPool |
| ETH   | `registry.acceptAdminRole(wON)` on TokenAdminRegistry |
| BSC   | `pool.acceptOwnership()` on the LockReleaseTokenPool |
| BSC   | `registry.acceptAdminRole(ON_BSC)` on TokenAdminRegistry |

### 3.3 Re-verify with `MULTISIG` env var set

```bash
MULTISIG=0x<safe-address> make verify-eth RPC=eth
MULTISIG=0x<safe-address> make verify-bsc RPC=bsc
```

This adds an ownership-handoff check: `pool.owner() == multisig` on each chain.

### 3.4 Deployer renounces wON admin role (ETH only)

After 3.2 confirms the multisig is operational:

```bash
make renounce RPC=eth
```

This calls `won.renounceRole(DEFAULT_ADMIN_ROLE, deployer)`. After this point, only the multisig can grant/revoke wON roles. **Do not skip this step.**

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
5. Drain the old pool: on the LockRelease side, set `acceptLiquidity=true` is required for `withdrawLiquidity`; since we deploy with `acceptLiquidity=false` permanently, the locked tokens cannot be moved without a corresponding burn on the other chain. **Plan migrations such that net positions are zero before swapping.**

---

## Appendix: file references

- Deployments JSON: `deployments/<chainId>.json` — written by 01 & 02, read by 03/04/05/06/08.
- Contracts: `src/WrappedON.sol` (only custom contract).
- Scripts: `script/01..08_*.s.sol`, `script/Helper.sol`, `script/Deployments.sol`.
- Tests: `test/WrappedON.t.sol` (unit), `test/PoolRoundtrip.t.sol` (pool wiring), `test/DeploymentE2E.t.sol` (full sequence simulation).
- Plan of record: `/home/parallels/.claude/plans/orochi-network-token-on-gleaming-cat.md`.
