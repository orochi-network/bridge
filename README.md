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

Production CCIP infra on both chains: Router 1.2.0, ARMProxy 1.0.0, TokenAdminRegistry 1.5.0, RegistryModuleOwnerCustom 1.6.0. This repo builds the pools from **`lib/chainlink-ccip` @ `contracts-ccip-v1.6.1`** (with shared/vendored sources from **`lib/chainlink-evm` @ `contracts-v1.4.0`**) — CCIP 1.6.1, the Chainlink-docs-recommended generic-pool version. The deployed `BurnMintTokenPool`/`LockReleaseTokenPool` report `typeAndVersion` `…1.6.1`.

For the deep operator playbook, see [`RUNBOOK.md`](RUNBOOK.md). For project conventions, see [`CLAUDE.md`](CLAUDE.md).

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

`make install` pulls the five pinned submodules (`forge-std`, `openzeppelin-contracts`, `chainlink-local`, `chainlink-ccip`, `chainlink-evm`) and applies the documented pragma patch (`0.8.24` → `^0.8.24`) so the vendored Chainlink + OZ sources compile under solc 0.8.34. The patch is working-tree-only and must be re-run if you ever do `git submodule update`.

### 3. Run the test suite (no RPC needed)

```bash
make test             # 139 tests, no fork (135 unit/integration + 4 stateful invariants)
```

Targeted subsets:

```bash
make test-unit        # WrappedON.t.sol only
make test-e2e         # everything except WrappedON unit tests and forks
```

Fork tests (live mainnet RPCs required):

```bash
make test-fork ETH_RPC=https://… BSC_RPC=https://…   # 10 tests
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
ETHERSCAN_API_KEY=...
BSCSCAN_API_KEY=...
```

Then **edit `script/Helper.sol`** and replace the `address(0)` placeholders with the live CCIP infrastructure addresses for each chain you'll deploy on. Get them from the official [CCIP directory](https://docs.chain.link/ccip/directory). Scripts call `_requireSet` on every address they consume, so a missed placeholder fails fast with a `MissingAddress` revert before any broadcast.

> **Key handling** (SECURITY: OPS-1). Signing is via a Foundry encrypted keystore account — no raw private key on the CLI or in `.env`. Create it once with `cast wallet import deployer --interactive`; the `make deploy-*` targets then sign with `--account deployer` (override with `ACCOUNT=<name>`) and forge prompts for the keystore password per broadcast. See `RUNBOOK.md §0.3` for the full procedure. The deployer EOA holds critical authority throughout the handoff window.

### 5. Deploy — testnet first (Sepolia ⇄ BSC Testnet)

Always validate on testnet before mainnet. The sequence is symmetric, except wON only exists on the Ethereum side (Sepolia).

```bash
source .env

# Ethereum side: scripts 01 → 02 → 03 → 04 → 05
make deploy-eth RPC=sepolia

# BSC side: scripts 02 → 04 → 05 (no wON, no role grant)
make deploy-bsc RPC=bsc_testnet
```

Script 01 (ETH) deploys three contracts in sequence: a `TimelockController` (48h delay), the `WrappedON` implementation, and an `ERC1967Proxy` that calls `initialize`. Artifacts are written to `deployments/<chainId>.json` under three keys: `wrappedON` (the proxy — this is the token registered with CCIP), `wrappedONImpl`, and `wrappedONTimelock`. All other scripts consume `wrappedON` (the proxy). Subsequent scripts read from the same file, so order matters within a chain but the two chains can be deployed in either order.

> **Recovery after mid-sequence failure** (SECURITY: OPS-5). If any of the chained scripts in `make deploy-eth` / `make deploy-bsc` fails (RPC timeout, nonce collision, gas exhaustion), simply re-run the same `make` target. Every script is idempotent: 01/02 skip when their artifact entry exists; 03 skips role grants that already landed; 04 probes the registry state before broadcasting; 05 skips wiring that's already in place. Do NOT manually re-run individual scripts unless you have confirmed the deployment artifact JSON is consistent with on-chain state — manual recovery is the most common path to inconsistent state.

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
2. **ETH only**: grants wON `DEFAULT_ADMIN_ROLE` to the multisig, **proposes** the multisig as new CCIP admin (two-step — multisig must `acceptCCIPAdmin` later). Also grants multisig `PAUSER_ROLE` on wON and the timelock's proposer/executor/canceller roles on the `TimelockController` (so the multisig can schedule and execute upgrades and use the emergency pause). The deployer keeps its own `PAUSER_ROLE` + timelock roles until the separate renounce step (step 10) — they are NOT renounced here.
3. `TokenAdminRegistry.transferAdminRole(token, multisig)` (two-step — multisig must `acceptAdminRole` later).

