# Architecture — Orochi Network ON Bridge

This document describes the architecture of the **ON ⇄ wON** bridge between
Ethereum Mainnet and BNB Smart Chain. It is the design-level companion to
[`README.md`](../README.md) (operator quickstart), [`RUNBOOK.md`](../RUNBOOK.md)
(deploy + handoff playbook), and [`SECURITY.md`](../SECURITY.md) (per-finding
audit log).

The bridge is built on **Chainlink CCIP** using the **Cross-Chain Token (CCT)**
standard. Most of the on-chain surface is stock Chainlink contracts; the only
custom contract in this repo is [`src/WrappedON.sol`](../src/WrappedON.sol).

---

## 1. High-level picture

```
        ─────────────────────────  Ethereum Mainnet  ───────────────────────────
        ┌─────────────┐         ┌─────────────────────┐          ┌───────────────┐
        │  ON (600M)  │ ◀─────▶ │   WrappedON (wON)   │ ◀──────▶ │ BurnMintPool  │
        │ non-mintable│ deposit │  reserve + ERC20    │  mint /  │ (stock CCIP)  │
        └─────────────┘ withdraw│  ccipMintHeadroomUsed   │  burn    │ MINTER/BURNER │
                                └─────────────────────┘          └───────┬───────┘
                                                                         │ lockOrBurn /
                                                                         │ releaseOrMint
                                                                         ▼
                                                               ┌──────────────────┐
                                                               │  CCIP Router +   │
                                                               │  OnRamp/OffRamp  │
                                                               │  + RMN proxy     │
                                                               └────────┬─────────┘
                                                                        │ DON-relayed
                                                                        │ commit + exec
        ─────────────────────────  BNB Smart Chain  ────────────────────┼─────────
                                                                        ▼
        ┌─────────────┐                                        ┌──────────────────┐
        │  ON (100M)  │ ◀────────────  lock / release  ──────▶ │ LockReleasePool  │
        │  canonical  │                                        │ acceptLiquidity= │
        └─────────────┘                                        │ false (stock)    │
                                                               └──────────────────┘
```

Two chains, one canonical asset family:

- **Ethereum side** uses a **burn/mint** pool against a new token (**wON**) that
  this repo deploys. CCIP-bridged value lives as wON.
- **BSC side** uses a **lock/release** pool against the **existing** ON token.
  Outbound transfers lock ON in the pool; inbound transfers release it.
- **wON** is also a 1:1 wrapper around native ETH-side ON: anyone can `deposit`
  ON to mint wON, and `withdraw` to redeem (subject to reserve availability).

This is **not a generic message bridge** — it transfers only tokens. There is no
arbitrary cross-chain calldata routed through this repo.

---

## 2. CCIP Cross-Chain Token (CCT) primer

The CCT standard is Chainlink's reference architecture for moving an ERC-20-like
asset between CCIP-enabled chains. The major pieces:

| Component | Where | Role |
|---|---|---|
| **Router** | one per chain (Chainlink-deployed) | Single entry point for senders. Exposes `getFee()` + `ccipSend()`. Routes the call into the lane-specific OnRamp. |
| **OnRamp** | per lane (source side) | Validates the message, calls the pool's `lockOrBurn`, assigns a sequence number, emits `CCIPSendRequested`. |
| **OffRamp** | per lane (destination side) | Receives the committed report from the DON, verifies the Merkle proof, calls the pool's `releaseOrMint`, delivers any extra message to the receiver. |
| **Committing DON** | off-chain | Watches OnRamps, batches messages into a Merkle root, posts it via `commit()` on the destination OffRamp. |
| **Executing DON** | off-chain | After commit, executes individual messages on the OffRamp (proof + payload). |
| **RMN (ARMProxy)** | one per chain (Chainlink-deployed) | Risk Management Network — emergency safeguard. If RMN curses a lane / chain, OffRamp halts inbound execution. |
| **TokenAdminRegistry** | one per chain (Chainlink-deployed) | Maps `token → pool` for each chain. OnRamp/OffRamp resolve which pool to call for a given token. |
| **RegistryModuleOwnerCustom** | one per chain (Chainlink-deployed) | Self-service hook for a token developer to claim admin authority for their token in the registry. |
| **TokenPool** | per token per chain (operator-deployed) | The token-specific bridge surface. Either `BurnMintTokenPool` or `LockReleaseTokenPool`. Implements `lockOrBurn` (source) and `releaseOrMint` (destination). Owns rate limiting per remote chain. |

