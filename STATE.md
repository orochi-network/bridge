# Deployment State — ON Bridge (mainnet)

_Last updated: 2026-06-23_

## 2026-06-23 — wON redeployed (permissionless deposit + UUPS proxy)

`WrappedON` was updated to add:
- **BSC→ETH arrivals always mint wON**: `mint` mints `amount` wON (the registered token) to the receiver — EOA or contract — and emits `CCIPMinted`. It never reads the reserve or delivers native ON, so the delivered asset is deterministic and not front-runnable via the permissionless `deposit`/`withdraw` reserve (issue #48). A holder who wants native ON calls `withdraw`. (An earlier draft auto-unwrapped to native ON when the reserve covered the arrival; that was removed before redeploy — see issue #48.)
- **Permissionless `deposit`**: the `LIQUIDITY_MANAGER_ROLE` gate on `deposit` was removed; anyone holding ETH-side ON can wrap 1:1 into wON.
- **UUPS upgradeability**: wON is now an `ERC1967Proxy` → `WrappedON` (impl). Upgrades are gated by `UPGRADER_ROLE` held by a `TimelockController` (48h delay). Emergency `pause`/`unpause` is gated by `PAUSER_ROLE` (ops multisig post-handoff).

Because wON was previously non-upgradeable, both ETH contracts (wON proxy + `BurnMintTokenPool`) were redeployed. The existing BSC `LockReleaseTokenPool` was retained; only its ETH-lane config was updated (new remote pool + new wON proxy address via script 05). Procedure: RUNBOOK §4.4.

The old on-chain wON (`0x98d6…606`) and old ETH pool (`0xE0b7…8A72`) were clean at redeploy time — no circulating holders, no reserve.

**New addresses are PENDING — fill in after broadcast:**

| Contract | Address | Notes |
|---|---|---|
| wON proxy (ERC1967Proxy) — NEW | _(PENDING post-broadcast)_ | Stable token address; registered in CCIP TokenAdminRegistry. Replaces `0x98d6…606` |
| wON implementation (WrappedON) — NEW | _(PENDING post-broadcast)_ | Behind the proxy; rotates on upgrade |
| TimelockController — NEW | _(PENDING post-broadcast)_ | Holds `UPGRADER_ROLE`; 48h min delay |
| BurnMintTokenPool — NEW | _(PENDING post-broadcast)_ | Paired with wON proxy; replaces `0xE0b7…8A72` |

Snapshot of where the mainnet deployment stands. Verified by direct on-chain reads
(`cast call`) this session. **Bridge is NOT yet operational** — see Blocker below.

## Deployer

- **EOA:** `0x08B7e28955D05FfcBd87b2c896BfC23B1A7Dab46`
- **Signer:** encrypted keystore account `deployer` (`~/.foundry/keystores/deployer`); deploys use `--account deployer`, no raw private key on the CLI.
- Holds, until multisig handoff: wON `DEFAULT_ADMIN_ROLE`, both pool `Ownable` ownerships, and (pending) the ETH registry admin role. **Do not hand off until both chains are wired and verified.**

> **Decision (2026-06-19): DO NOT run the multisig handoff yet.** The bridge is still
> pre-operational (path-4 blocked, no live lane), and scripts 04/05 on both chains are
> gated to the **deployer**. Handing off now would turn every remaining wiring step — and
> any fix/redeploy if verification fails — into a multi-signer Safe ceremony. Keep the
> deployer EOA in control through: finish wiring → verify both sides → live bridge test.
> Run handoff + renounce only after that, back-to-back, to keep the single-key window short.

## Deployed contracts

### Ethereum mainnet (chain id 1) — artifact `deployments/1.json`

> **SUPERSEDED 2026-06-23 — pending redeploy.** The addresses below are the pre-redeploy contracts (old wON + old ETH pool). New addresses will be written to `deployments/1.json` after broadcast and should replace this table.

| Contract | Artifact key | Address | Notes |
|---|---|---|---|
| wON (WrappedON) | `wrappedON` | `0x98d6d288AfaB1EdC7A6d49502790FA517765E606` | **OLD — superseded.** Non-upgradeable build (pre-UUPS). No holders, no reserve. |
| BurnMintTokenPool | `pool` | `0xE0b7Dcd123122aC50f47d4E97C8CaFD01BAc8A72` | **OLD — superseded.** Paired with old wON. |
| wON proxy (ERC1967Proxy) — NEW | `wrappedON` | _(PENDING post-broadcast)_ | Stable CCIP-registered token address. Replaces row above. |
| wON implementation — NEW | `wrappedONImpl` | _(PENDING post-broadcast)_ | Upgradeable impl; rotates on upgrade. |
| TimelockController — NEW | `wrappedONTimelock` | _(PENDING post-broadcast)_ | Holds `UPGRADER_ROLE`; 48h default delay. |
| BurnMintTokenPool — NEW | `pool` | _(PENDING post-broadcast)_ | Paired with wON proxy. Replaces old pool row above. |

### BSC mainnet (chain id 56) — artifact `deployments/56.json`

| Contract | Address | Notes |
|---|---|---|
| LockReleaseTokenPool | `0x98d6d288AfaB1EdC7A6d49502790FA517765E606` | `typeAndVersion`="LockReleaseTokenPool 1.6.1"; `getToken`=ON; `owner`=deployer; `getRebalancer`=`0x0` (no rebalancer — correct launch posture) |

> **Address collision (not a bug):** the BSC pool and ETH wON share `0x98d6…606`.
> Both are the deployer's nonce-0 contract, and `CREATE` addresses = `keccak(deployer, nonce)`,
> so the same EOA's first deploy lands on the same address on every chain. Different
> contracts on different chains. Watch for this during manual wiring checks — on the ETH
> side the *remote BSC pool* address equals the *local wON token* address.

### Canonical tokens (pre-existing, not deployed by us)

- ON on Ethereum: `0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d` (600M, non-mintable).
- ON on BSC: `0x0e4F6209eD984b21EDEA43acE6e09559eD051D48` ("Orochi Network Token" / ON). **`owner()` = `address(0)` (renounced); no `getCCIPAdmin`; not AccessControl.** This is the root of the path-4 blocker.

## CCIP infrastructure (validated live 2026-06-14)

- ETH TokenAdminRegistry: `0xb22764f98dD05c789929716D677382Df22C05Cb6`
- BSC TokenAdminRegistry: `0x736Fd8660c443547a85e4Eaf70A49C1b7Bb008fc`
- `make validate-config` passed on both chains (Router 1.2.0, TokenAdminRegistry 1.5.0, RegistryModuleOwnerCustom 1.6.0, ARMProxy 1.0.0; both lanes supported; LINK + 18-dec onToken).

## Per-script status

| Script | ETH (1) | BSC (56) |
|---|---|---|
| 01 DeployWrappedON | ✅ done | n/a (wON is ETH-only) |
| 02 DeployPools | ✅ done | ✅ done |
| 03 GrantRoles (MINTER/BURNER → pool) | ✅ done | n/a |
| 04 RegisterAdminAndPool (`setPool`) | ✅ done (`getPool(wON)`=pool, admin=deployer) | ✅ **done** (`getPool(ON)`=pool; deployer accepted admin) |
| 05 ApplyChainUpdates (remote pool + rate limits) | ✅ **done** (ETH nonce 8; `isSupportedChain(BSC)`=true, remote=BSC pool, remoteToken=BSC ON, limits 100k/10) | ✅ done (`isSupportedChain(ETH)`=true, remote=ETH pool, limits 100k/10) |

> **Fully wired & verified 2026-06-19** — independent `cast` cross-check: 16/16 wiring
> checks pass on both chains, lane is bidirectional and registered both sides. Rate limits
> both directions/both chains: enabled, capacity 100,000 ON, rate 10 ON/sec (the launch
> default — confirm with ops this is the intended production value, RUNBOOK §2.2). Pools
> still owned by deployer (pre-handoff, intentional); BSC `getRebalancer` = address(0).

### ~~Blocker~~ — BSC CCIP admin registration (path-4): ✅ RESOLVED 2026-06-19

Chainlink registered the deployer as ON's administrator via the registry (`proposeAdministrator`);
deployer then `acceptAdminRole` + `setPool`. ON `owner()` is still `address(0)` — resolution
was via Chainlink's registry action, exactly as expected. BSC side fully wired.

## 🚧 Current gap — ETH pool not wired to BSC

Script 05 ran on BSC but **never ran on Ethereum** (ETH nonce still 7). The ETH
`BurnMintTokenPool` has no BSC chain config → lane is **one-directional** (BSC→ETH known,
ETH→BSC missing). Bridging is NOT yet functional.

**Fix (one tx, deployer keystore):**
```
forge script script/05_ApplyChainUpdates.s.sol --rpc-url eth --broadcast --account deployer
```

## Remaining steps

1. ✅ ~~Chainlink registers admin~~ — done.
2. ✅ ~~BSC 04 (acceptAdminRole + setPool)~~ — done.
3. ✅ ~~BSC 05 (wire ETH remote + rate limits)~~ — done.
4. ✅ ~~ETH: run script 05 (wire BSC remote)~~ — done, ETH nonce 8.
5. ✅ ~~verify wiring~~ — done, 16/16 cross-chain checks pass.
6. ⏳ **NEXT: small live bridge test both directions** (RUNBOOK §2.5); record tx hashes.
7. ⏳ Ownership handoff to ops multisig (RUNBOOK §3), then deployer renounce.
   - **Handoff/renounce Makefile targets are gated behind an explicit confirmation**
     (decision 2026-06-19): they will not run without `CONFIRM_HANDOFF=yes` /
     `CONFIRM_RENOUNCE=yes`, so they cannot fire accidentally pre-operational but are
     triggerable by hand when ready — no Makefile edit needed. See RUNBOOK §3.

## Note on verify-* and the handoff check

`forge` auto-loads `.env`, which sets `MULTISIG=0x59E764De248D49C7859e1C719fEfB8e318611FB8`
(the intended ops Safe). With `MULTISIG` set, `08_PostDeployVerify` asserts
`pool.owner() == MULTISIG` and reverts `PoolOwnershipNotHandedOff` pre-handoff. This is
EXPECTED until handoff — it confirms all prior checks passed. For a clean pre-handoff verify,
run with `MULTISIG` unset/removed from forge's view.

## Tooling added this session

- `Makefile`: `deploy-eth` / `deploy-bsc` sign via `--account` (keystore-only); the raw `DEPLOYER_PK` / `--private-key` path was removed.
- `complete-bsc-deployment.sh`: finishes BSC registration + wiring + verification once admin is granted.
- `MAINNET_CHECKLIST.md`: pre-flight checklist (§0 verified 2026-06-14).
- `issue.md`: fork-test self-skip regression under forge 1.7.1 (`make test` shows 3 fork-suite failures; 141 non-fork tests pass — tooling, not contract).

## Notable non-blocking items

- **Etherscan verification** of `0x98d6…606` (wON) and `0xE0b7…8A72` (ETH pool) — deploy used `--verify`; confirm both show verified source.
- **BNB gas** on deployer is thin (~0.0098 BNB as of 2026-06-14) — top up before running BSC 04/05.
- **`OPS-29`** (BSC ON fixed-supply / no-minter) not yet explicitly probed.
- Testnet dry-run was intentionally skipped (deployed straight to mainnet).