From the multisig, queue these transactions:

| Chain | Transaction |
|---|---|
| ETH | `pool.acceptOwnership()` on the BurnMintTokenPool |
| ETH | `registry.acceptAdminRole(wON)` on TokenAdminRegistry |
| ETH | `wON.acceptCCIPAdmin()` on wON (proxy) |
| BSC | `pool.acceptOwnership()` on the LockReleaseTokenPool |
| BSC | `registry.acceptAdminRole(ON_BSC)` on TokenAdminRegistry |

The multisig already holds `PAUSER_ROLE` on wON and the timelock proposer/executor/canceller roles after the `TransferOwnership` step completes — no accept step needed for those (they are direct `grantRole` calls from the deployer). The deployer's own copies of `PAUSER_ROLE` + the timelock roles (and `DEFAULT_ADMIN_ROLE`) are renounced later in the `RenounceDeployerAdmin` step (step 10 / `make renounce`), whose pre-flight gate first asserts the multisig holds all of them.

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

The `RenounceDeployerAdmin` script pre-asserts that the multisig already holds `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE`, the timelock proposer/executor/canceller roles, AND has accepted the CCIP-admin role. If any is missing, the script reverts before renouncing — preventing an admin-less, permanently-unmanageable contract. It then renounces the deployer's own `DEFAULT_ADMIN_ROLE` + `PAUSER_ROLE` on wON and proposer/executor/canceller on the `TimelockController` (the deployer never held `UPGRADER_ROLE` — that sits on the timelock from `initialize`).

### 11. Post-launch operations

- **Update rate limits** (multisig or delegated `rateLimitAdmin`):
  ```bash
  # Post-handoff, set CALLER_FLAGS to a Foundry credential authorised on the pool
  # (e.g. another keystore account for the delegated rateLimitAdmin). The deployer
  # keystore account is no longer authorised once ownership has moved to the multisig.
  CALLER_FLAGS='--account ratelimit-admin' \
  OUTBOUND_CAPACITY=200000000000000000000000 OUTBOUND_RATE=20000000000000000 \
  INBOUND_CAPACITY=200000000000000000000000  INBOUND_RATE=20000000000000000  \
  make update-limits RPC=eth
  ```
- **Emergency pause** (multisig, from Safe UI):
  Call `wON.pause()` from the multisig (which holds `PAUSER_ROLE` post-handoff). This halts `mint`, `burn*`, `deposit`, and `withdraw` on the proxy; plain ERC20 transfers stay live. Resume with `wON.unpause()`. See RUNBOOK §4.6.
- **wON upgrade** (multisig + timelock, 48h delay):
  1. Deploy new implementation: `forge create src/WrappedON.sol:WrappedON --rpc-url eth --account deployer`.
  2. From the multisig, call `timelock.schedule(proxy, 0, abi.encodeCall(proxy.upgradeToAndCall, (newImpl, "")), 0, salt, 172800)`.
  3. Wait 48h, then call `timelock.execute(proxy, 0, abi.encodeCall(proxy.upgradeToAndCall, (newImpl, "")), 0, salt)`.
  See RUNBOOK §4.7 for the full procedure including state-preservation verification.