### CCIP message lifecycle (token transfer)

```
1. user.approve(ROUTER, amount)
2. user → ROUTER.ccipSend(msg)
3. ROUTER → OnRamp                                    [source chain]
4. OnRamp → TokenAdminRegistry.getPool(token) → pool
5. OnRamp → pool.lockOrBurn(...)                      // locks or burns
6. OnRamp emits CCIPSendRequested(msg, seqNum)
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
7. Committing DON observes source chain, batches msgs, posts
   commit(merkleRoot, seqRange) to OffRamp            [dest chain]
8. RMN may block here via curse (chain or lane).
9. Executing DON calls OffRamp.execute(msg, proof)    [dest chain]
10. OffRamp → TokenAdminRegistry.getPool(token) → pool
11. OffRamp → pool.releaseOrMint(...)                  // releases or mints
12. (optional) OffRamp delivers extra message to receiver via Router
```

Manual execution: if step 9's automated execution reverts (e.g. receiver runs
out of gas), any EOA can re-submit the proof with a higher gas limit via the
CCIP Explorer. **Token transfers in this bridge have no receiver callback**, so
manual execution is only relevant if a CCIP infrastructure-level revert (gas
estimation, RMN curse cleared, etc.) keeps a message pending.

### Token-administrator handshake

Before a token can be bridged, its admin must be registered in the
`TokenAdminRegistry` on each chain, and the admin must point the registry at a
pool. The standard four-path probe is:

1. `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin(token)` — token
   exposes `getCCIPAdmin()` returning the caller.
2. `RegistryModuleOwnerCustom.registerAdminViaOwner(token)` — token is
   `Ownable` and `owner() == caller`.
3. `RegistryModuleOwnerCustom.registerAccessControlDefaultAdmin(token)` —
   v1.6 path: token uses OZ `AccessControl` and `caller` holds
   `DEFAULT_ADMIN_ROLE`.
4. Manual coordination with Chainlink (token's owner or a Chainlink-internal
   path) — neither operator-callable nor permissionless.

After registration the proposed admin calls `acceptAdminRole(token)`, then
`setPool(token, pool)` to wire the pool. From that point, OnRamp/OffRamp
resolve `token → pool` and bridging is live.

This repo's [`script/04_RegisterAdminAndPool.s.sol`](../script/04_RegisterAdminAndPool.s.sol)
probes paths 1→2→3 in order and reverts with `CannotResolveCCIPAdmin` if none
match (the path-4 reality on BSC; see [`RUNBOOK.md`](../RUNBOOK.md) §0.2).

---

## 3. This bridge's components

### 3.1 Custom contract — `WrappedON` (`src/WrappedON.sol`)

The single custom contract. It is **both**:

- The CCIP burn/mint token on Ethereum (target of `BurnMintTokenPool`).
- A 1:1 wrapper around native ETH-side ON.

Inheritance: `ERC20`, `AccessControl`, `ReentrancyGuard`, `IGetCCIPAdmin`.
Does **not** inherit `IBurnMintERC20` — that interface bundles a vendored OZ
`IERC20` that conflicts with the project's OZ linearization. Selectors
(`mint`, `burn`, `burn(address,uint256)`, `burnFrom`) match exactly, and
`supportsInterface` advertises `type(IBurnMintERC20).interfaceId`, so the
pool's `staticcall`-based interface probes succeed.

**Storage:**

