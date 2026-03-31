# Production Guide: ON Token Bridge (Ethereum <-> BSC) with Hyperlane

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Phase 0: Pre-Migration Due Diligence](#3-phase-0-pre-migration-due-diligence)
4. [Phase 1: Infrastructure Setup](#4-phase-1-infrastructure-setup)
5. [Phase 2: Warp Route Deployment](#5-phase-2-warp-route-deployment)
6. [Phase 3: Old BSC ON Migration (Swap Contract)](#6-phase-3-old-bsc-on-migration-swap-contract)
7. [Phase 4: Security Hardening](#7-phase-4-security-hardening)
8. [Phase 5: Validator & Relayer Operations](#8-phase-5-validator--relayer-operations)
9. [Phase 6: Monitoring & Maintenance](#9-phase-6-monitoring--maintenance)
10. [Phase 7: Frontend & Go-Live](#10-phase-7-frontend--go-live)
11. [Phase 8: Post-Migration](#11-phase-8-post-migration)
12. [Operational Runbooks](#12-operational-runbooks)
13. [Cost Estimation](#13-cost-estimation)
14. [Security Checklist](#14-security-checklist)

---

## Version Compatibility Matrix

> **Critical**: All Hyperlane packages must be from the same release family.

| Component | Pinned Version | Notes |
|-----------|---------------|-------|
| **CLI** (`@hyperlane-xyz/cli`) | **v29.1.0** | Only dependency in `package.json` |
| **Core Contracts** (`@hyperlane-xyz/core`) | **v11.1.0** | Deployed via CLI (includes HypERC20) |
| **Agent Docker Image** | **`gcr.io/abacus-labs-dev/hyperlane-agent:agents-v1.7.0`** | Pinned for validator & relayer |
| **Node.js** | **v18+** | Required by CLI |
| **Foundry** | **Latest stable** | For ONSwap contract + verification |
| **Solidity** | **v0.8.28** | For ONSwap contract |
| **OpenZeppelin** | **v5.1.0** | SafeERC20 in ONSwap |

### Mainnet Contract Addresses (from Hyperlane Registry)

Pre-deployed Hyperlane v3 core contracts. The CLI detects these automatically.

| Contract | Ethereum | BSC |
|----------|----------|-----|
| **Mailbox** | `0xc005dc82818d67AF737725bD4bf75435d065D239` | `0x2971b9Aec44bE4eb673DF1B88cDB57b96eefe8a4` |
| **Domain ID** | `1` | `56` |

---

## 1. Architecture Overview

### Token Situation

- **Ethereum**: 600M ON (canonical ERC20, cannot mint more)
- **BSC**: 100M ON (old, separate contract)
- **Goal**: Bridge ON between ETH <-> BSC and migrate old BSC ON holders to the new bridgeable token

### Solution: Hyperlane Warp Route + Swap Contract

```
Ethereum                              BSC
┌───────────────────┐   Hyperlane    ┌───────────────────┐
│ ON Token (600M)   │ ────────────> │ HypERC20 Synthetic │
│ HypERC20Collateral│ <──────────── │ (100M pre-minted   │
│ (lock/unlock)     │   mint/burn   │  to deployer)      │
└───────────────────┘               └─────────┬─────────┘
                                              │ seeded
                                    ┌─────────┴─────────┐
                                    │ ONSwap.sol         │
                                    │ old BSC ON → new ON│
                                    │ 1:1 SafeERC20      │
                                    └───────────────────┘
```

### How It Works

1. **Hyperlane CLI** deploys `HypERC20Collateral` on Ethereum and `HypERC20` synthetic on BSC
2. `HypERC20.initialize(initialSupply=100M)` pre-mints 100M synthetic ON to the deployer
3. Deployer transfers 100M synthetic ON into the `ONSwap` contract
4. Old BSC ON holders call `swap(amount)` — old ON in, new synthetic ON out, 1:1
5. Bridge is live — users can `transferRemote()` ON between ETH <-> BSC

### Key Components

| Component | Role | Deployed By |
|-----------|------|-------------|
| **HypERC20Collateral** | Locks ON on Ethereum when bridging to BSC | Hyperlane CLI |
| **HypERC20 (Synthetic)** | Mints/burns ON on BSC; 100M pre-minted | Hyperlane CLI |
| **ONSwap** | 1:1 swap: old BSC ON → new synthetic ON | Foundry |
| **Mailbox** | Cross-chain message dispatch/processing | Pre-deployed by Hyperlane |
| **ISM** | Verifies message authenticity | Configured via CLI |
| **Validator** | Signs merkle root checkpoints | Docker agent |
| **Relayer** | Delivers messages between chains | Docker agent |

### Why We Only Need One Custom Contract

Hyperlane's `HypERC20.initialize()` accepts an `initialSupply` parameter that pre-mints tokens to the deployer. This eliminates the need for custom token contracts. The only custom contract is `ONSwap.sol` — a minimal 1:1 swap using SafeERC20 with owner recovery for emergencies.

### Important: Pre-Minted Tokens and Collateral

The 100M pre-minted synthetic ON represents the existing 100M old BSC ON supply. These tokens are **not backed by ETH collateral** — they replace old BSC ON which is burned (sent to `0x...dEaD`) on every swap.

**Bridging behavior:**

- If **no ETH ON** has been bridged to BSC: the ETH collateral contract holds 0 ON. Any attempt to bridge synthetic ON from BSC → ETH will **fail on the ETH side** (no tokens to release). The burn on BSC still executes but delivery on ETH reverts. Hyperlane retries until collateral exists.
- If **some ETH ON** has been bridged to BSC: collateral exists. ALL synthetic ON holders (including swap recipients) can bridge BSC → ETH on a **first-come-first-served** basis, up to the collateral balance.
- There is **no on-chain distinction** between pre-minted and bridge-minted synthetic ON. They are fungible.

**Recommended operational sequence to minimize risk:**

1. Deploy warp route + ONSwap
2. Complete the old BSC ON swap migration
3. Owner recovers any unswapped synthetic via `recover()`
4. **Then** open the bridge for ETH ↔ BSC traffic

This ensures pre-minted tokens are consumed by the swap before any ETH collateral is deposited.

---

## 2. Prerequisites

### Key Roles & Addresses

| Role | Purpose | Key Type |
|------|---------|----------|
| **Deployer** | Deploys warp route + swap contract | Hex key (used once) |
| **Owner** | Governs warp route config | Gnosis Safe multisig |
| **Validator** | Signs checkpoints | AWS KMS |
| **Relayer** | Submits cross-chain transactions | AWS KMS |

> **Never reuse the same key across roles in production.**

### Funding Requirements

| Chain | Role | Amount |
|-------|------|--------|
| Ethereum | Deployer | ~0.3-0.5 ETH |
| Ethereum | Relayer | ~0.1 ETH (ongoing) |
| BSC | Deployer | ~0.05 BNB |
| BSC | Relayer | ~0.1 BNB (ongoing) |

### Software Requirements

```bash
# Node.js v18+
node --version

# Hyperlane CLI (pinned)
npm install -g @hyperlane-xyz/cli@29.1.0
hyperlane --version   # 29.1.0

# Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge --version

# Docker (for agents)
docker --version
```

### Project Setup

```bash
git clone <this-repo>
cd bridge2
npm install        # installs @hyperlane-xyz/cli@29.1.0
forge install      # installs OpenZeppelin + forge-std
forge test -vv     # verify tests pass
```

---

## 3. Phase 0: Pre-Migration Due Diligence

### 3.1 Audit Old BSC ON Token

Before deploying anything, verify the old BSC ON token properties:

```bash
# Decimals (must be 18)
cast call $OLD_ON_TOKEN_BSC "decimals()(uint8)" --rpc-url $BSC_RPC_URL

# Total supply
cast call $OLD_ON_TOKEN_BSC "totalSupply()(uint256)" --rpc-url $BSC_RPC_URL

# Fee-on-transfer check: send 100 ON between two wallets and compare balances
# Replace $TEST_WALLET with a test address you control
cast send $OLD_ON_TOKEN_BSC "transfer(address,uint256)" $TEST_WALLET 100000000000000000000 \
  --rpc-url $BSC_RPC_URL --private-key $HYP_KEY
cast call $OLD_ON_TOKEN_BSC "balanceOf(address)(uint256)" $TEST_WALLET --rpc-url $BSC_RPC_URL
# Must return exactly 100000000000000000000 (100 * 1e18). If less, token has transfer fee.
# If fee-on-transfer exists, ONSwap will give more new ON than old ON was burned. Do NOT deploy.

# Check if contract is a proxy (upgradeable)
cast storage $OLD_ON_TOKEN_BSC 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $BSC_RPC_URL
# Non-zero = proxy. Check who the admin is.

# Check if pausable
cast call $OLD_ON_TOKEN_BSC "paused()(bool)" --rpc-url $BSC_RPC_URL 2>/dev/null || echo "No pause function"

# Check owner
cast call $OLD_ON_TOKEN_BSC "owner()(address)" --rpc-url $BSC_RPC_URL 2>/dev/null || echo "No owner function"
```

### 3.2 Inventory Old BSC ON Supply

Document where the 100M old BSC ON currently lives:
- [ ] Wallets (top holders on BscScan)
- [ ] DEX liquidity pools (PancakeSwap old-ON/BNB, etc.)
- [ ] CEX listings (which exchanges, contact info)
- [ ] DeFi protocols (staking, lending, vesting contracts)
- [ ] Smart contracts that cannot call `swap()` (need special handling)

### 3.3 Communication Plan

- [ ] Draft migration announcement (what, why, how, timeline)
- [ ] Notify CEXes 2-4 weeks before go-live (halt old ON deposits, update contract)
- [ ] Submit new token contract to CoinGecko/CMC after warp deploy
- [ ] Prepare user-facing swap guide (BscScan "Write Contract" walkthrough)
- [ ] Channels: Twitter/X, Discord, Telegram, blog post

### 3.4 Testnet Rehearsal

Run the full deployment flow on Sepolia + BSC Testnet before mainnet:

1. Deploy mock ON token on Sepolia
2. `hyperlane warp init` + `warp deploy` on testnets
3. Verify `initialSupply` mints to deployer
4. Deploy ONSwap on BSC testnet, seed, test swap
5. Test bridge both directions
6. Start validator + relayer on testnets, verify message delivery
7. Document all issues found

---

## 4. Phase 1: Infrastructure Setup

### 4.1 AWS KMS Keys

```bash
# Validator signing key
aws kms create-key \
  --key-spec ECC_SECG_P256K1 \
  --key-usage SIGN_VERIFY \
  --description "Hyperlane Validator - ON Token ETH<>BSC"
# Record the KeyId from output, then create alias:
aws kms create-alias --alias-name alias/hyperlane-validator-on --target-key-id <KeyId>

# Relayer signing key
aws kms create-key \
  --key-spec ECC_SECG_P256K1 \
  --key-usage SIGN_VERIFY \
  --description "Hyperlane Relayer - ON Token ETH<>BSC"
aws kms create-alias --alias-name alias/hyperlane-relayer-on --target-key-id <KeyId>
```

Derive Ethereum addresses from KMS public keys (needed for funding):

```bash
# Get public key and derive address
aws kms get-public-key --key-id alias/hyperlane-validator-on --output text --query PublicKey | \
  base64 -d | openssl ec -pubin -inform DER -outform PEM 2>/dev/null | \
  openssl ec -pubin -text -noout 2>/dev/null
# Use the public key to derive the Ethereum address, or use cast:
# cast wallet address --public-key <hex_public_key>
```

Record these addresses in `.env` as `VALIDATOR_ADDRESS` and `RELAYER_ADDRESS`. Fund both on ETH and BSC.

IAM policy for agents:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"],
      "Resource": "arn:aws:kms:*:*:key/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::hyperlane-validator-on-eth-bsc*"]
    }
  ]
}
```

### 4.2 S3 Bucket for Validator Signatures

```bash
aws s3 mb s3://hyperlane-validator-on-eth-bsc --region us-east-1

# Public read policy (relayer needs to read signatures)
aws s3api put-bucket-policy \
  --bucket hyperlane-validator-on-eth-bsc \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "PublicRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::hyperlane-validator-on-eth-bsc/*"
    }]
  }'
```

### 4.3 Gnosis Safe Multisig

1. Go to https://app.safe.global
2. Create Safe on **Ethereum** (2-of-3 or 3-of-5)
3. Create Safe on **BSC** with the same signers
4. Record both addresses — these become the warp route owners

### 4.4 Environment Setup

Copy `.env.example` to `.env` and fill in:

```bash
cp .env.example .env
# Fill in: HYP_KEY, ETH_RPC_URL, BSC_RPC_URL, ON_TOKEN_ETHEREUM,
#          OLD_ON_TOKEN_BSC, ETHERSCAN_API_KEY, BSCSCAN_API_KEY
```

---

## 5. Phase 2: Warp Route Deployment

### 5.1 Configure

Edit `configs/warp-route-deploy.yaml`:

```yaml
ethereum:
  type: collateral
  token: "0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d"
  owner: "0xDA5E5Be8f9C5fCdd30f2ee08D6b3F794511C2B48"
  mailbox: "0xc005dc82818d67AF737725bD4bf75435d065D239"

bsc:
  type: synthetic
  initialSupply: "100000000000000000000000000"  # 100M * 1e18, quoted to prevent precision loss
  name: "Orochi Network Token"
  symbol: "ON"
  owner: "0xDA5E5Be8f9C5fCdd30f2ee08D6b3F794511C2B48"
  mailbox: "0x2971b9Aec44bE4eb673DF1B88cDB57b96eefe8a4"
```

The `initialSupply` field causes `HypERC20.initialize()` to mint 100M synthetic ON to the deployer at deploy time. These tokens are used to seed the swap contract. The CLI schema field is `initialSupply` (not `totalSupply`).

### 5.2 Deploy

```bash
export HYP_KEY=0xYourDeployerPrivateKey
```

> **IMPORTANT**: `HYP_KEY` is a raw hex private key. Use a dedicated ephemeral key. Prefix with a space to avoid shell history: `  export HYP_KEY=0x...` (with `HISTCONTROL=ignorespace`). Destroy this key after Phase 7 (security hardening). You can also pass the key inline: `hyperlane warp deploy --key $HYP_KEY`.

**Step 1: Generate config via CLI**

```bash
npm run warp:init
# Runs: hyperlane warp init --out ./configs/warp-route-deploy.yaml
```

Follow the interactive prompts:
- Select network type: Mainnet
- Select chains: ethereum, bsc
- Token type for ethereum: collateral
- Token type for bsc: synthetic
- Enter token address, mailbox, etc.

For advanced ISM configuration during init:

```bash
npm run warp:init:advanced
# Runs: hyperlane warp init --advanced --out ./configs/warp-route-deploy.yaml
```

**Step 2: Manually add `initialSupply` to the generated config**

The CLI may not prompt for `initialSupply`. Edit `configs/warp-route-deploy.yaml` (the file generated by `--out`):

```yaml
bsc:
  type: synthetic
  initialSupply: "100000000000000000000000000"  # 100M * 1e18, quoted to prevent precision loss
  # ... rest of config
```

> **WARNING**: The field MUST be `initialSupply`, not `totalSupply`. The CLI Zod schema silently strips unknown fields. If you use `totalSupply`, zero tokens will be minted and you will not get an error.

**Step 3: Deploy**

```bash
npm run warp:deploy
# Runs: hyperlane warp deploy
# The CLI will prompt to select your warp route from the registry.
# Use -y to skip confirmation prompts: hyperlane warp deploy -y
```

Record deployed addresses:
```
✅ Collateral deployed on ethereum: 0x...
✅ Synthetic deployed on bsc: 0x...
```

Set `NEW_ON_TOKEN_BSC` and `COLLATERAL_CONTRACT` in `.env`.

**Step 4: Record the Warp Route ID**

After deployment, the CLI registers your warp route with an ID. This ID is used by all subsequent CLI commands (`check`, `verify`, `read`, `apply`, `send`, `get-fees`) to identify your route.

The warp route ID format is typically: `<SYMBOL>/<chain1>-<chain2>`, e.g., `ON/ethereum-bsc`.

To find your warp route ID:

```bash
# List all registered warp routes
hyperlane warp read
# The CLI will show available routes and prompt you to select one.

# Once you know the ID, use -w to skip prompts in all commands:
hyperlane warp check -w ON/ethereum-bsc
hyperlane warp read -w ON/ethereum-bsc
hyperlane warp send -w ON/ethereum-bsc --relay --amount 1
```

Record the warp route ID in `.env` or your notes. It is required for non-interactive usage (CI, scripts, `--yes` mode).

**Step 5: Verify 100M was actually minted to deployer**

```bash
cast call $NEW_ON_TOKEN_BSC "balanceOf(address)(uint256)" $DEPLOYER_ADDRESS --rpc-url $BSC_RPC_URL
# MUST return 100000000000000000000000000 (100M * 1e18)
# If it returns 0, initialSupply was not applied. Do NOT proceed.
```

### 5.3 Verify

```bash
# Verify config matches on-chain state
npm run warp:check
# Runs: hyperlane warp check
# Prompts to select warp route. Or specify: hyperlane warp check -w <warp-route-id>

# Verify source code on block explorers
npm run warp:verify
# Runs: hyperlane warp verify -w <warp-route-id>

# Check bridge fees
npm run warp:fees
# Runs: hyperlane warp get-fees --amount 1
```

### 5.4 Smoke Test

```bash
# Send 1 wei ON: ETH → BSC (with self-relay)
npm run warp:send:test
# Runs: hyperlane warp send --relay --amount 1

# For a specific amount, origin, and destination:
hyperlane warp send --relay --amount 1000000000000000000 --origin ethereum --destination bsc

# Send round-trip test (all connected chains):
hyperlane warp send --relay --amount 1 --round-trip

# Verify on Hyperlane Explorer: https://explorer.hyperlane.xyz
```

> **Note**: `--amount 1` sends 1 wei (smallest unit), not 1 token. For 1 full ON token, use `--amount 1000000000000000000`.

### 5.5 Read On-Chain State

```bash
npm run warp:read
# Runs: hyperlane warp read
# Prompts to select warp route. Or specify: hyperlane warp read -w <warp-route-id>

# Save current state to file for later editing (used in Phase 7 for ISM/ownership updates):
npm run warp:read:save
# Runs: hyperlane warp read --out ./configs/warp-route-current.yaml
```

---

## 6. Phase 3: Old BSC ON Migration (Swap Contract)

### 6.1 Deploy + Seed ONSwap (Atomic)

The deploy script deploys the swap contract AND seeds it with 100M synthetic ON in a single broadcast. This eliminates the risk window where tokens sit in the deployer wallet.

> **IMPORTANT: Key mismatch warning.** The 100M synthetic ON was minted to the `HYP_KEY` wallet during warp deploy. The Foundry script's `msg.sender` must be that SAME address. Use `--private-key $HYP_KEY` (not `--ledger`, unless you transfer tokens to the ledger first).

```bash
source .env

# Ensure these are set:
# OLD_ON_TOKEN_BSC, NEW_ON_TOKEN_BSC, SWAP_OWNER, SEED_AMOUNT (optional, default 100M)

# Option A: Use same key as HYP_KEY (recommended for atomic deploy+seed)
forge script script/DeploySwap.s.sol \
  --rpc-url $BSC_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $BSCSCAN_API_KEY \
  --private-key $HYP_KEY \
  -vvvv

# Option B: Use ledger (must transfer 100M synthetic to ledger address first)
# cast send $NEW_ON_TOKEN_BSC "transfer(address,uint256)" $LEDGER_ADDRESS 100000000000000000000000000 \
#   --rpc-url $BSC_RPC_URL --private-key $HYP_KEY
# Then:
# forge script script/DeploySwap.s.sol --rpc-url $BSC_RPC_URL --broadcast --verify --ledger
```

The script will:
1. Verify deployer holds sufficient synthetic ON (reverts with helpful message if not)
2. Deploy ONSwap with constructor validation (zero-address, same-token checks)
3. Transfer synthetic ON to ONSwap via SafeERC20 in the same broadcast
4. Verify the seed balance post-deploy

Record the `ONSwap` address. Set `SWAP_CONTRACT` in `.env`.

### 6.2 Verify

```bash
# Check swap contract holds 100M new ON
cast call $NEW_ON_TOKEN_BSC \
  "balanceOf(address)(uint256)" \
  $SWAP_CONTRACT \
  --rpc-url $BSC_RPC_URL
```

### 6.3 How Users Swap

**Via BscScan (for regular users):**

1. Go to BscScan → Old ON Token → **Write Contract** → `approve`
   - `spender`: ONSwap contract address
   - `amount`: amount in wei (e.g., `1000000000000000000000` for 1000 ON)
2. Go to BscScan → ONSwap Contract → **Write Contract** → `swap`
   - `_amount`: same amount as approved

**Via CLI (for developers):**

```bash
# 1. Approve ONSwap to spend old ON
cast send $OLD_ON_TOKEN_BSC \
  "approve(address,uint256)" \
  $SWAP_CONTRACT \
  <amount> \
  --rpc-url $BSC_RPC_URL --ledger

# 2. Swap old ON for new ON (1:1)
cast send $SWAP_CONTRACT \
  "swap(uint256)" \
  <amount> \
  --rpc-url $BSC_RPC_URL --ledger
```

> **One-way only.** There is no reverse swap. Old ON is permanently burned (sent to `0x...dEaD`). New synthetic ON can be used on BSC DEXes or bridged to Ethereum (only if backed by ETH collateral).

### 6.4 ONSwap Contract Details

`src/ONSwap.sol` — minimal swap with SafeERC20, owner recovery, and ReentrancyGuard:

- **`swap(amount)`** — 1:1 swap, old ON in, new ON out. Reverts on zero amount.
- **`recover(token, to, amount)`** — owner-only. Recover any token (emergency pause by recovering NEW_TOKEN, or recover old tokens post-migration).
- **ReentrancyGuard** — defense-in-depth against malicious token hooks
- **Constructor validation** — reverts on zero addresses or same token
- **Immutable token addresses** — cannot be changed after deployment
- **No receive/fallback** — rejects accidental ETH/BNB

Emergency pause: owner calls `recover(NEW_TOKEN, owner, fullBalance)` to drain new tokens, effectively stopping all swaps.

---

## 7. Phase 4: Security Hardening

### 7.1 Remove Trusted Relayer ISM

During initial deployment, a trusted relayer ISM may be configured. **Remove it for production:**

```bash
# Step 1: Read current on-chain config and save to file
npm run warp:read:save
# Runs: hyperlane warp read --out ./configs/warp-route-current.yaml

# Step 2: Edit configs/warp-route-current.yaml
# Add/change interchainSecurityModule block for both chains (see 7.2 below)

# Step 3: Apply the updated config
npm run warp:apply
# Runs: hyperlane warp apply
# The CLI reads from the registry and applies changes on-chain.
# Use --key $HYP_KEY if HYP_KEY is not in env.
# Use --relay if ICA transactions need self-relay.

# Step 4: Verify
npm run warp:read
# Confirm ISM is no longer trustedRelayerIsm
```

> **Note**: `warp apply` requires the deployer (initial owner) to still be the owner. Do this BEFORE transferring ownership to multisig (7.3). All `warp` commands accept `-w <warp-route-id>` to skip the interactive selection prompt.

### 7.2 ISM Options

| Level | ISM Type | Trade-off |
|-------|----------|-----------|
| **Basic** | `defaultFallbackRoutingIsm` | Hyperlane's default validators; lowest overhead |
| **Standard** | `staticMultisigIsm` (3-of-5) | Your own validators; medium overhead |
| **High** | `staticAggregationIsm` | Requires BOTH Hyperlane + your validators |

To add ISM to your warp config:

```yaml
ethereum:
  type: collateral
  token: "0x..."
  owner: "0x..."
  mailbox: "0x..."
  interchainSecurityModule:
    type: staticAggregationIsm
    modules:
      - type: defaultFallbackRoutingIsm
        owner: "0xDA5E5Be8f9C5fCdd30f2ee08D6b3F794511C2B48"
    threshold: 1
```

### 7.3 Transfer Ownership to Multisig

```bash
# Edit warp-config-current.yaml: change owner fields to Gnosis Safe addresses
# Then apply:
npm run warp:apply
# The CLI will prompt to select warp route and apply changes from the registry

# Verify ownership
npm run warp:read
# Confirm owner fields show Gnosis Safe, NOT deployer EOA
```

### 7.4 Destroy Deployer Key

After ownership is transferred and everything is verified:

```bash
# Clear from environment
unset HYP_KEY

# Clear shell history
history -c  # bash
# or: fc -p /dev/null  # zsh

# Securely delete any key files
```

> The deployer key is no longer needed. All future config changes go through the Gnosis Safe multisig.

---

## 8. Phase 5: Validator & Relayer Operations

### 8.1 Validator (Docker)

```yaml
# docker-compose.validator.yml
services:
  validator:
    image: gcr.io/abacus-labs-dev/hyperlane-agent:agents-v1.7.0
    command:
      - ./validator
      - --db=/data/hyperlane_db
      - --originChainName=ethereum
      - --reorgPeriod=64
      - --validator.type=aws
      - --validator.id=alias/hyperlane-validator-on
      - --checkpointSyncer.type=s3
      - --checkpointSyncer.bucket=hyperlane-validator-on-eth-bsc
      - --checkpointSyncer.region=us-east-1
    environment:
      - CONFIG_FILES=/config/agent-config.json
      - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
      - AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    volumes:
      - validator-data:/data
      - ./config:/config:ro
    restart: unless-stopped
volumes:
  validator-data:
```

### 8.2 Relayer (Docker)

Create the file `docker/docker-compose.relayer.yml`:

```yaml
services:
  relayer:
    image: gcr.io/abacus-labs-dev/hyperlane-agent:agents-v1.7.0
    command:
      - ./relayer
      - --db=/data/hyperlane_db
      - --relayChains=ethereum,bsc
      - --defaultSigner.type=aws
      - --defaultSigner.id=alias/hyperlane-relayer-on
      - --gasPaymentEnforcement=[{"type":"igp"}]
    environment:
      - CONFIG_FILES=/config/agent-config.json
      - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
      - AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    volumes:
      - relayer-data:/data
      - ./config:/config:ro
    ports:
      - "9090:9090"
    restart: unless-stopped
volumes:
  relayer-data:
```

**Start the relayer:**

```bash
# Create config directory and agent config (see section 8.5)
mkdir -p docker/config
# Copy your agent-config.json into docker/config/

# Start
cd docker
docker compose -f docker-compose.relayer.yml up -d

# Check logs
docker compose -f docker-compose.relayer.yml logs -f relayer

# Verify it is processing messages
curl http://localhost:9090/list_operations?destination_domain=56

# Stop
docker compose -f docker-compose.relayer.yml down
```

> **Note on validators**: The validator config (section 8.1) runs for Ethereum origin only. If you configure a custom ISM that requires your own validators for BOTH directions, add a second validator service with `--originChainName=bsc` and `--reorgPeriod=15`.

> **Note on gasPaymentEnforcement**: `"type":"igp"` means the relayer only delivers messages where the user paid sufficient gas via the InterchainGasPaymaster (IGP). Users must include `msg.value` when calling `transferRemote()` — the amount is determined by `quoteGasPayment(destinationDomain)`. Bridge UIs handle this automatically. If you want to subsidize gas during initial testing, temporarily use `[{"type":"none"}]` and switch back to `igp` before go-live.

### 8.3 Validator Announce

After the validator starts, it must announce its checkpoint storage location on-chain so the relayer can find signatures:

```bash
# The validator does this automatically on first startup.
# Verify in logs:
docker logs validator 2>&1 | grep "announced"
# Should show: "Validator has announced signature storage location"

# If not, manually announce:
hyperlane validator announce \
  --chain ethereum \
  --validator $VALIDATOR_ADDRESS \
  --storage-location "s3://hyperlane-validator-on-eth-bsc/us-east-1"
```

### 8.4 Fund Agent Wallets

Both the validator and relayer need gas on their respective chains:

```bash
# Fund relayer on ETH
cast send $RELAYER_ADDRESS --value 0.1ether --rpc-url $ETH_RPC_URL --private-key $HYP_KEY

# Fund relayer on BSC
cast send $RELAYER_ADDRESS --value 0.1ether --rpc-url $BSC_RPC_URL --private-key $HYP_KEY

# Fund validator on ETH (for announce tx)
cast send $VALIDATOR_ADDRESS --value 0.01ether --rpc-url $ETH_RPC_URL --private-key $HYP_KEY
```

### 8.5 Agent Config

Save this as `config/agent-config.json` (create the `config/` directory first):

```json
{
  "chains": {
    "ethereum": {
      "name": "ethereum",
      "chainId": 1,
      "domainId": 1,
      "protocol": "ethereum",
      "rpcUrls": [
        { "http": "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY" }
      ],
      "mailbox": "0xc005dc82818d67AF737725bD4bf75435d065D239"
    },
    "bsc": {
      "name": "bsc",
      "chainId": 56,
      "domainId": 56,
      "protocol": "ethereum",
      "rpcUrls": [
        { "http": "https://bsc-mainnet.nodereal.io/v1/YOUR_KEY" }
      ],
      "mailbox": "0x2971b9Aec44bE4eb673DF1B88cDB57b96eefe8a4"
    }
  }
}
```

---

## 9. Phase 6: Monitoring & Maintenance

### 9.1 Key Metrics

| Metric | Alert Threshold | Action |
|--------|----------------|--------|
| `hyperlane_messages_pending` | > 50 for 10 min | Check relayer |
| `hyperlane_latest_checkpoint` age | > 5 min stale | Check validator |
| Relayer ETH balance | < 0.05 ETH | Refund |
| Relayer BNB balance | < 0.05 BNB | Refund |
| Collateral TVL | Unexpected > 20% drop | Security incident |

### 9.2 Monitoring Commands

```bash
# Check relayer queue
curl http://localhost:9090/list_operations?destination_domain=56

# Prometheus metrics
curl http://localhost:9090/metrics

# Check swap progress
cast call $SWAP_CONTRACT "totalSwapped()(uint256)" --rpc-url $BSC_RPC_URL

# Check collateral locked on ETH
cast call $ON_TOKEN_ETHEREUM \
  "balanceOf(address)(uint256)" \
  $COLLATERAL_CONTRACT \
  --rpc-url $ETH_RPC_URL

# Check synthetic total supply on BSC
cast call $NEW_ON_TOKEN_BSC "totalSupply()(uint256)" --rpc-url $BSC_RPC_URL
```

### 9.3 Prometheus + Grafana

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'hyperlane-relayer'
    static_configs:
      - targets: ['relayer:9090']
  - job_name: 'hyperlane-validator'
    static_configs:
      - targets: ['validator:9090']
```

---

## 10. Phase 7: Frontend & Go-Live

### 10.1 Hyperlane Superbridge (Quickest)

1. Go to https://superbridge.app
2. Add your warp route config
3. Users bridge through the UI

### 10.2 Custom Bridge UI (SDK)

```typescript
import { WarpCore } from '@hyperlane-xyz/sdk';

const warpRouteConfig = {
  tokens: [
    {
      chainName: 'ethereum',
      standard: 'EvmHypCollateral',
      decimals: 18,
      symbol: 'ON',
      name: 'Orochi Network Token',
      addressOrDenom: '0xCollateralAddress',
      collateralAddressOrDenom: '0xONTokenAddress',
      connections: [{ token: 'ethereum|bsc|0xSyntheticAddress' }]
    },
    {
      chainName: 'bsc',
      standard: 'EvmHypSynthetic',
      decimals: 18,
      symbol: 'ON',
      name: 'Orochi Network Token',
      addressOrDenom: '0xSyntheticAddress',
      connections: [{ token: 'ethereum|ethereum|0xCollateralAddress' }]
    }
  ]
};
```

### 10.3 Registry Submission

After deployment, submit your warp route to the [Hyperlane Registry](https://github.com/hyperlane-xyz/hyperlane-registry) so it appears in the Hyperlane Explorer and bridge UIs.

**Step 1: Fork and clone**

```bash
gh repo fork hyperlane-xyz/hyperlane-registry --clone
cd hyperlane-registry
git checkout -b add-on-warp-route
```

**Step 2: Create the warp route config**

Create `deployments/warp_routes/ON/ethereum-bsc-config.yaml` with the actual deployed addresses (replace placeholders with values from your `.env`):

```yaml
tokens:
  - chainName: ethereum
    standard: EvmHypCollateral
    decimals: 18
    symbol: ON
    name: "Orochi Network Token"
    addressOrDenom: "<COLLATERAL_CONTRACT>"          # from .env after warp deploy
    collateralAddressOrDenom: "0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d"
    connections:
      - token: "ethereum|bsc|<NEW_ON_TOKEN_BSC>"     # synthetic address on BSC
  - chainName: bsc
    standard: EvmHypSynthetic
    decimals: 18
    symbol: ON
    name: "Orochi Network Token"
    addressOrDenom: "<NEW_ON_TOKEN_BSC>"              # synthetic address on BSC
    connections:
      - token: "ethereum|ethereum|<COLLATERAL_CONTRACT>"
```

**Step 3: Submit PR**

```bash
git add deployments/warp_routes/ON/
git commit -m "feat: add ON (Orochi Network) ETH<>BSC warp route"
gh pr create --title "Add ON Token Warp Route (Ethereum <> BSC)" --body "Adds Orochi Network Token (ON) warp route. Collateral on Ethereum, synthetic on BSC."
```

The Hyperlane team reviews PRs to the registry. Once merged, your route appears in the [Hyperlane Explorer](https://explorer.hyperlane.xyz) and compatible bridge UIs.

### 10.4 Go-Live Checklist

- [ ] Old BSC ON token audited (Phase 0: decimals, fee-on-transfer, proxy, pause)
- [ ] Testnet rehearsal completed (Phase 0)
- [ ] KMS keys created with aliases, IAM policy attached
- [ ] Gnosis Safe deployed on both chains
- [ ] Warp route deployed and verified (`npm run warp:check`)
- [ ] Deployer received 100M synthetic ON (verified with cast)
- [ ] Trusted relayer ISM removed (`warp apply`)
- [ ] Ownership transferred to Gnosis Safe on both chains
- [ ] Deployer key destroyed
- [ ] Validator running with AWS KMS, announce tx completed
- [ ] Relayer running and funded on both chains
- [ ] Test transfers completed both directions (ETH->BSC and BSC->ETH)
- [ ] ONSwap deployed + seeded with 100M (atomic, verified on BscScan)
- [ ] Test swap completed (small amount)
- [ ] Monitoring and alerting configured
- [ ] Synthetic ON added to BSC token lists and DEX aggregators
- [ ] Old BSC ON marked as deprecated on CoinGecko/CMC
- [ ] CEXes notified of contract migration
- [ ] User-facing migration guide published
- [ ] Migration announced on all channels
- [ ] Registry PR submitted

---

## 11. Phase 8: Post-Migration

### 11.1 Migration Progress Tracking

```bash
# Check swap progress
cast call $SWAP_CONTRACT "totalSwapped()(uint256)" --rpc-url $BSC_RPC_URL

# Calculate percentage
# totalSwapped / 100M * 1e18 = percentage migrated
```

### 11.2 Completion Criteria

The migration has no deadline — ONSwap runs forever by design. This means:
- No user gets locked out, reducing support burden
- Old ON holders can swap at any time
- The owner can effectively end swaps by calling `recover(NEW_TOKEN, owner, remaining)` to drain the pool

Consider the migration "complete" when >95% of old ON has been swapped.

### 11.3 Old Token Cleanup

- Old BSC ON is burned (sent to `0x...dEaD`) on every swap — no cleanup needed for swapped tokens
- The old BSC ON contract's `totalSupply()` does NOT decrease (social burn, not contract burn)
- Contact CoinGecko/CMC to exclude old BSC ON contract from supply calculations
- Add new synthetic ON contract to CoinGecko/CMC
- Remove old ON from DEX aggregator routing (1inch, Paraswap, DexScreener)

### 11.4 Old Liquidity Pools

- Remove any team-owned liquidity from old ON DEX pools
- Notify third-party LPs to withdraw and swap
- Bootstrap new synthetic ON DEX liquidity (ON/BNB, ON/USDT)

### 11.5 Edge Cases

- **Old ON in smart contracts that cannot call swap()**: Owner must withdraw from those contracts first, then swap. Document affected contracts.
- **Old ON on other chains**: Users must bridge back to BSC first, then swap.
- **Accidental direct transfer to ONSwap**: Owner can `recover()` and return to user.

---

## 12. Operational Runbooks

### 12.1 Stuck Messages

```bash
# Check queue
curl http://localhost:9090/list_operations?destination_domain=56

# Restart relayer (auto-retries pending messages)
docker restart relayer
```

### 12.2 Refunding Relayer

```bash
cast balance --rpc-url $ETH_RPC_URL $RELAYER_ADDRESS
cast balance --rpc-url $BSC_RPC_URL $RELAYER_ADDRESS

# Send funds
cast send $RELAYER_ADDRESS --value 0.1ether --rpc-url $ETH_RPC_URL --ledger
```

### 12.3 Emergency: Pause Bridge

Update ISM to reject all messages via Gnosis Safe multisig transaction.

### 12.4 Upgrading Agents

```bash
# 1. Check latest stable tag at https://github.com/hyperlane-xyz/hyperlane-monorepo/releases
# 2. Test on testnet first
# 3. Update docker-compose image tag
# 4. Rolling restart: relayer first, then validator
docker-compose -f docker-compose.relayer.yml up -d
docker-compose -f docker-compose.validator.yml up -d
```

### 12.5 AWS KMS Key Rotation

AWS KMS keys used by the validator and relayer should be rotated periodically. Because Hyperlane agents derive Ethereum addresses from KMS keys, rotation requires updating on-chain references.

**When to rotate:**
- Scheduled: every 6-12 months
- Unscheduled: if a key is suspected compromised

**Procedure:**

```bash
# 1. Create new KMS keys
aws kms create-key --key-spec ECC_SECG_P256K1 --key-usage SIGN_VERIFY \
  --description "Hyperlane Validator v2 - ON Token ETH<>BSC"
aws kms create-alias --alias-name alias/hyperlane-validator-on-v2 --target-key-id <new-key-id>

# 2. Derive the new Ethereum address from the new key
aws kms get-public-key --key-id alias/hyperlane-validator-on-v2 --output text --query PublicKey

# 3. Fund the new address on ETH and BSC
cast send <new-validator-address> --value 0.01ether --rpc-url $ETH_RPC_URL --ledger

# 4. Update docker-compose to use the new alias
# Change: --validator.id=alias/hyperlane-validator-on-v2
# Or:     --defaultSigner.id=alias/hyperlane-relayer-on-v2

# 5. Restart agents with new key
docker compose -f docker-compose.validator.yml up -d
docker compose -f docker-compose.relayer.yml up -d

# 6. For validators: the new validator must announce its storage location
# Check logs for "Validator has announced signature storage location"

# 7. If using a custom ISM with your validator address:
#    Update the ISM config to include the new validator address
#    via warp apply (requires multisig if ownership was transferred)

# 8. Verify the new validator is signing checkpoints
docker compose -f docker-compose.validator.yml logs -f | grep "signed checkpoint"

# 9. Disable the old KMS key (do NOT delete until fully transitioned)
aws kms disable-key --key-id <old-key-id>

# 10. After confirming everything works (wait 24-48h), schedule deletion
aws kms schedule-key-deletion --key-id <old-key-id> --pending-window-in-days 30
```

> **Important**: Never delete a KMS key immediately. Always disable first, monitor for 24-48 hours, then schedule deletion with a 30-day waiting period. If the old validator signed checkpoints that haven't been relayed yet, deleting the key could strand in-flight messages.

---

## 13. Cost Estimation

### One-Time

| Item | Cost |
|------|------|
| Warp route deployment (Ethereum) | ~$50-150 |
| Warp route deployment (BSC) | ~$1-5 |
| ONSwap deployment (BSC) | ~$1-2 |
| Gnosis Safe setup (2 chains) | ~$20-50 |
| **Total** | **~$75-210** |

### Monthly

| Item | Cost | Notes |
|------|------|-------|
| AWS EC2 (2x t3.medium) | ~$70 | Validator + relayer hosts |
| AWS KMS (2 keys) | ~$2 | Validator + relayer signing keys |
| AWS S3 | ~$1 | Validator checkpoint storage |
| RPC providers | $0-200 | Alchemy / QuickNode / Infura |
| Relayer gas | **$0** | Covered by users via IGP |
| **Total** | **~$75-275** | |

> Relayer gas is paid by users through the InterchainGasPaymaster (IGP). Users include `msg.value` when calling `transferRemote()`, which reimburses the relayer for destination chain gas. The relayer operator pays nothing for message delivery.

---

## 14. Security Checklist

### Pre-Deployment

- [ ] Old BSC ON audited: decimals=18, no fee-on-transfer, no proxy/upgrade risk
- [ ] Old BSC ON admin identified and risk assessed (pause, blacklist capabilities)
- [ ] Testnet rehearsal completed end-to-end
- [ ] Old BSC ON supply inventoried (wallets, DEXes, CEXes, DeFi, contracts)

### Smart Contracts

- [ ] Warp route contracts verified on Etherscan + BscScan
- [ ] ONSwap verified on BscScan
- [ ] 100M synthetic ON verified in deployer wallet after warp deploy
- [ ] ONSwap seeded with 100M (atomic deploy+seed)
- [ ] Ownership held by multisig (not EOA) on both chains
- [ ] ISM configured (not trusted relayer)

### Operations

- [ ] Separate keys for deployer, validator, relayer, owner
- [ ] KMS aliases created for validator and relayer
- [ ] IAM policy attached for KMS + S3 access
- [ ] Validator announce transaction completed
- [ ] Agent wallets funded on ETH and BSC
- [ ] Production signing via AWS KMS
- [ ] Deployer key destroyed after ownership transfer
- [ ] Agent Docker images pinned to `agents-v1.7.0`
- [ ] CLI pinned to `@29.1.0`
- [ ] `package-lock.json` committed

### Monitoring

- [ ] Alerting on agent health, wallet balances, message delivery
- [ ] Swap progress tracking (totalSwapped vs 100M)
- [ ] Collateral invariant check (locked ON vs synthetic supply minus 100M pre-mint)
- [ ] Incident response runbook documented

### Communication

- [ ] CEXes notified 2-4 weeks before go-live
- [ ] Migration announcement published (all channels)
- [ ] User-facing swap guide with BscScan walkthrough
- [ ] CoinGecko/CMC contract migration submitted
- [ ] DEX aggregators updated with new token contract

---

## CLI Quick Reference

### npm scripts

| Script | Runs | Purpose |
|--------|------|---------|
| `npm run warp:init` | `hyperlane warp init --out ./configs/warp-route-deploy.yaml` | Generate warp route config |
| `npm run warp:init:advanced` | `hyperlane warp init --advanced --out ...` | Generate config with ISM options |
| `npm run warp:deploy` | `hyperlane warp deploy` | Deploy warp route contracts |
| `npm run warp:check` | `hyperlane warp check` | Verify config matches on-chain |
| `npm run warp:verify` | `hyperlane warp verify` | Verify source on explorers |
| `npm run warp:send:test` | `hyperlane warp send --relay --amount 1` | Test transfer (1 wei) |
| `npm run warp:read` | `hyperlane warp read` | Read on-chain state |
| `npm run warp:read:save` | `hyperlane warp read --out ./configs/warp-route-current.yaml` | Save state to file |
| `npm run warp:apply` | `hyperlane warp apply` | Apply config changes (ISM, ownership) |
| `npm run warp:fees` | `hyperlane warp get-fees` | Show bridge fees |
| `npm run forge:build` | `forge build` | Build Solidity |
| `npm run forge:test` | `forge test -vv` | Run ONSwap tests |

### Common CLI flags (v29.1.0)

| Flag | Purpose |
|------|---------|
| `-k, --key, --private-key` | Private key or seed phrase |
| `-w, --warp-route-id, --id` | Select warp route (skip interactive prompt) |
| `-y, --yes` | Skip confirmation prompts |
| `-r, --registry` | Custom registry path(s) |
| `-o, --out` | Output file path (for `init`, `read`) |
| `--relay` | Self-relay messages (for `send`, `apply`) |
| `--advanced` | Advanced ISM config (for `init`) |
| `--origin, --destination` | Chain selection (for `send`, `check`) |
| `--amount` | Transfer amount in smallest unit (for `send`, `get-fees`) |
| `--round-trip` | Test all chain pairs (for `send`) |
| `--quick` | Skip delivery wait (for `send`) |

---

## References

- [Hyperlane Documentation](https://docs.hyperlane.xyz)
- [Hyperlane Registry](https://github.com/hyperlane-xyz/hyperlane-registry)
- [Hyperlane Explorer](https://explorer.hyperlane.xyz)
- [Warp Routes Overview](https://docs.hyperlane.xyz/docs/protocol/warp-routes/warp-routes-overview)
- [Production Guide](https://docs.hyperlane.xyz/docs/warp-production)
- [Run a Relayer](https://docs.hyperlane.xyz/docs/operate/relayer/run-relayer)
- [Gnosis Safe](https://app.safe.global)
