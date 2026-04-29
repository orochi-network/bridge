# Project: ON Cross-Chain Bridge (BSC ↔ Ethereum)

## What this project is

LayerZero V2 OFT bridge for the **ON** token between **BSC** (canonical / locked) and **Ethereum** (wrapped / mintable).

| Chain | Existing ON token | Bridge contract | Role |
|-------|-------------------|-----------------|------|
| BSC | [`0x0e4F6209eD984b21EDEA43acE6e09559eD051D48`](https://bscscan.com/address/0x0e4F6209eD984b21EDEA43acE6e09559eD051D48) | `ONOFTAdapter` | Locks/unlocks the existing ON token |
| ETH | [`0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d`](https://etherscan.io/address/0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d) | `WrappedON` (wON) | Mints/burns the bridged representation; held as the unwrap reserve |

**Solution 3** (per the design doc): BSC holds the canonical supply locked in `ONOFTAdapter`; Ethereum gets a fresh mintable `WrappedON` (wON). The pre-existing ETH-side ON is **held as a reserve** inside `WrappedON` for opt-in 1:1 unwrap (see "Auto-unwrap on Ethereum" below).

## Why Solution 3 (and not 1, 2, or 4)

- **Solution 1** (Chainlink CCIP `LockReleaseTokenPool`): requires liquidity management on both chains, off Chainlink best practices.
- **Solution 2** (multiple OFTAdapters): unsafe — source has no view of destination balance, oversend → permanently locked funds.
- **Solution 3** (BSC adapter + ETH mintable wON): one canonical reserve (BSC), the other side is mint/burn → no liquidity to manage. **Chosen.**
- **Solution 4** (mintable wrappers on both chains with internal accounting): same liquidity-fragmentation risk as 1/2, most custom code.

## Auto-unwrap on Ethereum (with bounded brick risk)

`WrappedON` overrides OFT's default `_credit` so that on inbound BSC→ETH messages:

- **Plain message + reserve ≥ amount**: transfer real ON to the recipient. wON is **not** minted.
- **Plain message + reserve insufficient**: fall back to minting wON (default OFT behaviour). The recipient can later call `unwrap(amount)` to redeem against the reserve once it's refilled.
- **Composed message** (`SEND_AND_CALL`): always mint wON, regardless of reserve. The compose handler downstream encodes `amountReceivedLD` as if it were the OFT (wON); auto-unwrapping would deliver real ON instead, leaving the compose handler manipulating a wON balance the recipient doesn't have. Force the mint path to keep compose semantics intact.

The pre-existing ETH ON has no mint, so this is a Solution-4-style design with a known liquidity-management problem. We accepted the trade-off because users always have a recovery path — message **delivery** never bricks for plain messages (fallback always succeeds), only **instant unwrap** can fail when the reserve is dry.

`WrappedON` exposes a manual swap surface:

- `wrap(amount)` — deposit real ON, mint wON 1:1. Lets legacy ETH-ON holders enter the bridge and lets the operator rebalance. Defends against fee-on-transfer reserves: reverts with `UnexpectedTransferAmount` if the actual amount received is not exactly the requested amount.
- `unwrap(amount)` — burn wON, withdraw real ON 1:1. Reverts with `ReserveInsufficient` if the reserve cannot cover the request.
- `seedReserve(amount)` — donate real ON to the reserve without minting wON. Same fee-on-transfer guard as `wrap`. **One-way subsidy** — see below.

### Reserve operations (operator obligations)

Sustained net BSC→ETH flow drains the reserve. Refill paths:

1. **Bridge wON back to BSC.** Treasury holds wON (from market activity, `wrap`-ing legacy ETH ON, or some other source), sends ETH→BSC to unlock real ON on BSC, acquires real ETH ON off-chain (DEX/OTC), then `seedReserve`s it.
2. **Direct treasury commitment.** Treasury holds real ETH ON and `seedReserve`s it.

Off-chain monitoring is required: alert when `WrappedON.reserve()` falls below a threshold proportional to expected daily inflow. There is **no autonomous refill mechanism on-chain**.

### `seedReserve` is a one-way subsidy

`seedReserve` does **not** mint wON to the donor. The donated funds become part of the reserve and can be paid out via auto-unwrap to ANY future inbound bridge user, or via `unwrap` to ANY existing wON holder — not just back to the donor. Once seeded, the donation is unrecoverable from the donor's perspective unless they independently hold wON they can `unwrap`. Treat `seedReserve` accordingly.

If you want a deposit that is recoverable, use `wrap(amount)` instead — it adds the same liquidity to the reserve AND mints `amount` wON to the depositor, who can later `unwrap` to get their funds back (assuming the reserve still covers it).

### Front-running grief vector

A wON holder can drain the reserve via `unwrap` while another user's BSC→ETH bridge is in flight (~60s LZ delivery), forcing that user onto the wON fallback even when the reserve was full at send time. This is economically neutral to the front-runner (they burn wON for an equal amount of ON) but harmful to the inbound user (they expected real ON). The bridge does not advertise auto-unwrap as a guarantee — integrators should treat it as best-effort. There is no on-chain mitigation; either accept the design or revert auto-unwrap entirely.

### ON-token-pause / blacklist behaviour

If the ON token is paused or blacklists the recipient, the auto-unwrap branch's `safeTransfer` reverts inside `_credit`, making the LayerZero message undeliverable until the lock lifts. The fallback-to-mint branch only fires when the reserve is insufficient, not as a generic try/catch. We do not wrap the transfer in try/catch because the trade-off is debatable (silent fallback hides ON-token incidents from users); operators should monitor delivery health and ensure the ON token doesn't ship a pause without coordination.

### Conservation invariant

At rest (no in-flight messages): every wON in circulation is a claim on real ON locked in `ONOFTAdapter` on BSC. Real ON in `WrappedON.reserve()` represents either (a) a `wrap` deposit (matched 1:1 by minted wON, recoverable by the depositor via `unwrap` while liquidity holds) or (b) a `seedReserve` donation (treasury subsidy, **not** recoverable directly — see "one-way subsidy" above).

## Origin

Scaffolded by copying `examples/oft-adapter` from [`LayerZero-Labs/devtools`](https://github.com/LayerZero-Labs/devtools/tree/main/examples/oft-adapter) (the same template `npx create-lz-oapp -e oft-adapter` produces). `ONOFTAdapter.sol` is **byte-identical** to the upstream template (only constructor pass-through). `WrappedON.sol` **diverges** from the template: it adds the auto-unwrap `_credit` override and the `wrap`/`unwrap`/`seedReserve` surface described above.

## Production configuration decisions (locked in)

- **DVNs**: 2 required, 0 optional → `['LayerZero Labs', 'Google Cloud']`. `metadata-tools` resolves names to per-chain addresses at `lz:oapp:wire` time.
- **Confirmations**: BSC→ETH = 20 (~60s on BSC's ~3s blocks); ETH→BSC = 15 (~3 min on ETH's 12s blocks).
- **Enforced executor options**: 250,000 gas, 0 value on `LZ_RECEIVE` for both directions. Sized to absorb the worst path (composed inbound on ETH with a hooky ON token); unused gas is refunded.
- **Ownership flow**: deploy with EOA, then `lz:oapp:wire`, then transfer `owner` and `setDelegate` to a multisig. Multisig addresses go in `.env` (`OWNER_BSC`, `OWNER_ETH`).
- **wON metadata**: `name = "Wrapped ON"`, `symbol = "wON"`, decimals 18 (OZ ERC20 default).

## Toolchain

| Tool | Version | Notes |
|------|---------|-------|
| Node | ≥18.16 | See `.nvmrc` |
| Hardhat | 2.28.6 | Required for `lz:oapp:wire` (applies DVN/executor/enforced-options config) |
| Foundry | latest stable | For unit/integration tests via `forge test` |
| Solidity | `0.8.22` (exact) | Production contracts use `pragma solidity 0.8.22;` (no caret); pinned in both `foundry.toml` and `hardhat.config.ts` |

Both Hardhat and Foundry are kept. Hardhat does deploy + wire; Foundry does fast tests.

### Cross-toolchain bytecode determinism

Hardhat and Foundry must produce **identical bytecode** for Etherscan / BSCScan source verification to succeed against either toolchain. The following are pinned in both `foundry.toml` and `hardhat.config.ts`:

- `solc` / `solidity.version` = `0.8.22`
- `evm_version` / `evmVersion` = `'shanghai'` (highest target solc 0.8.22 supports; both Ethereum and BSC mainnet support shanghai opcodes including PUSH0)
- `bytecode_hash` / `metadata.bytecodeHash` = `'ipfs'`
- `optimizer_runs` / `optimizer.runs` = `20_000`

Don't edit one without the other.

## License

Apache-2.0. See `LICENSE` at the repo root and the `SPDX-License-Identifier` headers on every `.sol` file.

## Repository layout

```
bridge/
├── contracts/
│   ├── ONOFTAdapter.sol     ← BSC: pass-through over OFTAdapter (LZ template, unchanged)
│   ├── WrappedON.sol        ← ETH: OFT + reserve-backed auto-unwrap, wrap/unwrap/seedReserve
│   └── mocks/
├── deploy/
│   ├── ONOFTAdapter.ts      ← deploys ONOFTAdapter on networks with `oftAdapter.tokenAddress` set
│   ├── WrappedON.ts         ← deploys WrappedON (wON) on networks with `wrappedOft.reserveAddress` set
│   └── MyERC20Mock.ts       ← test-only mock token deploy (unused on mainnet)
├── tasks/
│   ├── sendOFT.ts           ← `hardhat send` task: quote + approve + send
│   ├── sendEvm.ts
│   └── ...
├── test/                    ← Foundry + Hardhat tests
├── foundry.toml
├── hardhat.config.ts        ← networks: bsc (oftAdapter.tokenAddress) + ethereum (wrappedOft.reserveAddress)
├── layerzero.config.ts      ← BSC↔ETH pathway, 2 DVNs, confirmations, enforced options
├── package.json
├── .env.example             ← commented placeholders for RPC / keys / multisigs
├── LICENSE                  ← Apache-2.0
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
- **OFT decimals must match.** `WrappedON` defaults to 18 (OZ ERC20). Real ON on BSC is 18 — reconfirm via `cast call $ON_BSC "decimals()(uint8)" --rpc-url $RPC_URL_BSC`. Mismatch → silent dust loss via `decimalConversionRate`.
- **ETH reserve token must be 18 decimals.** `WrappedON` constructor reverts with `DecimalsMismatch` if the supplied ETH ON contract does not return 18. Reconfirm via `cast call 0x33f6...B59d "decimals()(uint8)" --rpc-url $RPC_URL_ETH` before deploy.
- **Only ONE OFTAdapter per global mesh.** BSC is it. If a third chain is added later, deploy another `WrappedON` (mintable), never another adapter.
- **Endpoint V2 address.** `0x1a44076050125825900e736c501f859c50fE728c` on every supported EVM mainnet/testnet. The Hardhat plugin pulls this automatically based on `eid`.
- **Approval before send (BSC side).** Users must `approve(adapter, amount)` on the ON token before calling `send()` on `ONOFTAdapter`.
- **Multisig hand-off.** Deployer EOA owns the contracts until step 5–6 of the post-deploy checklist. Don't go live without finishing the hand-off.

## What we deliberately did NOT do

- No custom logic in `ONOFTAdapter.sol` — byte-identical to the LZ template.
- No `MintBurnOFTAdapter` / `NativeOFTAdapter`.
- No LayerZero V1.
- No autonomous reserve refill / no on-chain liquidity oracle. Treasury monitors and refills off-chain.

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
- [ ] Confirm pre-existing ETH ON at `0x33f6...B59d` `decimals() == 18` (deploy reverts otherwise).
- [ ] Confirm Google Cloud DVN is live on both BSC and Ethereum mainnet (check https://docs.layerzero.network/v2/deployments/dvn-addresses).
- [ ] Decide multisig threshold + signers; have the multisig deployed on both chains.
- [ ] Decide reserve seeding strategy: how much real ETH ON to commit on day-1, who funds it, what the low-water alert threshold is.
