# CLAUDE.md — Orochi Network ON Bridge

This file is project memory for Claude Code working in this repository. Keep it short. Update when conventions or constraints change.

## What this is

A Foundry project implementing a **Chainlink CCIP Cross-Chain Token (CCT) bridge** for the Orochi Network **ON** token between Ethereum Mainnet and BNB Smart Chain.

- **BSC side**: stock `LockReleaseTokenPool` against the existing ON token. `acceptLiquidity = false` on construction disables `provideLiquidity`; the operator multisig still has custody of the reserve via `setRebalancer` → `withdrawLiquidity` (Chainlink CCT trust model — see [Trust model](#trust-model-bsc-reserve-custody)).
- **Ethereum side**: stock `BurnMintTokenPool` against a new **wON** token (this repo's only custom contract). The CCIP `mint` path is bounded by `MAX_CCIP_MINTED = 100M` (tracked via `ccipMintedSupply`); `deposit` is uncapped and bounded naturally by ETH-side ON supply.
- **wON** is also a 1:1 wrapper holding a reserve of native ETH-side ON. `deposit` mints wON 1:1 against deposited ON (received-amount accounting, `nonReentrant`); `withdraw` burns wON and returns ON when the reserve allows.

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

- **Solidity 0.8.34, optimizer 200, evm_version = cancun.** `lib/` is git submodules (see `.gitmodules`); `lib/ccip` is pinned to **`v2.17.0-ccip1.5.16`** to match the deployed production CCIP 1.5.x ABI on both ETH + BSC mainnet.
- **Pragma patch**: vendored Chainlink + OZ sources pin `pragma solidity 0.8.24;`; our project pins 0.8.34. `make patch-pragmas` rewrites them to `^0.8.24`. This runs automatically as part of `make install` and as a CI step after submodule checkout. Re-run manually if you do `git submodule update`.
- **Use stock Chainlink contracts** for `BurnMintTokenPool` and `LockReleaseTokenPool`. Do NOT subclass — extra inheritance increases audit surface for zero functional gain. (Subclassing was considered and rejected for SECURITY.md C-1; the Chainlink trust model is documented instead.)
- **Only one custom contract**: `src/WrappedON.sol`. Keep it small. New custom contracts require justification.
- **Decimals**: ON and wON are both 18. CCIP 1.5.x pools do not store `localTokenDecimals`; off-chain registration in the CCIP directory records 18/18 for both.
- **Roles on wON**: `MINTER_ROLE` and `BURNER_ROLE` go ONLY to the `BurnMintTokenPool` on Ethereum. `DEFAULT_ADMIN_ROLE` starts on deployer, then transfers to the ops multisig after wiring.
- **CCIP admin handoff is two-step**: `setCCIPAdmin(addr)` proposes; the proposed address must call `acceptCCIPAdmin()` to take effect. Same for `Ownable` ownership on pools and `TokenAdminRegistry` admin roles.
- **No upgrades**: contracts are non-upgradeable by design. Migration path = redeploy + re-register in `TokenAdminRegistry` + `applyChainUpdates`.

## Reserve invariant (wON)

There are TWO mint paths for wON; both produce identical fungible tokens but back differently:

1. `deposit(amount)` — user pulls native ETH ON; wON minted is backed by ON held in this contract's reserve.
2. `mint(...)` — CCIP pool mints when value arrives from BSC; backing is ON locked on the BSC `LockReleaseTokenPool`.

Conceptual invariant (NOT tracked as on-chain state — `wrapBackedSupply` is a term, not a storage variable): `{wON minted via deposit and still circulating} <= ON.balanceOf(WrappedON)`. Enforcement is via `withdraw` reverting when `ON.balanceOf(this) < amount`, plus the received-amount accounting in `deposit` that adds to the reserve and `totalSupply` in lockstep. CCIP-bridged users who want native ETH ON depend on someone else having wrapped — this is an arbitrage layer, not a guaranteed redemption.

**CCIP mint cap**: `WrappedON.MAX_CCIP_MINTED = 100_000_000 ether` bounds `ccipMintedSupply` — the counter incremented in `mint(...)` and saturating-decremented in every burn entrypoint. `mint` reverts `CCIPMintCapExceeded(cap, wouldBe)` when `ccipMintedSupply + amount` would exceed the cap; `deposit` is intentionally uncapped (bounded by ETH-side ON supply) so heavy wrap usage cannot starve inbound CCIP messages. The cap matches the canonical ON supply on BSC, which is the absolute upper bound on what the bridge can ever reflect onto Ethereum — see `SECURITY.md` C-3 / R-1 / R-14 for the full reasoning on why the counter is a BSC-pool-balance approximation, not a circulating-CCIP-minted accounting.

## Trust model: BSC reserve custody

`LockReleaseTokenPool` is constructed with `acceptLiquidity = false`, which disables **only** `provideLiquidity`. By design, the pool owner (the ops multisig after handoff) keeps full custody of the locked-ON reserve via `setRebalancer` → `withdrawLiquidity`. This is Chainlink's CCT pattern and is not a bug — but it does mean the multisig is a custody-grade authority on BSC. See `SECURITY.md` C-1 and `RUNBOOK.md` for monitoring guidance.

## Layout

```
src/WrappedON.sol                 the only custom contract
script/Helper.sol                 per-chain CCIP config (router, RMN, registry, selectors)
script/Deployments.sol            JSON artifact read/write helper
script/01_DeployWrappedON.s.sol   ETH only — deploys wON
script/02_DeployPools.s.sol       both chains — chain-dispatched on block.chainid
script/03_GrantRoles.s.sol        ETH only — grants MINTER/BURNER on wON to the pool
script/04_RegisterAdminAndPool.s.sol  both chains — probes getCCIPAdmin / Ownable / AccessControl, then setPool + post-asserts the wiring
script/05_ApplyChainUpdates.s.sol both chains — wires remote pool + rate limits
script/06_TransferOwnership.s.sol both chains — handoff to multisig (TransferOwnership + RenounceDeployerAdmin contracts)
script/07_UpdateRateLimits.s.sol  ops — adjust setChainRateLimiterConfig (env-driven)
script/08_PostDeployVerify.s.sol  view-only — programmatic check of all wiring
test/WrappedON.t.sol              unit tests
test/PoolRoundtrip.t.sol          pool wiring + lockOrBurn/releaseOrMint
test/DeploymentE2E.t.sol          full sequence simulation incl. handoff + rate-limit update
test/mocks/                       MockRouter, MockRMN
test/fork/Fork_ETH.t.sol          ETH mainnet fork — deploy + registry + bridge simulation (4)
test/fork/Fork_BSC.t.sol          BSC mainnet fork — token ownership probe + pool + bridge sim (4)
test/fork/Fork_Bridge.t.sol       dual-fork full roundtrip BSC→ETH→BSC against live CCIP (1)
deployments/<chainId>.json        written by scripts via vm.writeJson
```

## Operating

Everything goes through the `Makefile`. The full sequence is documented in `RUNBOOK.md`. Key targets:

- `make install`               — submodule init + patch-pragmas (one-time after clone).
- `make test`                  — full test suite, no fork: 99 tests total (95 unit/integration + 4 stateful invariants).
- `make test-unit`             — WrappedON.t.sol unit tests only.
- `make test-e2e`              — PoolRoundtrip + DeploymentE2E integration tests.
- `make test-fork ETH_RPC=... BSC_RPC=...` — fork tests against live mainnet (9 tests).
- `make deploy-eth RPC=...`    — scripts 01→05 on the Ethereum side.
- `make deploy-bsc RPC=...`    — scripts 02 + 04 + 05 on the BSC side.
- `make verify-eth/bsc RPC=...` — script 08 view-only verification.
- `make handoff-all ETH_RPC=... BSC_RPC=... MULTISIG=0x..` — sequential two-chain handoff (re-run safe on partial failure; the second leg has no rollback if the first succeeds).
- `make renounce RPC=eth MULTISIG=0x..` — final deployer-renounce after multisig accepts everything.
- `make update-limits ...`      — script 07 rate-limit tuning.

## Build & test

```bash
make install                                             # submodules + patch-pragmas
forge build
forge test -vvv --no-match-path "test/fork/**"          # 99 mock-based tests (no RPC needed)
make test-fork ETH_RPC=<url> BSC_RPC=<url>              # 9 mainnet fork tests
make test-unit                                           # WrappedON.t.sol only
make test-e2e                                            # PoolRoundtrip + DeploymentE2E only
forge coverage --report summary
```

## Deployment

Sequence: testnet (Sepolia ⇄ BSC Testnet) first, then mainnet. Scripts are numbered 01–05 and dispatched on `block.chainid` where they need to behave differently per chain. See `README.md` for the full command list.

Final step on both chains: transfer pool `Ownable` ownership and wON `DEFAULT_ADMIN_ROLE` to a Gnosis Safe; deployer EOA `renounceRole`s.

## Known open items (operational, pre-mainnet)

- BSC ON token CCIP-admin hook: confirm whether `0x0e4F6209eD984b21EDEA43acE6e09559eD051D48` exposes `getCCIPAdmin`, is `Ownable`, or uses OZ `AccessControl.DEFAULT_ADMIN_ROLE`. `script/04_RegisterAdminAndPool.s.sol` probes all three paths (with the AccessControl path routing through a local interface for the 1.6.0 registry on prod), then reverts with a clear instruction if none match. Resolve on a private fork before mainnet rollout (audit H-4).
- **CCIP infrastructure addresses in `script/Helper.sol` are intentionally `address(0)` placeholders.** Fill them in from https://docs.chain.link/ccip/directory before broadcasting. Scripts call `_requireSet` on every address they consume.
- ~~Test coverage gaps~~ — **closed**. All 8 gaps tracked in `SECURITY.md` "Test coverage gaps" are now covered (reserve-invariant stateful fuzz, renounce-before-accept negative, rate-limit exhaustion/refill, script 04 admin-dispatch on all four paths, BSC-side ownership handoff, property fuzz on deposit + cap boundary, fork tests assert non-zero rate/capacity, AccessControl v1.6 success path via `MockRegistryModuleV16`).

## Reference

- `README.md` — operator-facing step-by-step (clone → deploy → handoff → ops).
- `RUNBOOK.md` — deep dive on each step + trust model + required monitoring.
- `SECURITY.md` — audit ledger; every finding has a Status (fixed / accepted / operational).
- Chainlink CCIP CCT docs: https://docs.chain.link/ccip/concepts/cross-chain-token/overview
- Reference repo: https://github.com/smartcontractkit/ccip-starter-kit-foundry