| Slot | Field | Purpose |
|---|---|---|
| immutable | `ON` | Canonical ETH-side ON ERC20 used for `deposit`/`withdraw`. |
| state | `ccipMintHeadroomUsed` | Approximates BSC pool's locked-ON balance. Capped at `MAX_CCIP_MINTED = 100M`. |
| state | `s_ccipAdmin` | Current CCIP admin (read by `RegistryModuleOwnerCustom`). |
| state | `s_pendingCcipAdmin` | Two-step handoff target. Reverts on `address(0)`, self, or `address(this)` proposals. |

**Roles:**

| Role | Held by | Purpose |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | deployer → multisig (handoff) | OZ AccessControl admin. Can grant/revoke `MINTER_ROLE` / `BURNER_ROLE`. |
| `MINTER_ROLE` | Ethereum `BurnMintTokenPool` only | CCIP inbound — calls `mint(account, amount)`. |
| `BURNER_ROLE` | Ethereum `BurnMintTokenPool` only | CCIP outbound — calls one of three `burn` overloads. |
| (logical) `s_ccipAdmin` | deployer → multisig (separate two-step) | Independent of `DEFAULT_ADMIN_ROLE`. Read by registry. |

**Entry points:**

| Function | Caller | Effect |
|---|---|---|
| `deposit(amount)` | anyone | Pulls ON, mints wON 1:1. Received-amount accounting. `nonReentrant`. Uncapped. |
| `withdraw(amount)` | anyone | Burns wON, returns ON from reserve. Reverts on `InsufficientReserve`. `nonReentrant`. |
| `mint(account, amount)` | `MINTER_ROLE` (pool) | CCIP-inbound mint. Increments `ccipMintHeadroomUsed` and reverts if cap exceeded. Emits `CCIPMinted`. |
| `burn(amount)` / `burn(account, amount)` / `burnFrom(account, amount)` | `BURNER_ROLE` (pool) | CCIP-outbound burn. Saturating-decrements `ccipMintHeadroomUsed`. Emits `CCIPBurned`. |
| `setCCIPAdmin(addr)` / `acceptCCIPAdmin()` | current / pending admin | Two-step CCIP admin rotation. |
| `getCCIPAdmin()` / `pendingCCIPAdmin()` | view | Registry probes + handoff verification. |

### 3.2 Stock Chainlink contracts (vendored, not subclassed)

| Contract | Chain | Source path |
|---|---|---|
| `BurnMintTokenPool` | ETH | `lib/ccip/.../ccip/pools/BurnMintTokenPool.sol` |
| `LockReleaseTokenPool` | BSC | `lib/ccip/.../ccip/pools/LockReleaseTokenPool.sol` |
| `TokenAdminRegistry` | both | `lib/ccip/.../ccip/tokenAdminRegistry/TokenAdminRegistry.sol` |
| `RegistryModuleOwnerCustom` | both | `lib/ccip/.../ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol` |

`lib/ccip` is pinned to **`v2.17.0-ccip1.5.16`** to match the deployed production
CCIP 1.5.x ABI on both ETH + BSC mainnet. Decision rationale: subclassing was
considered (e.g. to disable `setRebalancer` on the BSC pool) and rejected —
extra inheritance increases audit surface for zero functional gain, and the
trust model is the documented Chainlink CCT pattern.

### 3.3 Configuration — `script/Helper.sol`

