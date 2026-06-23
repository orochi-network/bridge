# CLAUDE.md — Orochi Network ON Bridge

This file is project memory for Claude Code working in this repository. Keep it short. Update when conventions or constraints change.

## What this is

A Foundry project implementing a **Chainlink CCIP Cross-Chain Token (CCT) bridge** for the Orochi Network **ON** token between Ethereum Mainnet and BNB Smart Chain.

- **BSC side**: stock `LockReleaseTokenPool` against the existing ON token. CCIP 1.6.1 removed the `acceptLiquidity` ctor flag; `provideLiquidity`/`withdrawLiquidity` are gated on `msg.sender == s_rebalancer`, so deploying with **no rebalancer set** keeps them disabled (same launch posture as the old `acceptLiquidity = false`). The operator multisig takes custody of the reserve via `setRebalancer` → `withdrawLiquidity` (Chainlink CCT trust model — see [Trust model](#trust-model-bsc-reserve-custody)).
- **Ethereum side**: stock `BurnMintTokenPool` against a new **wON** token (this repo's only custom contract). The CCIP `mint` path is bounded by `MAX_CCIP_MINTED = 100M` (tracked via `ccipMintHeadroomUsed`); `deposit` is uncapped and bounded naturally by ETH-side ON supply.
- **wON** is also a 1:1 wrapper holding a reserve of native ETH-side ON. `deposit` mints wON 1:1 against deposited ON (received-amount accounting, `nonReentrant`); `withdraw` burns wON and returns ON when the reserve allows. On BSC→ETH arrivals, `mint` always delivers **wON** (the registered token) to every receiver, EOA or contract — it never reads the reserve or delivers native ON, so the delivered asset is deterministic and not front-runnable (issue #48). Holders who want native ON call `withdraw`.

## Token addresses (canonical)

- ON on Ethereum Mainnet: `0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d` (600M, 18 decimals, **non-mintable**).
- ON on BSC Mainnet:      `0x0e4F6209eD984b21EDEA43acE6e09559eD051D48` (100M, 18 decimals).

## CCIP chain selectors

- Ethereum Mainnet: `5009297550715157269`
- BSC Mainnet: `11344663589394136015`
- Sepolia / BSC Testnet: resolved in `script/Helper.sol` — verify against https://docs.chain.link/ccip/directory at deploy time.

## Secrets handling

**Never read `.env`, `.env.local`, or any `.env.*` file in this repo.** Don't `cat`, `Read`, `head`, `grep`, or otherwise dump their contents to stdout or into the conversation — they hold live RPC and block-explorer API keys. (The deployer key lives in an encrypted Foundry keystore, not in `.env` — signing is via `--account deployer`.) If you need to know which variables exist, refer to `.env.example` (which only has placeholders). If a deployment script needs an env var, just invoke `forge script` and let the user/shell pass it in.

## Conventions

- **Solidity 0.8.34, optimizer 200, evm_version = cancun.** `lib/` is git submodules (see `.gitmodules`). CCIP contracts come from **`lib/chainlink-ccip` pinned to `contracts-ccip-v1.6.1`** (EVM sources under `chains/evm/contracts/`), and its shared/vendored dependency **`lib/chainlink-evm` pinned to `contracts-v1.4.0`** (`@chainlink/contracts` — provides `Ownable2StepMsgSender`, `IBurnMintERC20`, `ITypeAndVersion`, and OZ vendored at v4.8.3 + v5.0.2 **for the Chainlink library's own internal use**; this repo's own `src/`+`test/` code resolves `@openzeppelin/contracts/` to the standalone `lib/openzeppelin-contracts` submodule at v5.6.1). This is CCIP 1.6.1, the Chainlink-docs-recommended generic-pool version; migrated off the archived `smartcontractkit/ccip` repo (which carried the old 1.5.x line, formerly pinned at `v2.17.0-ccip1.5.16`).
- **Pragma patch**: `make patch-pragmas` rewrites any `pragma solidity 0.8.24;` in `lib/` to `^0.8.24`. The CCIP 1.6.1 / chainlink-evm 1.4.0 sources already use caret pragmas, so this is now effectively a no-op, but it is kept (idempotent, harmless) for any future submodule that pins a bare 0.8.24.
- **Use stock Chainlink contracts** for `BurnMintTokenPool` and `LockReleaseTokenPool`. Do NOT subclass — extra inheritance increases audit surface for zero functional gain. Subclassing was considered and rejected; the Chainlink trust model is documented instead.
- **Only one custom contract**: `src/WrappedON.sol`. Keep it small. New custom contracts require justification.
- **Decimals**: ON and wON are both 18. CCIP 1.6.1 pool constructors take `uint8 localTokenDecimals` (validated against `token.decimals()`); both pools are deployed with `18`. Off-chain registration in the CCIP directory records 18/18 for both.
- **Roles on wON**: `MINTER_ROLE` and `BURNER_ROLE` go ONLY to the `BurnMintTokenPool` on Ethereum. `UPGRADER_ROLE` goes to the `TimelockController` (48h default delay) — gates `upgradeToAndCall` — and is **self-administered** (`_setRoleAdmin(UPGRADER_ROLE, UPGRADER_ROLE)` in `initialize`) so `DEFAULT_ADMIN_ROLE` can't re-grant it and bypass the timelock (SECURITY UPG-1). `PAUSER_ROLE` starts on the deployer-supplied admin and passes to the ops multisig at handoff — gates emergency `pause`/`unpause`; it deliberately keeps the default `DEFAULT_ADMIN_ROLE` admin. Pause halts ALL value paths **including `withdraw`**, so it can freeze 1:1 redemption while wON keeps trading — a deliberate, custody-affecting emergency control to stop the native-ON reserve being drained via `withdraw` during a bridge/protocol compromise (NOT merely "liveness-only"). Keeping `withdraw` pausable is a product decision (2026-06-23); see SECURITY.md WON-21 / #56. `DEFAULT_ADMIN_ROLE` starts on deployer, then transfers to the ops multisig after wiring. There is no `LIQUIDITY_MANAGER_ROLE` — `deposit` is permissionless (SECURITY M3 / #25 REVERSED 2026-06-23 by product decision).
- **CCIP admin handoff is two-step**: `setCCIPAdmin(addr)` proposes; the proposed address must call `acceptCCIPAdmin()` to take effect. The proposal target is validated on-chain — rejects `address(0)` (`ZeroAddress`), self-proposal `newAdmin == s_ccipAdmin`, and `newAdmin == address(this)` (both via `InvalidCCIPAdmin`) — so scripts can't accidentally clobber an in-flight pending or write an unreachable address. Same handoff shape for `Ownable` ownership on pools and `TokenAdminRegistry` admin roles.
- **wON is UUPS-upgradeable** (deliberate exception to "keep surface small"). It sits behind an `ERC1967Proxy` at a stable address. The implementation is deployed separately; script 01 deploys `TimelockController` → `WrappedON` (impl) → `ERC1967Proxy(initialize)`. Artifacts: `wrappedON` = proxy (the registered token), `wrappedONImpl`, `wrappedONTimelock`. State lives in ERC-7201 namespaced storage (`orochi.storage.WrappedON`); the impl `constructor` calls `_disableInitializers()`. Upgrade authority is custody-grade — see SECURITY.md `UPG-*` entries. **Storage-layout guard (#50)**: `make check-storage-layout` (wired into CI) diffs the `WrappedONStorage` struct against the committed snapshot `storage/WrappedON.storage-layout.json` and fails on ANY change (the struct is invisible to a plain `forge inspect`, so it inspects the `test/storage/StorageLayoutProbe.sol` probe — see `script/storage-layout.sh`). Reorder/insert/remove/retype corrupts proxy state; only an APPEND is safe, and an append requires `make update-storage-layout` + committing the refreshed snapshot.

## Reserve invariant (wON)

There are TWO mint paths for wON; both produce identical fungible tokens but back differently:

1. `deposit(amount)` — anyone pulls native ETH ON and receives wON 1:1; wON minted is backed by ON held in this contract's reserve. **Permissionless and uncapped** — wON supply growth (and ETH→BSC redemption demand) is bounded only by ETH-side ON supply and the CCIP pool rate limits.
2. `mint(...)` — CCIP pool mints when value arrives from BSC; backing is ON locked on the BSC `LockReleaseTokenPool`. Always mints **wON** to the receiver (EOA or contract) and increments `ccipMintHeadroomUsed`; it never reads the reserve or delivers native ON (issue #48 — keeps the delivered asset deterministic and not front-runnable via the permissionless `deposit`/`withdraw` reserve). Emits `CCIPMinted(account, amount, ccipMintHeadroomUsed)`.

Conceptual invariant (NOT tracked as on-chain state — `wrapBackedSupply` is a term, not a storage variable): `{wON minted via deposit and still circulating} <= ON.balanceOf(WrappedON)`. Enforcement is via `withdraw` reverting when `ON.balanceOf(this) < amount`, plus the received-amount accounting in `deposit` that adds to the reserve and `totalSupply` in lockstep. CCIP-bridged users who want native ETH ON depend on someone else having wrapped — this is an arbitrage layer, not a guaranteed redemption.

**CCIP mint cap**: `WrappedON.MAX_CCIP_MINTED = 100_000_000 ether` bounds `ccipMintHeadroomUsed` — the counter incremented in `mint(...)` and saturating-decremented in every burn entrypoint. `mint` reverts `CCIPMintCapExceeded(cap, wouldBe)` when `ccipMintHeadroomUsed + amount` would exceed the cap; `deposit` is permissionless, uncapped, and independent of `MAX_CCIP_MINTED`, so heavy wrap usage cannot starve inbound CCIP messages. The cap matches the canonical ON supply on BSC, which is the absolute upper bound on what the bridge can ever reflect onto Ethereum. The counter is a BSC-pool-balance approximation, not a circulating-CCIP-minted accounting. Every `mint` increments the counter — there is no reserve-covered fast path (issue #48 removed auto-unwrap), so the reserve can only ever leave via `withdraw`.

## Trust model: BSC reserve custody

In CCIP 1.6.1 `LockReleaseTokenPool` no longer has an `acceptLiquidity` flag. `provideLiquidity` and `withdrawLiquidity` revert `Unauthorized` unless `msg.sender == s_rebalancer`; `transferLiquidity(from, amount)` is `onlyOwner` but only ever PULLS liquidity *into* this pool from a `from` pool where this pool is the rebalancer (it calls `from.withdrawLiquidity`), so it cannot extract this pool's reserve. We deploy with **no rebalancer set**, so the reserve is not movable out by anyone at launch (the same end-state the old `acceptLiquidity = false` gave). By design, the pool owner (the ops multisig after handoff) can `setRebalancer` (it is `onlyOwner`) and thereby take full custody of the locked-ON reserve via `withdrawLiquidity`. This is Chainlink's CCT pattern and is not a bug — but it does mean the multisig is a custody-grade authority on BSC. See `RUNBOOK.md` for monitoring guidance.

## Layout

```
src/WrappedON.sol                 the only custom contract (UUPS-upgradeable, ERC-7201 storage)
script/Helper.sol                 per-chain CCIP config (router, RMN, registry, selectors)
script/Deployments.sol            JSON artifact read/write helper
script/01_DeployWrappedON.s.sol   ETH only — deploys TimelockController → impl → ERC1967Proxy
script/02_DeployPools.s.sol       both chains — chain-dispatched on block.chainid
script/03_GrantRoles.s.sol        ETH only — grants MINTER/BURNER on wON to the pool
script/04_RegisterAdminAndPool.s.sol  both chains — probes getCCIPAdmin / Ownable / AccessControl, then setPool + post-asserts the wiring
script/05_ApplyChainUpdates.s.sol both chains — wires remote pool + rate limits
script/06_TransferOwnership.s.sol both chains — handoff to multisig (TransferOwnership + RenounceDeployerAdmin contracts)
script/07_UpdateRateLimits.s.sol  ops — adjust setChainRateLimiterConfig (env-driven)
script/08_PostDeployVerify.s.sol  view-only — programmatic check of all wiring
test/WrappedON.t.sol              unit tests (incl. WON-1/4/5/7 + reentrancy TEST-8)
test/WrappedONInvariant.t.sol     4 stateful invariants over 9 handler actions
test/PoolRoundtrip.t.sol          pool wiring + lockOrBurn/releaseOrMint + rate-limit fuzz
test/DeploymentE2E.t.sol          full sequence simulation incl. handoff + rate-limit update
test/Script04Paths.t.sol          script 04 admin-dispatch path coverage
test/Script06Guards.t.sol         handoff env-var + multisig guard coverage
test/Script06Renounce.t.sol       renounce precondition assertions
test/Script07Preflight.t.sol      rate-limit preflight checks
test/Script08Verify.t.sol         post-deploy verification coverage
test/storage/StorageLayoutProbe.sol  inspect-only probe exposing the WrappedONStorage layout (#50 guard)
storage/WrappedON.storage-layout.json committed storage-layout snapshot (regenerate via make update-storage-layout)
script/storage-layout.sh          storage-layout guard runner (check|update); script/storage-layout.py normalises forge inspect output
test/mocks/                       MockRouter, MockRMN
test/fork/Fork_ETH.t.sol          ETH mainnet fork — deploy + registry + bridge simulation (5)
test/fork/Fork_BSC.t.sol          BSC mainnet fork — token ownership probe + pool + bridge sim (4)
test/fork/Fork_Bridge.t.sol       dual-fork full roundtrip BSC→ETH→BSC against live CCIP (1)
deployments/<chainId>.json        written by scripts via vm.writeJson
```

## Operating

Everything goes through the `Makefile`. The full sequence is documented in `RUNBOOK.md`. Key targets:

- `make install`               — submodule init + patch-pragmas (one-time after clone).
- `make test`                  — full suite: 174 tests total (incl. 4 stateful invariants); fork tests self-skip when ETH_RPC/BSC_RPC unset.
- `make test-unit`             — WrappedON.t.sol unit tests only.
- `make test-e2e`              — PoolRoundtrip + DeploymentE2E integration tests.
- `make test-fork ETH_RPC=... BSC_RPC=...` — fork tests against live mainnet (10 tests).
- `make validate-config RPC=...` — live staticcall check that `Helper.sol` CCIP infra addresses are genuine on the target chain (script `ValidateConfig.s.sol`; pairs with the pure `precheck-helper`).
- `make check-links`           — verify Chainlink `docs.chain.link` URLs in tracked sources still resolve (pre-release gate; not in PR CI — see RUNBOOK §0.5).
- `make check-storage-layout`  — diff wON's `WrappedONStorage` ERC-7201 layout vs the committed snapshot; fails on any reorder/insert/remove/retype (#50, wired into PR CI). `make update-storage-layout` refreshes the snapshot after an intentional struct append.
- `make deploy-eth RPC=...`    — scripts 01→05 on the Ethereum side.
- `make deploy-bsc RPC=...`    — scripts 02 + 04 + 05 on the BSC side.
- `make verify-eth/bsc RPC=...` — script 08 view-only verification. Post-handoff renounce check needs `DEPLOYER=0x..` (SECURITY: DEP-8); pre-handoff or `MULTISIG`-unset runs don't.
- `make handoff-all ETH_RPC=... BSC_RPC=... MULTISIG=0x..` — sequential two-chain handoff (re-run safe on partial failure; the second leg has no rollback if the first succeeds).
- `make renounce RPC=eth MULTISIG=0x..` — final deployer-renounce after multisig accepts everything.
- `make update-limits ...`      — script 07 rate-limit tuning.

## Build & test

```bash
make install                                             # submodules + patch-pragmas
forge build
make test                                                # mock-based suite; fork tests self-skip when ETH_RPC/BSC_RPC unset
make test-fork ETH_RPC=<url> BSC_RPC=<url>              # 10 mainnet fork tests
make test-unit                                           # WrappedON.t.sol only
make test-e2e                                            # PoolRoundtrip + DeploymentE2E only
forge coverage --report summary
```

## Deployment

Sequence: testnet (Sepolia ⇄ BSC Testnet) first, then mainnet. Scripts are numbered 01–05 and dispatched on `block.chainid` where they need to behave differently per chain. See `README.md` for the full command list.

Final step on both chains: transfer pool `Ownable` ownership and wON `DEFAULT_ADMIN_ROLE` to a Gnosis Safe; deployer EOA `renounceRole`s.

## Known open items (operational, pre-mainnet)

- BSC ON token CCIP-admin hook: **CONFIRMED path-4 (probed live 2026-06-01 via `make validate-bsc-admin`, #22).** `0x0e4F6209eD984b21EDEA43acE6e09559eD051D48` exposes no `getCCIPAdmin`, has `owner() == address(0)` (renounced), and is not OZ `AccessControl` — so `script/04_RegisterAdminAndPool.s.sol` will revert `CannotResolveCCIPAdmin` on BSC mainnet for any deployer. CCIP-admin registration must be arranged out-of-band with Chainlink (the `TokenAdminRegistry` owner) before the BSC deploy. Re-confirm at deploy time with `make validate-bsc-admin RPC=<bsc> DEPLOYER=0x..`. (`TEST-7` / formerly legacy audit tag `H-4`.)
- **CCIP infrastructure addresses in `script/Helper.sol` are intentionally `address(0)` placeholders.** Fill them in from https://docs.chain.link/ccip/directory before broadcasting. Scripts call `_requireSet` on every address they consume.
- ~~Test coverage gaps~~ — **closed**. See SECURITY.md `TEST-1` through `TEST-20` per-finding entries (the originally-HIGH `TEST-1` and `TEST-2` are FIXED; `TEST-7` LOW is deferred pending the BSC admin-path resolution above).
- **Security review (`SECURITY.md`)**: post 2026-05-19 remediation pass — all six originally HIGH findings (`DEP-1`, `CCIP-1`, `TEST-1`, `TEST-2`, `OPS-1`, `OPS-2`) are FIXED; only `TEST-7` and `OPS-8` remain DEFERRED (both LOW). See SECURITY.md for per-finding status.

## Reference

- `README.md` — operator-facing step-by-step (clone → deploy → handoff → ops).
- `RUNBOOK.md` — deep dive on each step + trust model + required monitoring.
- `SECURITY.md` — consolidated security review with unique ID prefixes (`WON-`, `DEP-`, `CCIP-`, `TEST-`, `OPS-`); disclosure address `security@orochi.network`.
- Chainlink CCIP CCT docs: https://docs.chain.link/ccip/concepts/cross-chain-token/overview
- Reference repo: https://github.com/smartcontractkit/ccip-starter-kit-foundry
