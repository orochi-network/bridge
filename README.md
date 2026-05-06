# ON Cross-Chain Bridge — BSC ↔ Ethereum

LayerZero V2 OFT bridge for the **ON** token.

| Chain | Contract | Token | Role |
|-------|----------|-------|------|
| **BSC** mainnet | `ONOFTAdapter` | wraps existing [`ON`](https://bscscan.com/address/0x0e4F6209eD984b21EDEA43acE6e09559eD051D48) at `0x0e4F...1D48` | Locks ON on outbound; releases on inbound. |
| **Ethereum** mainnet | `WrappedON` | mints/burns `wON` ("Wrapped ON"); holds `ON` reserve | Auto-unwraps to real ON when reserve covers, else mints wON. Manual `wrap` / `unwrap` / `seedReserve`. |

Architecture rationale and the rejected alternatives are documented in [CLAUDE.md](./CLAUDE.md). Trust assumptions, audit findings, and operator obligations are in [SECURITY.md](./SECURITY.md) — read it before any production change. To report a vulnerability: chiro@orochi.network.

---

## Prerequisites

- **Node** ≥ 18.16 (`nvm use` will pick up `.nvmrc`)
- **Foundry** (for tests) — `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- A funded **deployer EOA** with native gas on **both** BSC and Ethereum (≈ 0.05 BNB and ≈ 0.05 ETH covers everything below comfortably)
- **Multisig** (e.g. Safe) deployed on both chains — addresses needed for the post-deploy ownership transfer
- RPC endpoints for BSC and Ethereum mainnet (Alchemy / Infura / QuickNode / your own node — public RPCs work for testing but rate-limit aggressively)
- Etherscan + BSCScan API keys (optional, for source verification)

---

## Step 1 — Clone and install

```sh
git clone <this-repo> bridge
cd bridge
yarn install           # yarn.lock is the canonical lockfile (yarn 4 via packageManager field)
```

## Step 2 — Configure `.env`

```sh
cp .env.example .env
```

Fill in:

```sh
PRIVATE_KEY=0x<deployer private key, 0x-prefixed>
RPC_URL_BSC=https://bsc-mainnet.g.alchemy.com/v2/<key>
RPC_URL_ETH=https://eth-mainnet.g.alchemy.com/v2/<key>
BSCSCAN_API_KEY=<for source verification>
ETHERSCAN_API_KEY=<for source verification>
OWNER_BSC=0x<multisig that should own ONOFTAdapter>
OWNER_ETH=0x<multisig that should own WrappedON (wON)>
```

> Use `MNEMONIC=` instead of `PRIVATE_KEY` if you prefer; either works.

## Step 3 — Sanity-check both ON tokens

The bridge has two preconditions enforced or assumed at deploy time. **Both must hold** or the bridge will misbehave or fail to deploy.

### 3a. BSC ON (locked by `ONOFTAdapter`)

The `ONOFTAdapter` model assumes the inner token is **lossless** and **18 decimals**. Lossless is _not_ enforced on-chain — confirm by hand:

```sh
# Decimals must be 18
cast call 0x0e4F6209eD984b21EDEA43acE6e09559eD051D48 "decimals()(uint8)" \
  --rpc-url $RPC_URL_BSC

# Transfer-fee sanity: simulate transferFrom of 1e18 wei from a holder.
# If the resulting balance change is anything other than 1e18, ON has a fee/rebase
# and the bridge will silently lose tokens — STOP and reconsider.
```

If `decimals` ≠ 18 or the token has a transfer tax, **do not deploy**. Open an issue and re-evaluate.

### 3b. ETH ON (held as the unwrap reserve by `WrappedON`)

`WrappedON`'s constructor reverts with `DecimalsMismatch(actual)` if the reserve token does not return 18 — that's enforced. Fee-on-transfer behaviour is **not** caught at construction, but `wrap` / `seedReserve` revert with `UnexpectedTransferAmount` at call time if the actual transferred amount differs from the requested amount.

```sh
# Decimals must be 18 (enforced)
cast call 0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d "decimals()(uint8)" \
  --rpc-url $RPC_URL_ETH

# Same fee/rebase sanity check as 3a — the auto-unwrap path will revert
# inside _credit if a transfer charges fees, leaving the LZ message
# undeliverable until the reserve is empty (fallback to mint).
```

If either chain's ON has unexpected behaviour, do not deploy. The forked dry-run in [Step 5](#step-5--forked-mainnet-dry-run) re-runs both checks programmatically against actual mainnet state.

## Step 4 — Compile

```sh
yarn compile           # Hardhat + Foundry parallel compile
yarn test              # forge test + hardhat test
```

Both must pass before proceeding.

## Step 5 — Forked-mainnet dry-run

Before deploying for real, run the full bridge flow end-to-end against forked copies of BSC and Ethereum mainnet. The dry-run deploys both contracts against the **real** ON tokens on each fork and exercises every code path: BSC→ETH plain / seeded reserve / composed, ETH→BSC round trip, and the manual `wrap` / `unwrap` / `seedReserve` surface. It also asserts the Step 3 preconditions (BSC ON is lossless; ETH ON reports 18 decimals) on actual mainnet state. Real DVN/Executor infrastructure is bypassed — destination delivery is simulated by impersonating the LayerZero endpoint, so only the on-chain logic of the bridge contracts and the real ON tokens is exercised.

```sh
yarn test:dryrun           # picks up RPC_URL_BSC and RPC_URL_ETH from .env
```

Expect 7 passing tests in ~20 seconds against archive-quality RPCs. The test skips cleanly if either RPC env var is unset, so `yarn test` stays green without RPC credentials.

**If any test fails, do not deploy.** Most common failure modes:

| Failing test | What it means |
|---|---|
| `test_bsc_innerToken_isLossless` | BSC ON has a transfer fee or rebases. The default `OFTAdapter` cannot handle this; the bridge will leak backing on every send. Stop and reconsider Solution 3. |
| Constructor reverts with `DecimalsMismatch` | ETH ON does not return 18 decimals. Stop; the OFT decimal model assumes 18. |
| `test_bridge_*` reverts inside `quoteSend` / `send` | The RPC is missing state needed by the LayerZero endpoint (default send library, DVN config). Use an archive-quality RPC. |

Re-run the dry-run whenever the contracts, the ON token addresses, or the LZ endpoint configuration change. Implementation lives in [`test/foundry/DryRun.t.sol`](./test/foundry/DryRun.t.sol).

### 5b. Verify required DVNs are live

The bridge requires both `LayerZero Labs` and `Google` (the DVN run by Google Cloud) to attest before a message is delivered. If either is unavailable on either chain at deploy time, `lz:oapp:wire` will write a config that cannot deliver messages. Run:

```sh
yarn check:dvn             # picks up RPC_URL_BSC and RPC_URL_ETH from .env
```

The script fetches the [LayerZero metadata registry](https://metadata.layerzero-api.com/v1/metadata) (the same source `metadata-tools` uses at wire time), resolves each required DVN's canonical name to its per-chain address, then on each mainnet:

- confirms the resolved address has bytecode,
- calls `quorum()` to confirm the DVN responds.

It exits non-zero if anything is missing. Run it again immediately before `lz:oapp:wire` (Step 9) — it's the last opportunity to catch a DVN that has been deprecated or rotated since you last checked.

## Step 6 — Deploy `ONOFTAdapter` on BSC

```sh
npx hardhat lz:deploy --networks bsc --tags ONOFTAdapter
```

The deploy script reads `oftAdapter.tokenAddress` from `hardhat.config.ts` (already set to `0x0e4F...1D48`) and constructs:

```solidity
new ONOFTAdapter(
    0x0e4F6209eD984b21EDEA43acE6e09559eD051D48,           // ON token on BSC
    0x1a44076050125825900e736c501f859c50fE728c,           // LayerZero EndpointV2
    deployer                                              // initial owner + delegate
)
```

Address is written to `deployments/bsc/ONOFTAdapter.json`. **Save it** for Etherscan verification.

## Step 7 — Deploy `WrappedON` (wON) on Ethereum

```sh
npx hardhat lz:deploy --networks ethereum --tags WrappedON
```

This deploys the wrapped representation:

```solidity
new WrappedON(
    "Wrapped ON",                                         // name
    "wON",                                                // symbol
    0x1a44076050125825900e736c501f859c50fE728c,           // LayerZero EndpointV2
    deployer,                                             // initial owner + delegate
    0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d            // pre-existing ETH ON used as the unwrap reserve
)
```

Address is written to `deployments/ethereum/WrappedON.json`. The constructor reverts with `DecimalsMismatch(actual)` if the reserve token does not report 18 decimals — verify before retrying.

## Step 8 — Verify source code on the explorers

```sh
# BSC
npx hardhat verify --network bsc <ADAPTER_ADDR> \
  "0x0e4F6209eD984b21EDEA43acE6e09559eD051D48" \
  "0x1a44076050125825900e736c501f859c50fE728c" \
  "<DEPLOYER_ADDR>"

# Ethereum
npx hardhat verify --network ethereum <WON_ADDR> \
  "Wrapped ON" "wON" \
  "0x1a44076050125825900e736c501f859c50fE728c" \
  "<DEPLOYER_ADDR>" \
  "0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d"
```

> API keys are read from `.env` via the `etherscan` block in `hardhat.config.ts`. Hardhat-verify routes by chainId, so the `mainnet` key is used for Ethereum and the `bsc` key for BSC.

## Step 9 — Wire (set peers + DVNs + executor + enforced options)

This is the single most important step. It applies the entire `layerzero.config.ts` (peers, two required DVNs, confirmations, enforced `LZ_RECEIVE` options) to both contracts in one run.

```sh
npx hardhat lz:oapp:wire --oapp-config layerzero.config.ts
```

The CLI will:

1. Compute the diff between current on-chain config and `layerzero.config.ts`.
2. Print every transaction it intends to send, grouped by chain.
3. Ask for confirmation.
4. Submit them.

Expect roughly:

- 1× `setPeer` on BSC (peer = wON on Ethereum)
- 1× `setPeer` on Ethereum (peer = adapter on BSC)
- 1× `setConfig` on each side for **send** ULN (DVN = LayerZero Labs + Google [the DVN run by Google Cloud], confirmations)
- 1× `setConfig` on each side for **receive** ULN
- 1× `setEnforcedOptions` on each side (`LZ_RECEIVE` gas, applied to both `msgType: 1` SEND and `msgType: 2` SEND_AND_CALL — BSC inbound = 250k; ETH inbound = 300k for the composed-mint headroom)

If wire fails partway, **rerun it** — it's idempotent and will pick up where it left off.

## Step 10 — Verify peers and config

```sh
npx hardhat lz:oapp:peers:get --oapp-config layerzero.config.ts
npx hardhat lz:oapp:config:get --oapp-config layerzero.config.ts
```

Both sides should show:
- Peer correctly set to the counterpart contract
- Required DVNs: 2 (LayerZero Labs + Google — DVN canonical names; Google here is the DVN run by Google Cloud)
- Confirmations: 30 BSC→ETH, 15 ETH→BSC
- Enforced `LZ_RECEIVE` gas, applied to both `msgType: 1` (SEND) and `msgType: 2` (SEND_AND_CALL): 250,000 on BSC inbound, 300,000 on ETH inbound

## Step 11 — Smoke test with a tiny amount

Bridge a small amount end-to-end **before** transferring ownership. Use a wallet you control on both chains.

```sh
# 0.01 ON, BSC → ETH
# (deployer must first approve the adapter to spend 0.01 ON)
cast send 0x0e4F6209eD984b21EDEA43acE6e09559eD051D48 \
  "approve(address,uint256)" <ADAPTER_ADDR> 10000000000000000 \
  --private-key $PRIVATE_KEY --rpc-url $RPC_URL_BSC

npx hardhat lz:oft:send \
  --network bsc \
  --src-eid 30102 --dst-eid 30101 \
  --to <YOUR_ETH_ADDR> --amount 0.01
```

Watch the message on [LayerZero Scan](https://layerzeroscan.com/) (the task prints the link). When `Status: Delivered`:

```sh
# Confirm wON arrived
cast call <WON_ADDR> "balanceOf(address)(uint256)" <YOUR_ETH_ADDR> \
  --rpc-url $RPC_URL_ETH
```

Then the reverse leg:

```sh
# 0.01 wON, ETH → BSC (no approval needed — wON is mint/burn)
npx hardhat lz:oft:send \
  --network ethereum \
  --src-eid 30101 --dst-eid 30102 \
  --to <YOUR_BSC_ADDR> --amount 0.01
```

After delivery, confirm:
- `wON.totalSupply() == 0` (or back to whatever it was before)
- `ON.balanceOf(adapter) == 0` (or back to whatever it was before)
- Your BSC ON balance restored

If any of these are off, **do not transfer ownership yet** — investigate.

## Step 12 — Transfer ownership and delegate to multisig

Final step. After this, the deployer EOA has no admin power.

```sh
# BSC — atomic setDelegate(OWNER_BSC) + transferOwnership(OWNER_BSC) on ONOFTAdapter
npx hardhat lz:oapp:handoff --network bsc --contract ONOFTAdapter

# Ethereum — atomic setDelegate(OWNER_ETH) + transferOwnership(OWNER_ETH) on WrappedON
npx hardhat lz:oapp:handoff --network ethereum --contract WrappedON
```

The task reads the multisig from `OWNER_BSC` / `OWNER_ETH` in `.env`, calls `setDelegate` first (still requires the deployer as owner), then `transferOwnership`. It refuses to run if the current owner is unexpected and is a no-op if the handoff already completed, so it's safe to re-run from operator automation. It also refuses to run if `lz:oapp:wire` has not been applied on this side — `peers(remoteEid)` must be non-zero and a delegate must be set on the LayerZero endpoint — so the multisig never inherits a partially-wired OApp.

Confirm:

```sh
cast call <ADAPTER_ADDR> "owner()(address)" --rpc-url $RPC_URL_BSC   # → $OWNER_BSC
cast call <WON_ADDR>     "owner()(address)" --rpc-url $RPC_URL_ETH   # → $OWNER_ETH
```

> Steps 6–12 should run in a single operator session. Every minute the deployer EOA holds `owner` is a minute a hot-key compromise can rewire peers or forge messages.

🎉 The bridge is live.

---

## Reserve operations (operator)

`WrappedON` exposes three reserve-management entrypoints. Anyone can call them; the owner does **not** have a privileged path to drain the reserve.

| Function | What it does | Who calls |
|----------|--------------|-----------|
| `seedReserve(amount)` | Pulls `amount` real ON from caller into the reserve. **Does not** mint wON. **One-way subsidy**: the donor gets nothing back; the funds can be paid out to any wON holder via `unwrap` or to any inbound bridge user via auto-unwrap. | Treasury — only when the donation is genuinely intended as overcollateralization, not as a recoverable deposit. For a recoverable deposit use `wrap` instead. |
| `wrap(amount)` | Pulls `amount` real ON from caller, mints `amount` wON to caller. 1:1. Reverts with `UnexpectedTransferAmount` if the ON token is fee-on-transfer. | Legacy ETH ON holders bridging out, or the operator depositing recoverable liquidity. Caller must `approve` first. |
| `unwrap(amount)` | Burns `amount` wON from caller, transfers `amount` real ON to caller. 1:1. Reverts with `ReserveInsufficient` if reserve is dry. | Any wON holder once the reserve has been refilled. |

```sh
# Seed the reserve with 100,000 ON from a treasury wallet
cast send 0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d \
  "approve(address,uint256)" <WON_ADDR> 100000000000000000000000 \
  --private-key $TREASURY_KEY --rpc-url $RPC_URL_ETH
cast send <WON_ADDR> "seedReserve(uint256)" 100000000000000000000000 \
  --private-key $TREASURY_KEY --rpc-url $RPC_URL_ETH

# Read current reserve
cast call <WON_ADDR> "reserve()(uint256)" --rpc-url $RPC_URL_ETH

# User-initiated unwrap (must hold wON)
cast send <WON_ADDR> "unwrap(uint256)" <amount_wei> \
  --private-key $USER_KEY --rpc-url $RPC_URL_ETH
```

**Operator obligations:** sustained net BSC→ETH flow drains the reserve. Off-chain monitoring should alert when `reserve()` falls below an agreed threshold. Refill paths: bridge wON ETH→BSC to unlock real ON on BSC and acquire fresh ETH ON off-chain, or commit treasury ON directly via `seedReserve`. There is no autonomous on-chain refill.

**Known limitations:**
- **Front-running grief.** A wON holder can `unwrap` while a user's BSC→ETH bridge is in flight (~60s LZ delivery), forcing the inbound user onto the wON fallback. Auto-unwrap is best-effort, not guaranteed.
- **ON pause/blacklist.** If the ON token is paused or blacklists the recipient, the auto-unwrap branch reverts inside `_credit`, making the LayerZero message undeliverable until the lock lifts. Operators should monitor delivery health.
- **Composed messages.** `SEND_AND_CALL` always mints wON, even when the reserve covers the amount. The compose handler downstream needs wON for its own logic; auto-unwrap would deliver real ON instead. Recipients of composed messages can call `unwrap` separately.

## End-user send flow (for integrators)

```ts
// BSC → ETH
await ON.approve(ADAPTER, amount)

const sendParam = {
  dstEid: 30101,                          // Ethereum mainnet EID
  to: addressToBytes32(recipient),
  amountLD: amount,
  minAmountLD: amount,                    // OFTAdapter is lossless; min == amount
  extraOptions: '0x',                     // enforced options apply automatically
  composeMsg: '0x',
  oftCmd: '0x',
}

const fee = await adapter.quoteSend(sendParam, false)
await adapter.send(sendParam, fee, refundAddress, { value: fee.nativeFee })
```

Reverse direction (ETH → BSC) is identical against `wON` — no `approve` needed since wON is burned from the caller directly.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `lz:deploy` says "oftAdapter not configured, skipping" on Ethereum | Working as intended — ETH only deploys `WrappedON`, BSC only deploys `ONOFTAdapter` | none |
| `lz:oapp:wire` shows zero diff after deploy | Already wired — re-running is a no-op | none |
| Send tx reverts with `LZ_DefaultSendLibUnavailable` or similar | Wire step never ran or failed | Run `lz:oapp:wire` |
| Send succeeds on source but never delivers on destination | DVN issue, executor underfunded, or insufficient confirmations elapsed | Check [LayerZero Scan](https://layerzeroscan.com/), ensure both DVNs attested. Default confirmations take ≈ 90s (BSC→ETH, 30 confs × ~3s) and ≈ 3min (ETH→BSC, 15 confs × ~12s). |
| `transferFrom` reverts inside `send()` | User didn't `approve(adapter, amount)` on the ON token | Approve first |
| wON balance on ETH doesn't match expected amount | Decimal mismatch — almost certainly impossible since both are 18, but if a future ON deploys with different decimals it WILL silently lose dust | Check `decimalConversionRate()` on both contracts |

For deep debugging see [LayerZero V2 docs — Debugging](https://docs.layerzero.network/v2/developers/evm/troubleshooting/debugging-messages).

---

## License

Apache-2.0. See [`LICENSE`](./LICENSE).