Per-chain CCIP infrastructure addresses + chain selectors. All addresses are
intentional `address(0)` placeholders to be filled from the
[CCIP directory](https://docs.chain.link/ccip/directory) before broadcast.
Every consumer calls `_requireSet` so a missed placeholder reverts with
`MissingAddress(what)`.

Chain selectors (`uint64`) are stable and committed:

| Chain | ID | CCIP selector |
|---|---|---|
| Ethereum Mainnet | 1 | 5009297550715157269 |
| Sepolia | 11155111 | 16015286601757825753 |
| BSC Mainnet | 56 | 11344663589394136015 |
| BSC Testnet | 97 | 13264668187771770619 |

---

## 4. Token model

There are three tokens to keep straight, all 18 decimals:

| Symbol | Chain | Contract | Supply model | Address |
|---|---|---|---|---|
| ON | Ethereum | existing, non-mintable | fixed 600M | `0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d` |
| wON | Ethereum | this repo | CCIP-mint capped at 100M + uncapped deposit-mint | (deployed) |
| ON | BSC | existing | fixed 100M | `0x0e4F6209eD984b21EDEA43acE6e09559eD051D48` |

### 4.1 Why wON exists

ETH-side ON is **non-mintable**. CCIP burn/mint pools require a token whose
mint/burn the pool can call. wON is the minimum surface that satisfies that
contract while:

1. Letting ETH-side ON holders opt into the bridge (via the `deposit` wrap path).
2. Capping CCIP-minted exposure to the BSC ON canonical supply (the absolute
   upper bound on ON that can ever be locked on the BSC pool).
3. Keeping `totalSupply` recognizable to wallets/indexers as a normal ERC-20.

### 4.2 Two mint paths, one fungible token

```
        ┌──────────────────────────┐
        │   ON.balanceOf(wON)      │  reserve (held by wON itself)
        │   (backing for           │
        │    deposit-minted wON)   │
        └────────────▲─────────────┘
                     │
                     │ deposit / withdraw — uncapped, 1:1 against reserve
                     │
        ┌────────────┴─────────────┐
        │   wON.totalSupply()      │  fungible — no provenance tag
        └────────────┬─────────────┘
                     │
                     │ mint / burn — capped at 100M, pool-only
                     │
        ┌────────────▼─────────────┐
        │   wON.ccipMintHeadroomUsed   │  approximates BSC locked-ON balance
        │   (BurnMintTokenPool)    │
        └──────────────────────────┘
```

Both mint paths produce **fungible** wON. They are backed differently:

- **`deposit(amount)`** — user pulls native ETH ON; wON minted is backed by ON
  held in the wON contract's own reserve. Uncapped (bounded naturally by
  ETH-side ON supply). Independent of CCIP.
- **`mint(...)`** — the Ethereum `BurnMintTokenPool` calls this on inbound CCIP
  messages. Backed by ON locked on the BSC `LockReleaseTokenPool`.

### 4.3 Invariants

**Wrap-reserve invariant** (mechanical, not stored):

> `{wON minted via deposit and still circulating} ≤ ON.balanceOf(wON contract)`

Enforced by `withdraw` reverting on insufficient reserve, plus `deposit`'s
received-amount accounting that adds to the reserve and `totalSupply` in
lockstep.

**Safety invariant** (the one operators monitor):

> `lockedON_BSC + reserveON_ETH ≥ totalSupply(wON)`

This holds because every CCIP `mint` on ETH pairs with a `lock` on BSC, and
every CCIP burn pairs with a `release`. The reserve side is independent
(deposit/withdraw moves ETH-side ON and wON in lockstep without touching BSC).

### 4.4 `MAX_CCIP_MINTED` cap

`MAX_CCIP_MINTED = 100_000_000 ether` (matches canonical BSC ON supply).
`ccipMintHeadroomUsed` is incremented in `mint(...)` (reverts on cap breach) and
**saturating-decremented** on every burn entry-point.

The cap bounds damage from a **buggy or compromised pool** that could mint
without a matching BSC lock. It is **not** a per-token-provenance counter:
wON is fungible, and a deposit-backed user can bridge OUT (burning wON,
saturating-decrementing the counter even though the mint was never
CCIP-sourced). Under honest pool behaviour the counter tracks live BSC-locked
balance; under buggy behaviour it bounds the upside.

> Monitoring tip (`SECURITY: WON-3 / CCIP-7`): for real cross-chain exposure,
> read `IERC20(ON).balanceOf(BSC_LockReleaseTokenPool)` as ground truth.
> Treat `ccipMintHeadroomUsed` as a useful local indicator, not the authoritative
> "value in flight" number.