- **Monitor** the events listed in [`RUNBOOK.md`](RUNBOOK.md#trust-model-bsc-reserve-custody) — especially `LiquidityRemoved`, `setRebalancer`, any `RoleGranted(MINTER_ROLE / BURNER_ROLE, …)` on wON, and `Upgraded(implementation)` on the proxy.
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
script/PrecheckHelper.s.sol             pure non-zero placeholder check for Helper.sol
script/ValidateConfig.s.sol             live RPC staticcall check of CCIP infra addresses
script/ValidateBscAdmin.s.sol           read-only probe of the BSC ON CCIP-admin path
test/WrappedON.t.sol                    unit tests
test/WrappedONInvariant.t.sol           4 stateful invariants over 9 handler actions
test/PoolRoundtrip.t.sol                pool wiring + lockOrBurn / releaseOrMint
test/DeploymentE2E.t.sol                full sequence simulation
test/Deployments.t.sol                  deployment-artifact JSON round-trip
test/Script04Paths.t.sol                script 04 admin-dispatch path coverage
test/Script06Guards.t.sol               handoff env-var + multisig guard coverage
test/Script06Renounce.t.sol             renounce precondition assertions
test/Script07Preflight.t.sol            rate-limit preflight checks
test/Script08Verify.t.sol               post-deploy verification coverage
test/fork/Fork_ETH.t.sol                ETH mainnet fork
test/fork/Fork_BSC.t.sol                BSC mainnet fork
test/fork/Fork_Bridge.t.sol             dual-fork BSC→ETH→BSC roundtrip
deployments/<chainId>.json              written by scripts, read by subsequent scripts
```

---

## Security

Trust-model TL;DR:

- The BSC pool's owner (the ops multisig) has custody of the locked-ON reserve via Chainlink's standard `setRebalancer` / `withdrawLiquidity` flow. This is the documented Chainlink CCT pattern; subclassing to disable it was considered and rejected.
- wON's CCIP-mint path is hard-capped at 100M ether (the BSC ON canonical supply, the absolute upper bound on what the bridge can ever reflect onto Ethereum). The `deposit` wrap path is **permissionless** — any ETH-side ON holder can wrap 1:1; wON supply growth and ETH→BSC redemption demand are bounded by ETH-side ON supply and the CCIP pool rate limits. `deposit` is uncapped in amount and independent of `MAX_CCIP_MINTED`, so heavy wrap usage cannot starve inbound CCIP messages. The safety invariant `lockedON_BSC + reserveON_ETH >= totalSupply(wON)` is preserved by mechanics (CCIP mint ↔ BSC lock pairing; deposit ↔ reserve lockstep), not by a `totalSupply` cap. On BSC→ETH arrivals, `mint` always delivers **wON** (the registered token) to every receiver — EOA or contract — and never native ON; the reserve is never read on the mint path, so the delivered asset is deterministic and not front-runnable (issue #48). A holder who wants native ON calls `withdraw`.
- The ON locked on BSC *via CCIP* equals the wON minted on Ethereum *via CCIP*, message-for-message — but that equality is guaranteed by CCIP's 1:1 message pairing, **not** by any on-chain check on Ethereum. **Ethereum cannot read the BSC locked balance**, so the bridge trusts Chainlink (the DON + RMN) to honour the pairing. The on-chain `MAX_CCIP_MINTED` / `ccipMintHeadroomUsed` counter is a *local approximation* of that off-chain figure — it caps the local CCIP-mint counter, not aggregate wON supply.
- `setCCIPAdmin` on wON is two-step (propose + accept). Overwriting an in-flight proposal emits `CCIPAdminProposalCancelled(prev)` so any party with a queued `acceptCCIPAdmin` tx gets a clear signal.
- CCIP entrypoints emit named events for indexer-friendly auditing: `CCIPMinted(account, amount, ccipMintHeadroomUsed)` from inbound mints and `CCIPBurned(account, amount, ccipMintHeadroomUsed)` from all three burn overloads.
- The `Wrapped` event's second parameter is named `received` (post-fee, the actual wON minted) — renamed from `amount` per `SECURITY.md` WON-9 to make the received-amount-accounting semantics explicit. ABI consumers that read parameters by name (ethers v6, viem, OZ Defender) need to update their bindings; consumers that read by index are unaffected.
- The CCIP mint-cap counter was renamed `ccipMintedSupply` → `ccipMintHeadroomUsed` (`SECURITY.md` M1 / #23) so the name reflects "cap headroom consumed", not BSC-minted supply. **ABI impact:** the public getter selector changes (`ccipMintedSupply()` → `ccipMintHeadroomUsed()`), so callers reading it by name/selector must update; the `CCIPMinted` / `CCIPBurned` event *signatures* are unchanged (renaming a non-indexed parameter doesn't alter the topic hash), but by-name decoders should refresh the param label.

See [`SECURITY.md`](SECURITY.md) for the full security review with per-finding status, the
disclosure policy (`security@orochi.network`), and the identifier-prefix convention
(`WON-`, `DEP-`, `CCIP-`, `TEST-`, `OPS-`). For incident response, see
[`RUNBOOK.md`](RUNBOOK.md#4-post-launch-operations).
