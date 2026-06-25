# Mainnet Deployment Checklist — ON Bridge

A one-page tick-list. Full detail lives in `RUNBOOK.md` (section refs in parentheses).
Do the **whole testnet pass first** (Sepolia ⇄ BSC Testnet) before touching mainnet.

## 0. Pre-flight (before any gas is spent)

> Verification pass run **2026-06-14** — `[x]` = confirmed green this session, `[~]` = partially verified / caveat, `[ ]` = still owed.

- [x] Fill CCIP infra addresses in `script/Helper.sol` for **both** ETH (`1`) and BSC (`56`) from the [CCIP directory](https://docs.chain.link/ccip/directory): `router`, `rmnProxy`, `tokenAdminRegistry`, `registryModuleOwnerCustom`, `linkToken` (§0.1, §2.1) — filled for all four chains
- [x] `make precheck-helper RPC=eth` and `RPC=bsc` — no address is left `address(0)` *(both OK 2026-06-14)*
- [x] `make validate-config RPC=eth` and `RPC=bsc` — live staticcall confirms the addresses are genuine CCIP contracts + the lane is real *(both OK 2026-06-14: Router 1.2.0, TokenAdminRegistry 1.5.0, RegistryModuleOwnerCustom 1.6.0, ARMProxy 1.0.0, LINK + 18-dec onToken; both lanes supported)*
- [~] **BSC admin path** — `make validate-bsc-admin RPC=bsc`: **path-4 confirmed** 2026-06-14 (no `getCCIPAdmin`, `owner()==0`, no AccessControl) → script 04 **will revert**. CCIP-admin must be registered **out-of-band with Chainlink before the BSC deploy.** ⏳ Still owed: `DEPLOYER=0x<eoa>`-gated re-run at deploy time (§0.2, SECURITY `TEST-7`)
- [ ] **BSC ON supply is fixed at 100M** with no live minter — the `MAX_CCIP_MINTED = 100M` cap depends on this (§0.2, `OPS-29`) *(not yet probed)*
- [ ] `.env` filled and sourced; for mainnet prefer an encrypted keystore (`--account deployer`) over `--private-key` (§0.3) *(.env present + RPC vars load; keystore not yet set up)*
- [~] `make build` ✅ and non-fork tests ✅ (**141 green**) and `make fmt-check` ✅ (§0.4). ⚠️ Full `make test` shows **3 fork suites failing in `setUp`** (self-skip broken under forge 1.7.1) — tooling, not contract; see `issue.md`. Note: doc count 130 is stale → **141** non-fork
- [x] `make check-links` — Chainlink doc URLs still resolve (release gate) (§0.5) *(7/7 OK 2026-06-14)*

## 1. Testnet dry run (do not skip)

- [ ] Deploy mock ON + patch Helper for Sepolia/BSC-testnet branches (§1.0, `OPS-23`)
- [ ] `make deploy-eth RPC=sepolia` then `make deploy-bsc RPC=bsc_testnet` (§1.1–1.2)
- [ ] `make verify-eth RPC=sepolia` / `make verify-bsc RPC=bsc_testnet` — all green (§1.3)
- [ ] Smoke test both directions via [CCIP Explorer](https://ccip.chain.link/) (§1.4)

## 2. Mainnet deploy

- [ ] Re-verify infra addresses on mainnet (re-run `validate-config`) (§2.1)
- [ ] Calibrate rate limits in `script/05_ApplyChainUpdates.s.sol` (default 100k cap / 10 ON/sec) — size **ETH→BSC capacity ≤ BSC pool releasable balance − buffer** (§2.2, `CCIP-2`)
- [ ] `make deploy-eth RPC=eth`
- [ ] `make deploy-bsc RPC=bsc` (only after BSC admin is registered — see 0)
- [ ] `make verify-eth RPC=eth` / `make verify-bsc RPC=bsc` — all green (§2.4)
- [ ] Small real-value bridge each direction; record tx hashes (§2.5)

## 3. Handoff to multisig (minimize the window — §3)

- [ ] Multisig signers staged and ready **before** starting
- [ ] `make handoff-all ETH_RPC=eth BSC_RPC=bsc MULTISIG=0x<safe>` (§3.1)
- [ ] Multisig accepts, **simulate each before signing** (§3.2):
  - ETH: `pool.acceptOwnership()`, `registry.acceptAdminRole(wON)`, `wON.acceptCCIPAdmin()`
  - BSC: `pool.acceptOwnership()`, `registry.acceptAdminRole(ON_BSC)`
- [ ] `MULTISIG=0x.. make verify-eth RPC=eth` / `verify-bsc RPC=bsc` — ownership flipped (§3.3)
- [ ] `make renounce RPC=eth MULTISIG=0x<safe>` — deployer drops wON admin + liquidity-manager roles. **Do not skip.** (§3.4)

## 4. Before going live

- [ ] Off-chain monitoring/alerts deployed for the Critical events (Trust-model table, §3.4 / RUNBOOK trust-model section): BSC `LiquidityRemoved` / `RebalancerSet` / `OwnershipTransfer*` / `RouterUpdated` / `RemotePoolSet`; wON unexpected `RoleGranted(MINTER/BURNER)`; `CCIPMinted` vs BSC pool balance
- [ ] Liquidity alarm: page when `BSC_ON.balanceOf(BSC pool) < ETH→BSC capacity + buffer` (§4.4)
- [ ] On-call rotation briefed on the `CCIPMintCapExceeded` and stuck-ETH→BSC-transfer runbooks (§0.2, §4.4)

---

**Key reminders**

- The deployer EOA holds custody-grade authority during the whole 3.1→3.4 window — aim for hours, not days, and monitor both chains while in flight.
- BSC pool owner can `setRebalancer` → `withdrawLiquidity` the entire locked reserve by design (Chainlink CCT trust model) — the multisig is custody-grade on BSC.
- Contracts are non-upgradeable; migration = redeploy + re-register (§4.3).
