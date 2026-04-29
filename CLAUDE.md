# Project: ON Cross-Chain Bridge (BSC ↔ Ethereum)

## What this project is

LayerZero V2 OFT bridge for the **ON** token between **BSC** (canonical / locked) and **Ethereum** (wrapped / mintable).

| Chain | Existing ON token | Bridge contract | Role |
|-------|-------------------|-----------------|------|
| BSC | [`0x0e4F6209eD984b21EDEA43acE6e09559eD051D48`](https://bscscan.com/address/0x0e4F6209eD984b21EDEA43acE6e09559eD051D48) | `ONOFTAdapter` | Locks/unlocks the existing ON token |
| ETH | [`0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d`](https://etherscan.io/address/0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d) | `WrappedON` (wON) | Mints/burns the bridged representation |

**Solution 3** (per the design doc): BSC holds the canonical supply locked in `ONOFTAdapter`; Ethereum gets a fresh mintable `WrappedON` (wON). The pre-existing ETH-side ON contract is **unused** by the bridge and orphaned by design.

## Why Solution 3 (and not 1, 2, or 4)

- **Solution 1** (Chainlink CCIP `LockReleaseTokenPool`): requires liquidity management on both chains, off Chainlink best practices.
- **Solution 2** (multiple OFTAdapters): unsafe — source has no view of destination balance, oversend → permanently locked funds.
- **Solution 3** (BSC adapter + ETH mintable wON): one canonical reserve (BSC), the other side is mint/burn → no liquidity to manage. **Chosen.**
- **Solution 4** (mintable wrappers on both chains with internal accounting): same liquidity-fragmentation risk as 1/2, most custom code.

## Why no auto-unwrap on Ethereum

Auto-unwrap (override `_credit`/`_debit` so wON converts to the pre-existing ETH ON on receipt) would require:

1. Custom Solidity in `WrappedON.sol` (we want to keep it byte-identical to the LayerZero template).
2. A finite reserve of the pre-existing ETH ON inside wON. The pre-existing token has no mint, so net BSC→ETH flow drains the reserve and bricks the ETH side.
3. Liquidity monitoring + manual rebalances.

This converts Solution 3 into Solution 4 and reintroduces exactly the problem we picked Solution 3 to avoid. **Decision: users on ETH hold wON directly. No on-chain unwrap.**

## Origin

Scaffolded by copying `examples/oft-adapter` from [`LayerZero-Labs/devtools`](https://github.com/LayerZero-Labs/devtools/tree/main/examples/oft-adapter) (the same template `npx create-lz-oapp -e oft-adapter` produces). Contracts (`WrappedON.sol`, `ONOFTAdapter.sol`) are **byte-identical** to the upstream template — only the constructor pass-through that the abstract parents require.

## Production configuration decisions (locked in)

- **DVNs**: 2 required, 0 optional → `['LayerZero Labs', 'Google Cloud']`. `metadata-tools` resolves names to per-chain addresses at `lz:oapp:wire` time.
- **Confirmations**: BSC→ETH = 20 (~60s on BSC's ~3s blocks); ETH→BSC = 15 (~3 min on ETH's 12s blocks).
- **Enforced executor options**: 200,000 gas, 0 value on `LZ_RECEIVE` for both directions. Generous headroom for `_lzReceive` (mint on ETH, transfer on BSC); unused gas is refunded.
- **Ownership flow**: deploy with EOA, then `lz:oapp:wire`, then transfer `owner` and `setDelegate` to a multisig. Multisig addresses go in `.env` (`OWNER_BSC`, `OWNER_ETH`).
- **wON metadata**: `name = "Wrapped ON"`, `symbol = "wON"`, decimals 18 (OZ ERC20 default).

## Toolchain

| Tool | Version | Notes |
|------|---------|-------|
| Node | ≥18.16 | See `.nvmrc` |
| Hardhat | 2.22.x | Required for `lz:oapp:wire` (applies DVN/executor/enforced-options config) |
| Foundry | latest stable | For unit/integration tests via `forge test` |
| Solidity | 0.8.22 | Pinned, matches LZ template |

Both Hardhat and Foundry are kept. Hardhat does deploy + wire; Foundry does fast tests.

## Repository layout

```
bridge/
├── contracts/
│   ├── ONOFTAdapter.sol     ← BSC: pass-through over OFTAdapter (LZ template, unchanged)
│   ├── WrappedON.sol            ← ETH: pass-through over OFT       (LZ template, unchanged)
│   └── mocks/
├── deploy/
│   ├── ONOFTAdapter.ts      ← deploys ONOFTAdapter on networks with `oftAdapter.tokenAddress` set
│   ├── WrappedON.ts             ← deploys WrappedON (wON) on networks WITHOUT `oftAdapter` config
│   └── MyERC20Mock.ts       ← test-only mock token deploy (unused on mainnet)
├── tasks/
│   ├── sendOFT.ts           ← `hardhat send` task: quote + approve + send
│   ├── sendEvm.ts
│   └── ...
├── test/                    ← Foundry + Hardhat tests
├── foundry.toml
├── hardhat.config.ts        ← networks: bsc + ethereum mainnet (BSC has oftAdapter.tokenAddress set)
├── layerzero.config.ts      ← BSC↔ETH pathway, 2 DVNs, confirmations, enforced options
├── package.json
├── .env.example             ← commented placeholders for RPC / keys / multisigs
└── CLAUDE.md                ← this file
```

## Common commands

```sh
# One-time setup
cp .env.example .env         # fill in PRIVATE_KEY (or MNEMONIC) and RPC URLs
npm install                  # or pnpm install — pnpm-lock.yaml is the canonical lockfile
npm run compile              # Hardhat + Foundry compile

# Tests
npm test                     # forge test + hardhat test

# Deploy
npx hardhat lz:deploy        # CLI prompts for networks; pick `bsc` and `ethereum`
                             # → BSC deploys ONOFTAdapter, ETH deploys WrappedON (wON)

# Wire (sets peers + DVNs + executor + enforced options on both sides)
npx hardhat lz:oapp:wire --oapp-config layerzero.config.ts

# Verify peers
npx hardhat lz:oapp:peers:get --oapp-config layerzero.config.ts

# Send (BSC → ETH)
npx hardhat lz:oft:send --network bsc --src-eid 30102 --dst-eid 30101 --to 0xRECIPIENT --amount 1.0
# Send (ETH → BSC)
npx hardhat lz:oft:send --network ethereum --src-eid 30101 --dst-eid 30102 --to 0xRECIPIENT --amount 1.0
```

## Post-deploy checklist (mainnet)

1. ✅ Verify on Etherscan + BSCScan (`--verify` flag on `lz:deploy` or manual).
2. ✅ Run `lz:oapp:wire` — confirm both peers, DVN config, and enforced options applied.
3. ✅ Run `lz:oapp:peers:get` to confirm bidirectional peers.
4. ✅ Send a small test amount BSC→ETH and ETH→BSC; confirm balances move losslessly.
5. ✅ `transferOwnership(OWNER_BSC)` on `ONOFTAdapter`, `transferOwnership(OWNER_ETH)` on `WrappedON`.
6. ✅ `setDelegate(OWNER_BSC)` and `setDelegate(OWNER_ETH)` (LayerZero config authority).
7. ✅ Have multisig signers confirm they can call admin functions (sanity check).

## Important gotchas

- **OFTAdapter requires a lossless inner token.** ON on BSC must NOT be fee-on-transfer or rebasing. The adapter assumes `transferFrom(amount)` actually moves `amount`. **Verify with a forked-mainnet test before production.**
- **OFT decimals must match.** `WrappedON` defaults to 18 (OZ ERC20). Real ON on BSC is 18 — but reconfirm via `cast call $ON_BSC "decimals()(uint8)" --rpc-url $RPC_URL_BSC`. Mismatch → silent dust loss via `decimalConversionRate`.
- **Only ONE OFTAdapter per global mesh.** BSC is it. If a third chain is added later, deploy another `WrappedON` (mintable), never another adapter.
- **Endpoint V2 address.** `0x1a44076050125825900e736c501f859c50fE728c` on every supported EVM mainnet/testnet. The Hardhat plugin pulls this automatically based on `eid`.
- **Approval before send (BSC side).** Users must `approve(adapter, amount)` on the ON token before calling `send()` on `ONOFTAdapter`.
- **Multisig hand-off.** Deployer EOA owns the contracts until step 5–6 of the post-deploy checklist. Don't go live without finishing the hand-off.

## What we deliberately did NOT do

- No custom contract logic — `WrappedON.sol` and `ONOFTAdapter.sol` are byte-identical to the LZ template.
- No auto-unwrap on ETH (would require an ETH-side reserve and convert this into Solution 4).
- No `MintBurnOFTAdapter` / `NativeOFTAdapter`.
- No LayerZero V1.

## Re-scaffolding the upstream template

To pull a newer version of the LayerZero template later:

```sh
git clone --depth 1 https://github.com/LayerZero-Labs/devtools.git /tmp/lz-fresh
diff -r /tmp/lz-fresh/examples/oft-adapter/contracts ./contracts
diff -r /tmp/lz-fresh/examples/oft-adapter/test ./test
```

If upstream contracts changed, decide case-by-case whether to merge.

## Things still to fill in before production deploy

- [ ] `.env` — `PRIVATE_KEY` (deployer), `RPC_URL_BSC`, `RPC_URL_ETH`, `BSCSCAN_API_KEY`, `ETHERSCAN_API_KEY`, `OWNER_BSC`, `OWNER_ETH`.
- [ ] Confirm ON on BSC `decimals() == 18` and is not fee-on-transfer (forked test).
- [ ] Confirm Google Cloud DVN is live on both BSC and Ethereum mainnet (check https://docs.layerzero.network/v2/deployments/dvn-addresses).
- [ ] Decide multisig threshold + signers; have the multisig deployed on both chains.
