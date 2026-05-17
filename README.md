# Orochi Network ON Bridge (Ethereum ⇄ BSC, Chainlink CCIP)

A Chainlink CCIP **Cross-Chain Token (CCT)** bridge for the Orochi Network **ON** token between Ethereum Mainnet and BNB Smart Chain.

- **BSC side**: stock `LockReleaseTokenPool` against the existing ON token. Outbound locks ON; inbound releases ON.
- **Ethereum side**: stock `BurnMintTokenPool` against a new **wON** token (the only custom contract in this repo). Outbound burns wON; inbound mints wON.
- **wON** doubles as a 1:1 wrapper around native ETH-side ON: `deposit` pulls ON into a reserve and mints wON, `withdraw` burns wON and returns ON when the reserve allows.

| Chain | Token | Address | Supply | Mint model |
|---|---|---|---|---|
| Ethereum Mainnet | ON (existing) | `0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d` | 600M | Non-mintable |
| Ethereum Mainnet | wON (this repo) | deployed | CCIP-mint ≤ 100M; deposit-backed uncapped | Burn/Mint (pool only) |
| BSC Mainnet | ON (existing) | `0x0e4F6209eD984b21EDEA43acE6e09559eD051D48` | 100M | Lock/Release |

Production CCIP versions on both chains: Router 1.2.0, ARMProxy 1.0.0, TokenAdminRegistry 1.5.0, RegistryModuleOwnerCustom 1.6.0. This repo pins `lib/ccip` to **`v2.17.0-ccip1.5.16`** to match.

For the deep operator playbook, see [`RUNBOOK.md`](RUNBOOK.md). For audit findings + status, see [`SECURITY.md`](SECURITY.md). For project conventions, see [`CLAUDE.md`](CLAUDE.md).

---

## Step-by-step guide

### 1. Prerequisites

| Tool | Version | Install |
|---|---|---|
| Foundry (`forge` / `cast`) | 1.5+ | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| `git` | any | system package manager |
| `make` | any | system package manager |
| Python 3 (Slither, optional) | 3.10+ | system package manager |

### 2. Clone and install

```bash
git clone https://github.com/orochi-network/bridge.git
cd bridge
make install          # git submodule update --init --recursive + patch-pragmas
make build            # forge build --sizes
```

`make install` pulls the four pinned submodules (`forge-std`, `openzeppelin-contracts`, `chainlink-local`, `ccip`) and applies the documented pragma patch (`0.8.24` → `^0.8.24`) so the vendored Chainlink + OZ sources compile under solc 0.8.34. The patch is working-tree-only and must be re-run if you ever do `git submodule update`.

### 3. Run the test suite (no RPC needed)

```bash
make test             # 99 tests + 4 stateful invariants, no fork
```

Targeted subsets:

```bash
make test-unit        # WrappedON.t.sol only
make test-e2e         # PoolRoundtrip + DeploymentE2E
```

Fork tests (live mainnet RPCs required):

```bash
make test-fork ETH_RPC=https://… BSC_RPC=https://…   # 9 tests
```

Coverage summary:

```bash
make coverage
```

### 4. Configure environment

Copy `.env.example` → `.env` and fill in:

```bash
ETH_RPC=...
SEPOLIA_RPC=...
BSC_RPC=...
BSC_TESTNET_RPC=...
DEPLOYER_PK=0x...
ETHERSCAN_API_KEY=...
BSCSCAN_API_KEY=...
```

Then **edit `script/Helper.sol`** and replace the `address(0)` placeholders with the live CCIP infrastructure addresses for each chain you'll deploy on. Get them from the official [CCIP directory](https://docs.chain.link/ccip/directory). Scripts call `_requireSet` on every address they consume, so a missed placeholder fails fast with a `MissingAddress` revert before any broadcast.

### 5. Deploy — testnet first (Sepolia ⇄ BSC Testnet)

