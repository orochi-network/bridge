# Project: ON Cross-Chain Bridge (BSC ↔ Ethereum)

## Hard rules for AI assistants

- **Never read, write, edit, `cat`, `grep`, `head`, `tail`, or otherwise inspect `.env`** (or any other dotenv file: `.env.local`, `.env.production`, etc.). It contains the deployer `PRIVATE_KEY` / `MNEMONIC`, archive RPC URLs with embedded API keys, and Etherscan/BSCScan API keys. Treat it as if it were not on the filesystem. If a task seems to require its contents, ask the user to paste only the specific value they want you to use — never request the file. `.env.example` (committed, placeholders only) is fine.

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

Scaffolded by copying `examples/oft-adapter` from [`LayerZero-Labs/devtools`](https://github.com/LayerZero-Labs/devtools/tree/main/examples/oft-adapter) (the same template `npx create-lz-oapp -e oft-adapter` produces). `ONOFTAdapter.sol` **diverges** from the upstream template only in `_debit` (FoT balance-delta guard + `RateLimiter` integration); `_credit` is inherited from `OFTAdapter` unchanged. `WrappedON.sol` **diverges** by adding the auto-unwrap `_credit` override (with the upstream `OFT._credit:83` `address(0) → 0xdead` redirect kept verbatim), the `wrap`/`unwrap`/`seedReserve` surface, and the same `RateLimiter` integration.

## Rate limiting

Both contracts mix in `@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter`. **Outbound only** (per-EID, sliding window with linear decay); inbound is intentionally NOT rate-limited because an arrived message is the tail of an already-debited outbound, so throttling can only brick LayerZero delivery. Owner-only: `setRateLimits(RateLimitConfig[])`, `resetRateLimits(uint32[])`. Unconfigured EIDs (`limit==0 && window==0`) are **fail-open**, so a fresh deploy is usable from block one; the multisig sets production limits via `setRateLimits` immediately after the multisig handoff (Step 7 of the post-deploy checklist below; README Step 13). Failure mode: `RateLimitExceeded()` reverts on the source-chain `send` call before any LayerZero plumbing engages, so users keep their funds. `setRateLimits` rejects every `(limit>0, window<60)` shape with `InvalidRateLimitConfig` — covers both the upstream silent-disable `(limit>0, window=0)` case (div-by-zero guard substitutes `window=1` and refills every second) and any sub-block-time window where upstream's linear decay would refill the bucket every block. The all-zero `(0, 0)` sentinel and the deny-all pause idiom (`limit=1, window=type(uint64).max`) remain accepted — `(0, 0)` is NOT a pause, write the deny-all to halt an EID (see README "Pausing an EID"). See README "Rate limiting" for sizing guidance and the multisig workflow.

## Production configuration decisions (locked in)

- **DVNs**: 2 required, 0 optional → `['LayerZero Labs', 'Google']`. `metadata-tools` resolves these to per-chain addresses at `lz:oapp:wire` time via an **exact (`===`) match on `canonicalName`** in the LZ metadata registry — the same exact-match rule it applies to executor names. The DVN run by Google Cloud is registered under canonicalName `Google` (id `google-cloud`); the marketing name `'Google Cloud'` would not resolve. Liveness probe: `yarn check:dvn`.
- **Confirmations**: BSC→ETH = 30 (~90s on BSC's ~3s blocks; raised from 20 to clear historical reorg depth); ETH→BSC = 15 (~3 min on ETH's 12s blocks).
- **Enforced executor options**: `LZ_RECEIVE` enforced for both `msgType 1` (SEND) and `msgType 2` (SEND_AND_CALL). ETH-inbound: 300,000 gas; BSC-inbound: 250,000 gas. `lzCompose` gas is NOT enforced (application-specific; integrators must supply their own `addExecutorLzComposeOption` when using `composeMsg`). Unused gas is refunded by the executor.
- **Ownership flow**: deploy with EOA, then `lz:oapp:wire`, then transfer `owner` and `setDelegate` to a multisig. Multisig addresses go in `.env` (`OWNER_BSC`, `OWNER_ETH`).
- **wON metadata**: `name = "Wrapped ON"`, `symbol = "wON"`, decimals 18 (OZ ERC20 default).

## Toolchain

| Tool | Version | Notes |
|------|---------|-------|
| Node | ≥18.16 | See `.nvmrc` (currently `v18.18.0`). Provides `corepack`. |
| Yarn | 4.14.1 | Provisioned via `corepack` from the `packageManager` field in `package.json`. **Nothing under `.yarn/` is committed** — `.gitignore` excludes it; `corepack` materialises the binary on first invocation. `.yarnrc.yml` carries the `nodeLinker: node-modules`, `packageExtensions` (silencing benign upstream LZ peer-dep warnings), and `logFilters` config. |
| Hardhat | 2.28.6 | Required for `lz:oapp:wire` (applies DVN/executor/enforced-options config) |
| Foundry | latest stable | For unit/integration tests via `forge test` |
| Solidity | `0.8.34` (exact) | Production contracts use `pragma solidity 0.8.34;` (no caret); pinned in both `foundry.toml` and `hardhat.config.ts`. Hardhat 2.28.6 prints a "0.8.34 is not fully supported yet" warning — this only degrades stack traces; bytecode is correct. |

Both Hardhat and Foundry are kept. Hardhat does deploy + wire; Foundry does fast tests.

### Cross-toolchain bytecode determinism

Hardhat and Foundry must produce **identical bytecode** for Etherscan / BSCScan source verification to succeed against either toolchain. The following are pinned in both `foundry.toml` and `hardhat.config.ts`:

- `solc` / `solidity.version` = `0.8.34`
- `evm_version` / `evmVersion` = `'cancun'` (Ethereum Cancun shipped 2024-03-13; BSC Tycho hardfork shipped Cancun-equivalent semantics including EIP-1153 on 2024-06-20 via BEP-343, so PUSH0 + TLOAD/TSTORE are safe on both mainnets — `WrappedON._composedFlag` uses transient storage)
- `bytecode_hash` / `metadata.bytecodeHash` = `'ipfs'`
- `optimizer_runs` / `optimizer.runs` = `20_000`

Don't edit one without the other. CI enforces this on every PR via `.github/workflows/bytecode-diff.yml` + `scripts/check-bytecode.js`: it strips the CBOR metadata trailer (which embeds an IPFS hash that is path-dependent and legitimately differs between toolchains) and asserts the runtime bytecode is byte-identical. The IPFS hash divergence is reported informationally; a runtime mismatch fails the workflow.

## License

Apache-2.0. See `LICENSE` at the repo root and the `SPDX-License-Identifier` headers on every `.sol` file.

## Repository layout

```
bridge/
├── contracts/
│   ├── ONOFTAdapter.sol     ← BSC: OFTAdapter + FoT _debit guard + RateLimiter (outbound); _credit inherited unchanged
│   ├── WrappedON.sol        ← ETH: OFT + reserve-backed auto-unwrap, wrap/unwrap/seedReserve
│   └── mocks/
├── deploy/
│   ├── ONOFTAdapter.ts      ← deploys ONOFTAdapter on networks with `oftAdapter.tokenAddress` set
│   ├── WrappedON.ts         ← deploys WrappedON (wON) on networks with `wrappedOft.reserveAddress` set
│   └── MyERC20Mock.ts       ← test-only mock token deploy (unused on mainnet)
├── tasks/
│   ├── sendOFT.ts           ← `lz:oft:send` task: quote + approve + send
│   ├── sendEvm.ts
│   ├── handoff.ts           ← `lz:oapp:handoff` — atomic, idempotent setDelegate + transferOwnership
│   └── ...
├── scripts/
│   ├── check-bytecode.js    ← Hardhat vs Foundry runtime bytecode diff (strips CBOR metadata)
│   └── check-dvn.js         ← pre-deploy DVN liveness probe (LZ metadata registry + RPC)
├── docs/
│   ├── ARCHITECTURE.md      ← LayerZero message-flow diagrams + _credit decision tree
│   ├── PROTOCOL.md          ← fee model, DVN/Executor sourcing decisions
│   └── SECURITY.md          ← audit findings, fixes, operator obligations
├── test/                    ← Foundry + Hardhat tests
├── .github/
│   └── workflows/bytecode-diff.yml  ← CI: enforces cross-toolchain bytecode determinism
├── foundry.toml
├── hardhat.config.ts        ← networks: bsc (oftAdapter.tokenAddress) + ethereum (wrappedOft.reserveAddress)
├── layerzero.config.ts      ← BSC↔ETH pathway, 2 DVNs, confirmations, enforced options
├── package.json             ← `packageManager: yarn@4.14.1` (corepack)
├── .yarnrc.yml              ← yarn 4 config (nodeLinker, packageExtensions, logFilters)
├── yarn.lock
├── .env.example             ← commented placeholders for RPC / keys / multisigs
├── LICENSE                  ← Apache-2.0
└── CLAUDE.md                ← this file
```

## Common commands

```sh
# One-time setup
cp .env.example .env         # fill in PRIVATE_KEY (or MNEMONIC) and RPC URLs
yarn install --immutable     # reproduces yarn.lock exactly; fails if it would drift (yarn 4 via packageManager field)
yarn compile                 # Hardhat + Foundry compile

# Tests
yarn test                    # forge test + hardhat test

# Deploy
npx hardhat lz:deploy        # CLI prompts for networks; pick `bsc` and `ethereum`
                             # → BSC deploys ONOFTAdapter, ETH deploys WrappedON (wON)

# Wire (sets peers + DVNs + executor + enforced options on both sides)
npx hardhat lz:oapp:wire --oapp-config layerzero.config.ts

# Verify peers
npx hardhat lz:oapp:peers:get --oapp-config layerzero.config.ts

# Hand off owner + delegate to the multisig (atomic, idempotent)
npx hardhat lz:oapp:handoff --network bsc --contract ONOFTAdapter
npx hardhat lz:oapp:handoff --network ethereum --contract WrappedON

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
5. ✅ Run `lz:oapp:handoff` on each network to atomically `setDelegate(multisig)` then `transferOwnership(multisig)` (correct order; the task is idempotent, refuses to run if the current owner is unexpected, and self-verifies `lz:oapp:wire` completion via the `peers(remoteEid)` and `endpoint.delegates(oapp)` pre-flight checks before transferring). Reads multisig from `OWNER_BSC` / `OWNER_ETH`.
6. ✅ Have multisig signers confirm they can call admin functions (sanity check).
7. ✅ Multisig calls `setRateLimits` on both contracts to apply production caps for the BSC↔ETH pathway. Until this runs, both EIDs are unconfigured and unlimited (see "Rate limiting" above).

Steps 1–5 should run in a single operator session — every minute the deployer EOA holds `owner` is a minute a hot-key compromise can rewire peers or forge messages.

## Important gotchas

- **OFTAdapter requires a lossless inner token.** ON on BSC must NOT be fee-on-transfer or rebasing. The adapter assumes `transferFrom(amount)` actually moves `amount`. **Verify with a forked-mainnet test before production.**
- **OFT decimals must match.** `WrappedON` defaults to 18 (OZ ERC20). Real ON on BSC is 18 — reconfirm via `cast call $ON_BSC "decimals()(uint8)" --rpc-url $RPC_URL_BSC`. Mismatch → silent dust loss via `decimalConversionRate`.
- **ETH reserve token must be 18 decimals.** `WrappedON` constructor reverts with `DecimalsMismatch` if the supplied ETH ON contract does not return 18. Reconfirm via `cast call 0x33f6...B59d "decimals()(uint8)" --rpc-url $RPC_URL_ETH` before deploy.
- **Only ONE OFTAdapter per global mesh.** BSC is it. If a third chain is added later, deploy another `WrappedON` (mintable), never another adapter.
- **Endpoint V2 address.** `0x1a44076050125825900e736c501f859c50fE728c` on every supported EVM mainnet/testnet. The Hardhat plugin pulls this automatically based on `eid`.
- **Approval before send (BSC side).** Users must `approve(adapter, amount)` on the ON token before calling `send()` on `ONOFTAdapter`.
- **Multisig hand-off.** Deployer EOA owns the contracts until step 5 of the post-deploy checklist (`lz:oapp:handoff`). Don't go live without finishing the hand-off — until then, the deploy key can rewire peers and forge inbound messages.

## CI

- **`.github/workflows/bytecode-diff.yml`** — runs on every push to `main` and on PRs that touch `contracts/`, `foundry.toml`, `hardhat.config.ts`, the bytecode script, the workflow itself, `package.json`, or `yarn.lock`. Provisions yarn 4 via `corepack prepare yarn@4.14.1 --activate` (NOT just `corepack enable`, because GHA's ubuntu-latest pre-installs yarn classic 1.22 and the classic shim wins on PATH unless we explicitly activate). Caches `.yarn/cache` keyed on `yarn.lock` via `actions/cache@v4` rather than `setup-node`'s `cache: 'yarn'` (which would query yarn classic for the cache folder *before* corepack runs). Compiles with both Hardhat and Foundry, then asserts byte-identical runtime bytecode.

## Security posture

Full audit findings, fixes, decisions, and operator obligations are in [docs/SECURITY.md](./docs/SECURITY.md). Read it before any production change. Vulnerability reports: chiro@orochi.network.

Status snapshot of the audit findings (current branch state, post-RateLimiter merge in `d61f5e1`):

**Fixed in code (HIGH).**
- **H1** Asymmetric fee-on-transfer protection — balance-delta guards in both `ONOFTAdapter._debit` and `WrappedON._credit` (auto-unwrap branch reverts with `UnexpectedTransferAmount` on mismatch; fallback-to-mint applies only when the reserve is insufficient, not on a delta mismatch).
- **H2** Manual ownership / delegate handoff — automated and made idempotent by `tasks/handoff.ts` (`lz:oapp:handoff`), with pre-flight checks that the OApp is wired before transferring.
- **H3** BSC→ETH confirmations 20 → 30 to clear historical reorg depths.

**Fixed in code (MEDIUM).**
- **M1** `_lzReceive` composed branch duplicated upstream logic — refactored to a transient flag + `super._lzReceive`, so `UnwrapFallbackToMint` no longer false-positives on every composed message.
- **M2** Enforced executor gas symmetric and missing for composed sends — split per-leg AND per-msgType (BSC inbound 250k; ETH inbound 300k for `msgType 1` and `msgType 2`).
- **M4** `_credit` recipient handling — matches upstream LayerZero exactly. `ONOFTAdapter` does not override `_credit`; `WrappedON._credit` keeps only the upstream `OFT._credit:83` `address(0) → 0xdead` redirect. Bad recipients are an operator obligation; see SECURITY.md M4.
- **M5** No throttle on outbound flow per EID — LayerZero `RateLimiter` mixed in on both contracts (outbound only, per-EID, owner-only setters; unconfigured EIDs are fail-open so a fresh deploy is usable until the multisig dials in caps; `(0, 0)` is the unconfigured sentinel and is NOT a pause — see README "Pausing an EID" for the deny-all idiom).

**Fixed in code (LOW / cleanup).** Exact `0.8.34` pragma pin in mocks; `MyERC20Mock` deploy gated to non-live networks; DVN canonical name `'Google Cloud'` → `'Google'` (the metadata registry uses an exact canonicalName match); pre-deploy `yarn check:dvn` script; bytecode-diff CI (`yarn check:bytecode`) asserting Hardhat/Foundry runtime parity.

**Decision (no code change).**
- **M3** DVN config kept at 2-required + 0-optional. A delivery failure must be visible and triaged, not silently routed around. A third DVN would only be added if liveness incidents outweighed the per-message DVN fee, which is not the case at the bridge's current message profile.

**Resolved (no further action).**
- ETH ON token migration plan — both ON tokens are immutable on their deployed addresses, the issuer confirmed no upgrade path, and the on-chain delta guards re-assert losslessness on every send / `wrap` / `seedReserve` so any future deviation surfaces as an explicit revert.

**Outstanding (operator obligations, not code).**
- Pre-deploy: run `yarn test:dryrun` and `yarn check:dvn` against archive RPCs.
- Compress deploy → `lz:oapp:wire` → `lz:oapp:handoff` into a single operator session — every minute the deployer EOA holds `owner` is exposure.
- Post-handoff: multisig calls `setRateLimits` on both contracts (Step 7 in the post-deploy checklist). Until then, both EIDs are unconfigured → unlimited.
- Monitor `WrappedON.reserve()` against an agreed daily-flow threshold; refill via `wrap` (recoverable) or `seedReserve` (one-way subsidy).
- Monitor cumulative outbound flow per EID off-chain — the on-chain RateLimiter only bounds a single window, not a multi-window sustained drain.
- Subscribe to `UnwrapFallbackToMint` event alerts; after the M1 fix, every emission indicates a depleted reserve (the FoT-delta path reverts, it does not emit).
- Coordinate with the ON token issuer on both chains before any pause / upgrade / blacklist change.

## What we deliberately did NOT do

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

## Forked-mainnet dry-run

`test/foundry/DryRun.t.sol` forks BSC + ETH mainnet, deploys both contracts
against the real ON tokens, and exercises the full bridge flow end-to-end
(BSC→ETH plain, BSC→ETH with seeded reserve, BSC→ETH composed, ETH→BSC round
trip, wrap/unwrap/seedReserve, plus explicit lossless-inner-token and decimals
checks). Real DVN/Executor infrastructure is bypassed — destination delivery
is simulated by impersonating the LayerZero endpoint, so only the on-chain
logic of the bridge contracts (and of the real ON tokens) is exercised.

```sh
RPC_URL_BSC=https://... RPC_URL_ETH=https://... yarn test:dryrun
```

The test skips cleanly if either RPC env var is unset, so `yarn test` stays
green without RPC credentials. Run the dry-run before every mainnet deploy.

## Things still to fill in before production deploy

- [ ] `.env` — `PRIVATE_KEY` (deployer), `RPC_URL_BSC`, `RPC_URL_ETH`, `BSCSCAN_API_KEY`, `ETHERSCAN_API_KEY`, `OWNER_BSC`, `OWNER_ETH`.
- [ ] Run `yarn test:dryrun` against archive RPCs — covers BSC ON lossless transfer, ETH ON 18 decimals, full BSC↔ETH bridge flow, auto-unwrap vs fallback vs composed paths, manual wrap/unwrap/seedReserve.
- [ ] Run `yarn check:dvn` against archive RPCs — fetches the LZ metadata registry, resolves `LayerZero Labs` and `Google` DVN canonical names per chain, and probes that each contract has bytecode and responds to `quorum()` on BSC and Ethereum mainnet.
- [ ] Decide multisig threshold + signers; have the multisig deployed on both chains.
- [ ] Decide reserve seeding strategy: how much real ETH ON to commit on day-1, who funds it, what the low-water alert threshold is.