---

## 5. End-to-end flows

### 5.1 Wrap on Ethereum (no CCIP involved)

```
user                wON contract             ON token
  │     deposit(N)     │                        │
  │ ─────────────────▶ │                        │
  │                    │  safeTransferFrom(...) │
  │                    │ ─────────────────────▶ │   (N moves to wON's
  │                    │                        │    own balance)
  │                    │   _mint(user, recvd)   │
  │ ◀───────────────── │                        │
  │  wON balance +N    │  emit Wrapped          │
```

`withdraw` is the symmetric reverse, gated by
`reserve = ON.balanceOf(wON) ≥ amount`.

### 5.2 Outbound: BSC → Ethereum

```
1. user.approve(BSC_ROUTER, amount)
2. user → BSC_ROUTER.ccipSend({receiver: 0x<eth_addr>, tokens: [ON, amount], ...})
3. BSC_ROUTER → BSC_OnRamp
4. BSC_OnRamp → LockReleaseTokenPool.lockOrBurn(amount, sender, dest, ...)
                ─ moves ON from user to the pool (LOCK)
                ─ checks outbound rate limiter
5. BSC_OnRamp emits CCIPSendRequested
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
6. Committing DON commits batch to ETH_OffRamp.commit(merkleRoot)
7. Executing DON calls ETH_OffRamp.execute(msg, proof)
8. ETH_OffRamp → BurnMintTokenPool.releaseOrMint(receiver, amount, src, ...)
                ─ checks inbound rate limiter
                ─ calls wON.mint(receiver, amount)
                ─ wON checks ccipMintHeadroomUsed + amount ≤ MAX_CCIP_MINTED
                ─ emits CCIPMinted
9. receiver holds `amount` wON on Ethereum
```

### 5.3 Outbound: Ethereum → BSC

```
1. user.approve(ETH_ROUTER, amount)
2. user → ETH_ROUTER.ccipSend({receiver: 0x<bsc_addr>, tokens: [wON, amount], ...})
3. ETH_ROUTER → ETH_OnRamp
4. ETH_OnRamp → BurnMintTokenPool.lockOrBurn(amount, sender, dest, ...)
                ─ pool transfers `amount` wON from user to itself
                ─ pool calls wON.burn(amount) (one of three overloads)
                ─ wON saturating-decrements ccipMintHeadroomUsed
                ─ emits CCIPBurned
                ─ checks outbound rate limiter
5. ETH_OnRamp emits CCIPSendRequested
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
6. Committing DON commits batch to BSC_OffRamp.commit(...)
7. Executing DON calls BSC_OffRamp.execute(msg, proof)
8. BSC_OffRamp → LockReleaseTokenPool.releaseOrMint(receiver, amount, src, ...)
                ─ checks inbound rate limiter
                ─ pool transfers `amount` ON from itself to receiver (RELEASE)
9. receiver holds `amount` ON on BSC
```

### 5.4 Cross-flow: deposit → bridge

A user wanting native ETH ON on BSC follows two distinct steps:

1. `wON.deposit(amount)` — wraps ON to wON on Ethereum.
2. `ROUTER.ccipSend(wON, amount, bsc_receiver)` — burns wON, releases ON on BSC.

After step 2, `ccipMintHeadroomUsed` on wON has saturating-decremented (even
though the original mint was a `deposit`, not a CCIP inbound) — by design,
because wON is fungible and the BSC-locked balance has correspondingly
decreased.

---

## 6. Rate limiting

CCIP pools enforce **token-bucket rate limits per remote chain**, separately
for outbound and inbound. Configured via
`TokenPool.setChainRateLimiterConfig(remoteSelector, outboundCfg, inboundCfg)`.

Each bucket is a `RateLimiter.Config { isEnabled, capacity, rate }`:

- `isEnabled=true` requires `0 < rate < capacity` (strict).
- `isEnabled=false` requires `capacity == 0 AND rate == 0`.

