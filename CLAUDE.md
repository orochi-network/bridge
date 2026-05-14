# CLAUDE.md — Orochi Network ON Bridge

This file is project memory for Claude Code working in this repository. Keep it short. Update when conventions or constraints change.

## What this is

A Foundry project implementing a **Chainlink CCIP Cross-Chain Token (CCT) bridge** for the Orochi Network **ON** token between Ethereum Mainnet and BNB Smart Chain.

- **BSC side**: stock `LockReleaseTokenPool` against the existing ON token. `acceptLiquidity = false` on construction — `withdrawLiquidity` is permanently disabled.
- **Ethereum side**: stock `BurnMintTokenPool` against a new **wON** token (this repo's only custom contract).
- **wON** is also a 1:1 wrapper holding a reserve of native ETH-side ON. `deposit` mints wON 1:1 against deposited ON; `withdraw` burns wON and returns ON when the reserve allows.

## Token addresses (canonical)

- ON on Ethereum Mainnet: `0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d` (600M, 18 decimals, **non-mintable**).
- ON on BSC Mainnet:      `0x0e4F6209eD984b21EDEA43acE6e09559eD051D48` (100M, 18 decimals).

## CCIP chain selectors

- Ethereum Mainnet: `5009297550715157269`
- BSC Mainnet: `11344663589394136015`
- Sepolia / BSC Testnet: resolved in `script/Helper.sol` — verify against https://docs.chain.link/ccip/directory at deploy time.

## Secrets handling

**Never read `.env`, `.env.local`, or any `.env.*` file in this repo.** Don't `cat`, `Read`, `head`, `grep`, or otherwise dump their contents to stdout or into the conversation — they hold live RPC API keys and the deployer private key. If you need to know which variables exist, refer to `.env.example` (which only has placeholders). If a deployment script needs an env var, just invoke `forge script` and let the user/shell pass it in.

## Conventions

- **Solidity 0.8.34, optimizer 200, evm_version = cancun.** Library files in `lib/` use `^0.8.24` (patched from exact `0.8.24` to allow compilation with 0.8.34). Re-run the patch if `forge install` resets them: `find lib -name "*.sol" | xargs sed -i 's/^pragma solidity 0\.8\.24;/pragma solidity ^0.8.24;/'`
- **Use stock Chainlink contracts** for `BurnMintTokenPool` and `LockReleaseTokenPool`. Do NOT subclass — extra inheritance increases audit surface for zero functional gain.
- **Only one custom contract**: `src/WrappedON.sol`. Keep it small. New custom contracts require justification.
- **Decimals**: ON and wON are both 18. `localTokenDecimals = 18` on both pools. No remote scaling needed.
- **Roles on wON**: `MINTER_ROLE` and `BURNER_ROLE` go ONLY to the `BurnMintTokenPool` on Ethereum. `DEFAULT_ADMIN_ROLE` starts on deployer, then transfers to the ops multisig after wiring.
- **No upgrades**: contracts are non-upgradeable by design. Migration path = redeploy + re-register in `TokenAdminRegistry` + `applyChainUpdates`.

## Reserve invariant (wON)

There are TWO mint paths for wON; both produce identical fungible tokens but back differently:

1. `deposit(amount)` — user pulls native ETH ON; wON minted is backed by ON held in this contract's reserve.
2. `mint(...)` — CCIP pool mints when value arrives from BSC; backing is ON locked on the BSC `LockReleaseTokenPool`.

Documented invariant: `wrapBackedSupply <= ON.balanceOf(WrappedON)`. `withdraw` reverts when `ON.balanceOf(this) < amount`. CCIP-bridged users who want native ETH ON depend on someone else having wrapped — this is an arbitrage layer, not a guaranteed redemption.

## Layout

```
src/WrappedON.sol                 the only custom contract
script/Helper.sol                 per-chain CCIP config (router, RMN, registry, selectors)
script/Deployments.sol            JSON artifact read/write helper
script/01_DeployWrappedON.s.sol   ETH only — deploys wON
script/02_DeployPools.s.sol       both chains — chain-dispatched on block.chainid
script/03_GrantRoles.s.sol        ETH only — grants MINTER/BURNER on wON to the pool
script/04_RegisterAdminAndPool.s.sol  both chains — probes getCCIPAdmin / Ownable / proposeAdministrator
script/05_ApplyChainUpdates.s.sol both chains — wires remote pool + rate limits
script/06_TransferOwnership.s.sol both chains — handoff to multisig (TransferOwnership + RenounceDeployerAdmin contracts)
script/07_UpdateRateLimits.s.sol  ops — adjust setChainRateLimiterConfig (env-driven)
script/08_PostDeployVerify.s.sol  view-only — programmatic check of all wiring
test/WrappedON.t.sol              unit tests (18)
test/PoolRoundtrip.t.sol          pool wiring + lockOrBurn/releaseOrMint (4)
test/DeploymentE2E.t.sol          full sequence simulation incl. handoff + rate-limit update (4)
test/mocks/                       MockRouter, MockRMN
test/fork/Fork_ETH.t.sol          ETH mainnet fork — deploy + registry + bridge simulation (4)
test/fork/Fork_BSC.t.sol          BSC mainnet fork — token ownership probe + pool + bridge sim (4)
test/fork/Fork_Bridge.t.sol       dual-fork full roundtrip BSC→ETH→BSC against live CCIP (1)
deployments/<chainId>.json        written by scripts via vm.writeJson
```

## Operating

Everything goes through the `Makefile`. The full sequence is documented in `RUNBOOK.md`. Key targets:

- `make test`                  — full test suite (26 tests, no fork).
- `make test-unit`             — WrappedON.t.sol unit tests only.
- `make test-e2e`              — PoolRoundtrip + DeploymentE2E integration tests.
- `make test-fork ETH_RPC=... BSC_RPC=...` — fork tests against live mainnet (9 tests).
- `make deploy-eth RPC=...`    — scripts 01→05 on the Ethereum side.
- `make deploy-bsc RPC=...`    — scripts 02 + 04 + 05 on the BSC side.
- `make verify-eth/bsc RPC=...` — script 08 view-only verification.
- `make handoff MULTISIG=0x..`  — script 06 handoff to multisig.
- `make renounce RPC=...`       — final deployer-renounce after multisig confirmed.
- `make update-limits ...`      — script 07 rate-limit tuning.

## Build & test

```bash
forge build
forge test -vvv --no-match-path "test/fork/**"          # 26 mock-based tests (no RPC needed)
make test-fork ETH_RPC=<url> BSC_RPC=<url>              # 9 mainnet fork tests
make test-unit                                           # WrappedON.t.sol only
make test-e2e                                            # PoolRoundtrip + DeploymentE2E only
forge coverage --report summary
```

## Deployment

Sequence: testnet (Sepolia ⇄ BSC Testnet) first, then mainnet. Scripts are numbered 01–05 and dispatched on `block.chainid` where they need to behave differently per chain. See `README.md` for the full command list.

Final step on both chains: transfer pool `Ownable` ownership and wON `DEFAULT_ADMIN_ROLE` to a Gnosis Safe; deployer EOA `renounceRole`s.

## Known open items

- BSC ON token CCIP-admin hook: confirm whether `0x0e4F6209eD984b21EDEA43acE6e09559eD051D48` exposes `getCCIPAdmin`, is `Ownable`, or requires the token owner to call `proposeAdministrator`. `script/04_RegisterAdminAndPool.s.sol` branches on this automatically and reverts with a clear message if neither path works. Resolve before mainnet rollout.
- **All CCIP infrastructure addresses in `script/Helper.sol` (router / rmnProxy / tokenAdminRegistry / registryModuleOwnerCustom / linkToken) are intentionally `address(0)` placeholders.** Fill them in from https://docs.chain.link/ccip/directory before broadcasting. Scripts call `_requireSet` on every address they consume, so a stale Helper fails fast with a `MissingAddress` revert.

## Reference

- Plan: `/home/parallels/.claude/plans/orochi-network-token-on-gleaming-cat.md`
- Chainlink CCIP CCT docs: https://docs.chain.link/ccip/concepts/cross-chain-token/overview
- Reference repo: https://github.com/smartcontractkit/ccip-starter-kit-foundry