Always validate on testnet before mainnet. The sequence is symmetric, except wON only exists on the Ethereum side (Sepolia).

```bash
source .env

# Ethereum side: scripts 01 → 02 → 03 → 04 → 05
make deploy-eth RPC=sepolia

# BSC side: scripts 02 → 04 → 05 (no wON, no role grant)
make deploy-bsc RPC=bsc_testnet
```

Each script writes its outputs to `deployments/<chainId>.json` (key: `wrappedON`, `pool`). Subsequent scripts read from the same file, so order matters within a chain but the two chains can be deployed in either order.

### 6. Verify wiring is correct

```bash
make verify-eth RPC=sepolia
make verify-bsc RPC=bsc_testnet
```

`script/08_PostDeployVerify.s.sol` is view-only — it queries the registry, pool, and rate-limit state and reverts loudly on any mismatch. Run it whenever the topology changes.

### 7. Run an end-to-end bridge test on testnet

Send a small amount across using whatever CCIP client you prefer (the [CCIP UI](https://test.transporter.io/) is the simplest). Confirm:

- The lockOrBurn event fires on the source.
- The CCIP message lands on the destination.
- The receiver gets the expected amount.

Test both directions. Test reaching the rate-limit bucket. Test that withdrawing past the reserve reverts.

### 8. Deploy to mainnet

Same Make targets, different RPC.

```bash
make deploy-eth RPC=eth
make deploy-bsc RPC=bsc
make verify-eth RPC=eth
make verify-bsc RPC=bsc
```

### 9. Hand off ownership to the multisig

After confirming mainnet works end-to-end:

```bash
make handoff-all ETH_RPC=eth BSC_RPC=bsc MULTISIG=0x<safe-address>
```

This runs the handoff sequentially against ETH then BSC. There is no atomic rollback — if the first leg succeeds and the second fails, the bridge is half-handed-off and you must re-run the second leg. The handoff steps are idempotent (multisig grants are no-ops if already in place; `transferOwnership` and `transferAdminRole` overwrite the pending acceptor), so re-running is safe. Each invocation:

1. `pool.transferOwnership(multisig)` (two-step Ownable — multisig must `acceptOwnership` later).
2. **ETH only**: grants wON `DEFAULT_ADMIN_ROLE` to the multisig, **proposes** the multisig as new CCIP admin (two-step — multisig must `acceptCCIPAdmin` later).
3. `TokenAdminRegistry.transferAdminRole(token, multisig)` (two-step — multisig must `acceptAdminRole` later).

From the multisig, queue these transactions:

| Chain | Transaction |
|---|---|
| ETH | `pool.acceptOwnership()` on the BurnMintTokenPool |
| ETH | `registry.acceptAdminRole(wON)` on TokenAdminRegistry |
| ETH | `wON.acceptCCIPAdmin()` on wON |
| BSC | `pool.acceptOwnership()` on the LockReleaseTokenPool |
| BSC | `registry.acceptAdminRole(ON_BSC)` on TokenAdminRegistry |

Re-verify with `MULTISIG` set:

```bash
MULTISIG=0x<safe-address> make verify-eth RPC=eth
MULTISIG=0x<safe-address> make verify-bsc RPC=bsc
```

### 10. Renounce the deployer's wON admin role (ETH only)

Only after step 9's `acceptCCIPAdmin` has landed:

```bash
make renounce RPC=eth MULTISIG=0x<safe-address>
```

The script pre-asserts that the multisig already holds `DEFAULT_ADMIN_ROLE` AND has accepted the CCIP-admin role. If either is missing, the script reverts before renouncing — preventing an admin-less, permanently-unmanageable contract.

### 11. Post-launch operations

- **Update rate limits** (multisig only):
  ```bash
  OUTBOUND_CAPACITY=200000000000000000000000 OUTBOUND_RATE=20000000000000000 \
  INBOUND_CAPACITY=200000000000000000000000  INBOUND_RATE=20000000000000000  \
  make update-limits RPC=eth
  ```
- **Monitor** the events listed in [`RUNBOOK.md`](RUNBOOK.md#trust-model-bsc-reserve-custody) — especially `LiquidityRemoved`, `setRebalancer`, and any `RoleGranted(MINTER_ROLE / BURNER_ROLE, …)` on wON.
- **RMN curses** halt the lane automatically. Coordinate with Chainlink ops; no operator action required.

---

## Common workflows at a glance

| Task | Command |
|---|---|
| Install deps + patch | `make install` |
| Build (with sizes) | `make build` |
| Full test suite (no fork) | `make test` |
| Unit tests only | `make test-unit` |
| Fork tests against mainnet | `make test-fork ETH_RPC=… BSC_RPC=…` |
| Format check | `make fmt-check` |
| Coverage summary | `make coverage` |
| Deploy ETH side | `make deploy-eth RPC=…` |
| Deploy BSC side | `make deploy-bsc RPC=…` |
| Verify wiring | `make verify-eth RPC=…` / `make verify-bsc RPC=…` |
| Handoff both chains | `make handoff-all ETH_RPC=… BSC_RPC=… MULTISIG=…` |
| Renounce deployer admin | `make renounce RPC=eth MULTISIG=…` |
| Adjust rate limits | `make update-limits RPC=… OUTBOUND_CAPACITY=… …` |

---

## Repository layout

```
src/WrappedON.sol                       custom wON token (the only custom contract)
script/Helper.sol                       per-chain CCIP config + selectors
script/Deployments.sol                  reads/writes deployments/<chainId>.json
script/01_DeployWrappedON.s.sol         ETH only — deploys wON
script/02_DeployPools.s.sol             both chains — chain-dispatched on block.chainid
script/03_GrantRoles.s.sol              ETH only — MINTER/BURNER on wON for the pool
script/04_RegisterAdminAndPool.s.sol    both chains — registers admin + setPool
script/05_ApplyChainUpdates.s.sol       both chains — wires remote pool + rate limits
script/06_TransferOwnership.s.sol       handoff (TransferOwnership) + final renounce
script/07_UpdateRateLimits.s.sol        ops — adjust setChainRateLimiterConfig
script/08_PostDeployVerify.s.sol        view-only — programmatic wiring check
test/WrappedON.t.sol                    unit tests
test/PoolRoundtrip.t.sol                pool wiring + lockOrBurn / releaseOrMint
test/DeploymentE2E.t.sol                full sequence simulation
test/fork/Fork_ETH.t.sol                ETH mainnet fork
test/fork/Fork_BSC.t.sol                BSC mainnet fork
test/fork/Fork_Bridge.t.sol             dual-fork BSC→ETH→BSC roundtrip
deployments/<chainId>.json              written by scripts, read by subsequent scripts
```

---

## Security

See [`SECURITY.md`](SECURITY.md) for the full audit and the disposition of every finding. Trust-model TL;DR:

- The BSC pool's owner (the ops multisig) has custody of the locked-ON reserve via Chainlink's standard `setRebalancer` / `withdrawLiquidity` flow. This is the documented Chainlink CCT pattern; subclassing to disable it was considered and rejected.
- wON's CCIP-mint path is hard-capped at 100M ether (the BSC ON canonical supply, the absolute upper bound on what the bridge can ever reflect onto Ethereum). The `deposit` wrap path is intentionally uncapped — bounded naturally by the ETH-side ON supply — so heavy wrap usage cannot starve inbound CCIP messages. The safety invariant `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` is preserved by mechanics (CCIP mint ↔ BSC lock pairing; deposit ↔ reserve lockstep), not by a `totalSupply` cap. See SECURITY.md C-3 / R-1 / R-14.
- `setCCIPAdmin` on wON is two-step (propose + accept).

For incident response, see [`RUNBOOK.md`](RUNBOOK.md#4-post-launch-operations).