[`script/07_UpdateRateLimits.s.sol`](../script/07_UpdateRateLimits.s.sol)
mirrors these validation rules in a preflight so misconfiguration fails
off-chain rather than mid-broadcast.

**Initial values** (calibrate before mainnet, see RUNBOOK §2.2):

| Direction | Capacity | Rate | Refill from zero |
|---|---|---|---|
| Outbound | 100,000 ON | 10 ON/sec (~864k/day) | ~2.8 h |
| Inbound | 100,000 ON | 10 ON/sec | ~2.8 h |

Symmetric capacity is intentional. The ETH-inbound side is already protected
by `MAX_CCIP_MINTED`; symmetric limits keep operator surface predictable.

**Authority**: rate-limit changes are callable by:

- `Ownable.owner` (the pool owner — the multisig post-handoff), OR
- The optional `rateLimitAdmin` set via `TokenPool.setRateLimitAdmin(addr)`.

Delegating to a `rateLimitAdmin` lets a hot key tune limits without going
through the cold multisig (Chainlink CCT best practice).

---

## 7. Risk Management Network (RMN)

The RMN proxy address (`rmnProxy`) is wired into each pool at construction.
The OffRamp consults RMN on every inbound delivery; if RMN has cursed the lane
(or the chain), execution halts automatically. There is no operator-side
intervention required to honour a curse — coordinate with Chainlink to resolve
the underlying incident, and execution resumes once RMN un-curses.

---

## 8. Authority & handoff map

```
                                  Deployer EOA
                                     │
                              (one-time deploy)
                                     │
        ┌────────────────────────────┼────────────────────────────┐
        ▼                            ▼                            ▼
ETH BurnMintTokenPool         wON contract             BSC LockReleaseTokenPool
   Ownable.owner             DEFAULT_ADMIN_ROLE             Ownable.owner
                              (+ s_ccipAdmin)
                                                          (+ setRebalancer)

   TokenAdminRegistry         TokenAdminRegistry
   .administrator(wON)        .administrator(ON_BSC)

                                ↓ handoff (script 06)
                                ↓ two-step on every role

                              Ops Multisig
                              (Gnosis Safe)

                                ↓ renounce (script 06 RenounceDeployerAdmin)

                       Deployer EOA: no roles, no ownership
```

| Role / surface | Initial holder | Final holder | Handoff mechanism |
|---|---|---|---|
| ETH `BurnMintTokenPool.owner` | deployer | multisig | Two-step `transferOwnership` / `acceptOwnership` |
| BSC `LockReleaseTokenPool.owner` | deployer | multisig | Two-step `transferOwnership` / `acceptOwnership` |
| `wON.DEFAULT_ADMIN_ROLE` | deployer | multisig + deployer renounces | Grant to multisig, then `renounceRole` (preconditioned on multisig having accepted) |
| `wON.MINTER_ROLE` / `BURNER_ROLE` | none → ETH pool (script 03) | ETH pool | Granted once at deploy; never moves |
| `wON.s_ccipAdmin` | deployer (set in ctor) | multisig | Two-step `setCCIPAdmin` / `acceptCCIPAdmin` |
| `TokenAdminRegistry.administrator(token)` (per chain) | deployer | multisig | Two-step `transferAdminRole` / `acceptAdminRole` |
| BSC pool `setRebalancer` / `withdrawLiquidity` | (unset) | multisig-controlled | Implicit — pool owner can `setRebalancer` at any time post-handoff |

**Two-step pattern everywhere.** Every authority transfer in the system —
`Ownable`, `AccessControl` admin, CCIP admin, registry admin — is two-step.
A typo'd target leaves the role with the proposer; a re-propose can overwrite
the pending slot. `wON.setCCIPAdmin` additionally rejects `address(0)`, the
current admin (self-proposal), and `address(this)` (would soft-lock the role)
via `InvalidCCIPAdmin`; overwriting an in-flight proposal emits
`CCIPAdminProposalCancelled(prev)` so any party with a queued `acceptCCIPAdmin`
gets a clear signal.

---

## 9. Trust model

**Bridge security ultimately rests on three trust assumptions:**

1. **Chainlink CCIP infrastructure** — the DONs, RMN, OnRamps/OffRamps, and
   TokenAdminRegistry behave correctly. This is the same trust assumption every
   CCIP CCT deployment makes.
2. **The ops multisig** — post-handoff, the multisig holds custody of the
   BSC-side locked-ON reserve via `setRebalancer` → `withdrawLiquidity`. This
   is the **documented Chainlink CCT pattern** for `LockReleaseTokenPool` and
   is intentional. We deploy with `acceptLiquidity=false` to disable
   `provideLiquidity`, but `withdrawLiquidity` remains operator-controlled by
   design. Subclassing to disable this was considered and rejected.
3. **The deployer EOA, during the handoff window** — between the grant in
   script 06 and the multisig accepts, the deployer still holds wON
   `DEFAULT_ADMIN_ROLE` and the BSC pool ownership. A compromised deployer key
   here could grant `MINTER_ROLE` to an attacker (unbacked mint) or drain the
   BSC reserve. Minimize this window and monitor while in flight — see RUNBOOK
   §3.1.

`RUNBOOK.md` enumerates the events to monitor (BSC `LiquidityRemoved`,
`setRebalancer` calldata trace, ETH `RoleGranted(MINTER_ROLE/BURNER_ROLE, *)`
where grantee isn't the audited pool, and CCIPAdminTransferred /
CCIPAdminProposalCancelled).

---

## 10. Deployment topology

The deploy sequence is encoded in numbered Forge scripts dispatched per
`block.chainid`. Every script is **idempotent** so a mid-sequence failure can
be recovered by re-running the same `make` target.

```
script/01_DeployWrappedON.s.sol         ETH only        ─ deploys wON
script/02_DeployPools.s.sol             both chains     ─ deploys pool (chain-dispatched)
script/03_GrantRoles.s.sol              ETH only        ─ grants MINTER/BURNER on wON to pool
script/04_RegisterAdminAndPool.s.sol    both chains     ─ probes admin path, accepts, setPool
script/05_ApplyChainUpdates.s.sol       both chains     ─ wires remote pool + rate limits
script/06_TransferOwnership.s.sol       both chains     ─ handoff to multisig (+ Renounce on ETH)
script/07_UpdateRateLimits.s.sol        ops             ─ adjust rate limits
script/08_PostDeployVerify.s.sol        both chains     ─ view-only wiring assertion
```

Deployment artifacts live in `deployments/<chainId>.json` with keys
`.wrappedON` (ETH only) and `.pool` (every chain). Subsequent scripts read
these via `Deployments.tryReadAddress`, which returns `address(0)` on missing
file / missing key / malformed JSON so the calling script's `_requireSet`
diagnostic fires with a clear message instead of a low-level Foundry panic.

```
deploy-eth:                 deploy-bsc:
  01 → 02 → 03 → 04 → 05      02 → 04 → 05
```

After both chains are deployed and `make verify-*` is clean:

```
make handoff-all ETH_RPC=… BSC_RPC=… MULTISIG=0x…
  → script 06 on ETH (TransferOwnership)
  → script 06 on BSC (TransferOwnership)
  → (multisig actions, off-chain)
  → MULTISIG=… make verify-eth / verify-bsc
  → make renounce RPC=eth MULTISIG=…   ← script 06 RenounceDeployerAdmin
```

---

## 11. Test surface

The test suite is the executable specification for the architecture:

| Test file | Purpose |
|---|---|
| `test/WrappedON.t.sol` | Unit tests for every wON entry-point including reentrancy probe. |
| `test/WrappedONInvariant.t.sol` | 4 stateful invariants over 9 handler actions (reserve invariant, cap monotonicity, role gating, two-step admin). |
| `test/PoolRoundtrip.t.sol` | Pool wiring + `lockOrBurn` / `releaseOrMint` with mock router + rate-limit fuzz. |
| `test/DeploymentE2E.t.sol` | Full deploy sequence in-process incl. handoff + rate-limit update. |
| `test/Script04Paths.t.sol` | Admin-path dispatch coverage for all four paths in script 04. |
| `test/Script06Guards.t.sol`, `Script06Renounce.t.sol` | Handoff env-var guards + renounce-precondition assertions. |
| `test/Script07Preflight.t.sol` | Rate-limit preflight validation matches CCIP. |
| `test/Script08Verify.t.sol` | Post-deploy verifier covers every assertion path. |
| `test/fork/Fork_ETH.t.sol` | ETH mainnet fork — deploy + registry + bridge sim. |
| `test/fork/Fork_BSC.t.sol` | BSC mainnet fork — token ownership probe + pool + bridge sim. |
| `test/fork/Fork_Bridge.t.sol` | Dual-fork BSC → ETH → BSC roundtrip against live CCIP. |

`make test` runs 130 tests (126 unit/integration + 4 stateful invariants).
`make test-fork ETH_RPC=… BSC_RPC=…` adds 9 mainnet fork tests.

---

## 12. Security index

See [`SECURITY.md`](../SECURITY.md) for the consolidated review with per-finding
status. Finding IDs are prefixed by area:

| Prefix | Area |
|---|---|
| `WON-` | `WrappedON` token contract. |
| `DEP-` | Deployment / artifact handling. |
| `CCIP-` | CCIP wiring, pool config, rate limits. |
| `TEST-` | Test surface, fuzz, coverage gaps. |
| `OPS-` | Operational / runbook / key handling. |

Disclosure: `security@orochi.network`.

---

## 13. Open items (pre-mainnet)

- **CCIP infrastructure addresses in `script/Helper.sol`** are placeholders.
  Fill them in from the [CCIP directory](https://docs.chain.link/ccip/directory)
  before broadcast. Scripts revert with `MissingAddress` if missed.
- **BSC ON CCIP-admin hook**: confirm whether the canonical BSC ON exposes
  `getCCIPAdmin`, is `Ownable`, or uses OZ `AccessControl`. RUNBOOK §0.2
  documents the read-only `cast call` probes to run before broadcasting
  script 04 on mainnet (tracked as `TEST-7`/`Known open items` — the
  prior `H-4` legacy audit tag).
- **BSC ON non-mintability** (OPS-29): the bridge assumes BSC ON's supply
  is the immutable 100M `MAX_CCIP_MINTED` ceiling. Confirm with `cast call`
  in RUNBOOK §0.2 that no minter / unbounded mint function exists on
  `0x0e4F62…` before mainnet broadcast.
- **Mainnet key handling**: deploy via Foundry's encrypted keystore
  (`cast wallet import deployer --interactive` + `--account deployer`)
  rather than `--private-key $DEPLOYER_PK`, which leaks the key into
  `ps aux` and shell history. See RUNBOOK §0.3 + SECURITY `OPS-1`.

---

## 14. References

- **Chainlink CCIP CCT overview** —
  <https://docs.chain.link/ccip/concepts/cross-chain-token/overview>
- **CCIP EVM components** —
  <https://docs.chain.link/ccip/concepts/architecture/onchain/evm/components>
- **CCIP best practices (EVM)** —
  <https://docs.chain.link/ccip/concepts/best-practices/evm>
- **CCIP directory (live addresses)** —
  <https://docs.chain.link/ccip/directory>
- **Reference repo (CCIP starter kit)** —
  <https://github.com/smartcontractkit/ccip-starter-kit-foundry>
- **This repo** — [`README.md`](../README.md), [`RUNBOOK.md`](../RUNBOOK.md),
  [`SECURITY.md`](../SECURITY.md), [`CLAUDE.md`](../CLAUDE.md).
