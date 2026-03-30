# Deployment Checklist

Step-by-step checklist for deploying the ON Token Bridge. Each step maps to a section in [GUIDE.md](./GUIDE.md) with expected results to verify.

---

## Phase 0: Pre-Migration Due Diligence
> GUIDE.md → Section 3

### 3.1 Audit Old BSC ON Token

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Check decimals | `cast call $OLD_ON_TOKEN_BSC "decimals()(uint8)" --rpc-url $BSC_RPC_URL` | `18` |
| 2 | Check total supply | `cast call $OLD_ON_TOKEN_BSC "totalSupply()(uint256)" --rpc-url $BSC_RPC_URL` | `100000000000000000000000000` (100M * 1e18) |
| 3 | Fee-on-transfer test | Transfer 100 ON to test wallet, check received balance | Received == 100 ON exactly. If less → **STOP, do not deploy** |
| 4 | Check if proxy | `cast storage $OLD_ON_TOKEN_BSC 0x3608...bbc --rpc-url $BSC_RPC_URL` | `0x0` (not a proxy). Non-zero = proxy, investigate further |
| 5 | Check if pausable | `cast call $OLD_ON_TOKEN_BSC "paused()(bool)" --rpc-url $BSC_RPC_URL` | `false` or call reverts (no pause function = good) |

### 3.2 Inventory Old BSC ON Supply

- [ ] Top holders documented (BscScan)
- [ ] DEX liquidity pools identified
- [ ] CEX listings identified
- [ ] DeFi positions identified (staking, lending, vesting)
- [ ] Smart contracts holding old ON that cannot call `swap()` documented

### 3.3 Communication Plan

- [ ] Migration announcement drafted
- [ ] CEXes notified (2-4 weeks before go-live)
- [ ] New token contract submitted to CoinGecko/CMC
- [ ] User-facing swap guide prepared

### 3.4 Testnet Rehearsal

- [ ] Mock ON deployed on Sepolia
- [ ] `warp init` + `warp deploy` completed on testnets
- [ ] `initialSupply` minting verified on testnet
- [ ] ONSwap deployed + seeded on BSC testnet
- [ ] Swap tested on testnet
- [ ] Bridge tested both directions on testnet
- [ ] Validator + relayer started on testnet

---

## Phase 1: Infrastructure Setup
> GUIDE.md → Section 4

### 4.1 AWS KMS Keys

| # | Step | Expected Result |
|---|------|-----------------|
| 1 | Create validator KMS key | Key ID returned |
| 2 | Create validator alias `alias/hyperlane-validator-on` | Alias created |
| 3 | Create relayer KMS key | Key ID returned |
| 4 | Create relayer alias `alias/hyperlane-relayer-on` | Alias created |
| 5 | Attach IAM policy (kms:Sign, s3:PutObject, etc.) | Policy attached |
| 6 | Derive ETH addresses from KMS public keys | Addresses recorded in `.env` as `VALIDATOR_ADDRESS`, `RELAYER_ADDRESS` |

### 4.2 S3 Bucket

| # | Step | Expected Result |
|---|------|-----------------|
| 1 | Create S3 bucket | `s3://hyperlane-validator-on-eth-bsc` created |
| 2 | Set public read policy | Policy applied |

### 4.3 Gnosis Safe

- [ ] Safe deployed on Ethereum (2-of-3 or 3-of-5)
- [ ] Safe deployed on BSC with same signers
- [ ] Both addresses recorded — must match `0xDA5E5Be8f9C5fCdd30f2ee08D6b3F794511C2B48`

### 4.4 Environment Setup

- [ ] `.env` created from `.env.example`
- [ ] `HYP_KEY` set (deployer private key)
- [ ] `ETH_RPC_URL` and `BSC_RPC_URL` set
- [ ] `ETHERSCAN_API_KEY` and `BSCSCAN_API_KEY` set
- [ ] `ON_TOKEN_ETHEREUM`, `OLD_ON_TOKEN_BSC` verified
- [ ] `SWAP_OWNER` set to multisig address
- [ ] `DEPLOYER_ADDRESS` derived from `HYP_KEY` and recorded

---

## Phase 2: Warp Route Deployment
> GUIDE.md → Section 5

### 5.1 Configure

| # | Step | Expected Result |
|---|------|-----------------|
| 1 | Run `npm run warp:init` | Config written to `configs/warp-route-deploy.yaml` |
| 2 | Verify `type: collateral` for Ethereum | Present in generated config |
| 3 | Verify `type: synthetic` for BSC | Present in generated config |
| 4 | Manually add `initialSupply: "100000000000000000000000000"` to BSC section | Field present, **quoted string** |
| 5 | Verify token address matches `0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d` | Correct |

### 5.2 Deploy

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Set deployer key | `export HYP_KEY=0x...` | Key in env |
| 2 | Deploy warp route | `npm run warp:deploy` | `✅ Collateral deployed on ethereum: 0x...` and `✅ Synthetic deployed on bsc: 0x...` |
| 3 | Record warp route ID | Shown in CLI output | e.g., `ON/ethereum-bsc` |
| 4 | Record collateral address | From deploy output | Set `COLLATERAL_CONTRACT` in `.env` |
| 5 | Record synthetic address | From deploy output | Set `NEW_ON_TOKEN_BSC` in `.env` |
| 6 | **Verify 100M minted** | `cast call $NEW_ON_TOKEN_BSC "balanceOf(address)(uint256)" $DEPLOYER_ADDRESS --rpc-url $BSC_RPC_URL` | **`100000000000000000000000000`** (100M * 1e18). If `0` → `initialSupply` was stripped. **STOP.** |

### 5.3 Verify

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Check config matches on-chain | `npm run warp:check` | No errors |
| 2 | Verify on block explorers | `npm run warp:verify` | Contracts verified |
| 3 | Check fees | `npm run warp:fees` | Fee amounts displayed |

### 5.4 Smoke Test

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Send 1 wei ON: ETH → BSC | `npm run warp:send:test` | Message dispatched and delivered |
| 2 | Verify on Hyperlane Explorer | https://explorer.hyperlane.xyz | Message status: delivered |

### 5.5 Save State

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Save current on-chain state | `npm run warp:read:save` | `configs/warp-route-current.yaml` created |

---

## Phase 3: Old BSC ON Migration (Swap Contract)
> GUIDE.md → Section 6

### 6.1 Deploy + Seed ONSwap

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Run deploy script | `forge script script/DeploySwap.s.sol --rpc-url $BSC_RPC_URL --broadcast --verify --private-key $HYP_KEY --etherscan-api-key $BSCSCAN_API_KEY -vvvv` | `ONSwap deployed at: 0x...` and `Seeded: 100000000000000000000000000` |
| 2 | Record swap address | From output | Set `SWAP_CONTRACT` in `.env` |

> **Must use `--private-key $HYP_KEY`** (same key as warp deploy). Using `--ledger` will fail unless tokens are transferred to ledger first.

### 6.2 Verify

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Check swap balance | `cast call $NEW_ON_TOKEN_BSC "balanceOf(address)(uint256)" $SWAP_CONTRACT --rpc-url $BSC_RPC_URL` | `100000000000000000000000000` |
| 2 | Check deployer balance is 0 | `cast call $NEW_ON_TOKEN_BSC "balanceOf(address)(uint256)" $DEPLOYER_ADDRESS --rpc-url $BSC_RPC_URL` | `0` |
| 3 | Check swap contract owner | `cast call $SWAP_CONTRACT "owner()(address)" --rpc-url $BSC_RPC_URL` | Multisig address `0xDA5E5Be8f9C5fCdd30f2ee08D6b3F794511C2B48` |
| 4 | Verify on BscScan | Open contract on BscScan | Source verified, read/write functions visible |

### 6.3 Test Swap

| # | Step | Expected Result |
|---|------|-----------------|
| 1 | Approve ONSwap from a test wallet | TX succeeds |
| 2 | Call `swap(amount)` with small amount | TX succeeds |
| 3 | Verify new ON received by test wallet | Balance increased |
| 4 | Verify old ON sent to `0x...dEaD` | `oldToken.balanceOf(0x...dEaD)` increased |
| 5 | Verify `totalSwapped` incremented | `cast call $SWAP_CONTRACT "totalSwapped()(uint256)"` matches |

---

## Phase 4: Security Hardening
> GUIDE.md → Section 7

### 7.1 Remove Trusted Relayer ISM

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Read current state | `npm run warp:read:save` | `configs/warp-route-current.yaml` updated |
| 2 | Edit ISM config | Add `interchainSecurityModule` block | ISM block present in YAML |
| 3 | Apply changes | `npm run warp:apply` | TX succeeds |
| 4 | Verify ISM updated | `npm run warp:read` | ISM is NOT `trustedRelayerIsm` |

### 7.3 Transfer Ownership to Multisig

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Edit owner in config to multisig | Update YAML | Owner = `0xDA5E5Be8f9C5fCdd30f2ee08D6b3F794511C2B48` |
| 2 | Apply | `npm run warp:apply` | TX succeeds |
| 3 | Verify ETH owner | `npm run warp:read` | Owner = multisig on both chains |

### 7.4 Destroy Deployer Key

| # | Step | Expected Result |
|---|------|-----------------|
| 1 | `unset HYP_KEY` | Env cleared |
| 2 | Clear shell history | History wiped |
| 3 | Verify deployer cannot call owner functions | Confirmed |

---

## Phase 5: Validator & Relayer Operations
> GUIDE.md → Section 8

### 8.1-8.2 Start Agents

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Create config directory | `mkdir -p docker/config` | Directory exists |
| 2 | Create `agent-config.json` | Copy from GUIDE.md Section 8.5, fill RPC URLs | File at `docker/config/agent-config.json` |
| 3 | Start validator | `cd docker && docker compose -f docker-compose.validator.yml up -d` | Container running |
| 4 | Start relayer | `docker compose -f docker-compose.relayer.yml up -d` | Container running |
| 5 | Check validator logs | `docker compose -f docker-compose.validator.yml logs -f` | "Validator has announced signature storage location" |
| 6 | Check relayer health | `curl http://localhost:9090/list_operations?destination_domain=56` | JSON response, no errors |

### 8.3 Validator Announce

| # | Step | Expected Result |
|---|------|-----------------|
| 1 | Check validator logs for announce | "announced" message visible |
| 2 | If not announced, manually announce | `hyperlane validator announce` succeeds |

### 8.4 Fund Agent Wallets

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Fund relayer on ETH | `cast send $RELAYER_ADDRESS --value 0.1ether --rpc-url $ETH_RPC_URL` | Balance ≥ 0.1 ETH |
| 2 | Fund relayer on BSC | `cast send $RELAYER_ADDRESS --value 0.1ether --rpc-url $BSC_RPC_URL` | Balance ≥ 0.1 BNB |
| 3 | Fund validator on ETH | `cast send $VALIDATOR_ADDRESS --value 0.01ether --rpc-url $ETH_RPC_URL` | Balance ≥ 0.01 ETH |

---

## Phase 6: Monitoring
> GUIDE.md → Section 9

| # | Step | Expected Result |
|---|------|-----------------|
| 1 | Relayer queue check | `curl http://localhost:9090/list_operations?destination_domain=56` returns data |
| 2 | Prometheus scraping | Metrics available at `http://localhost:9090/metrics` |
| 3 | Swap progress | `cast call $SWAP_CONTRACT "totalSwapped()(uint256)" --rpc-url $BSC_RPC_URL` returns current total |
| 4 | Collateral locked | `cast call $ON_TOKEN_ETHEREUM "balanceOf(address)(uint256)" $COLLATERAL_CONTRACT --rpc-url $ETH_RPC_URL` matches bridged amount |
| 5 | Synthetic supply | `cast call $NEW_ON_TOKEN_BSC "totalSupply()(uint256)" --rpc-url $BSC_RPC_URL` ≥ 100M * 1e18 |

---

## Phase 7: Frontend & Go-Live
> GUIDE.md → Section 10

### 10.3 Registry Submission

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Fork Hyperlane registry | `gh repo fork hyperlane-xyz/hyperlane-registry --clone` | Repo cloned |
| 2 | Create branch | `git checkout -b add-on-warp-route` | Branch created |
| 3 | Create config file | `deployments/warp_routes/ON/ethereum-bsc-config.yaml` with deployed addresses | File created |
| 4 | Commit and push | `git add && git commit && git push` | Pushed |
| 5 | Create PR | `gh pr create --title "Add ON Token Warp Route"` | PR URL returned |

### 10.4 Go-Live Checklist

- [ ] Old BSC ON token audited (Phase 0)
- [ ] Testnet rehearsal completed (Phase 0)
- [ ] KMS keys + aliases created (Phase 1)
- [ ] Gnosis Safe on both chains (Phase 1)
- [ ] Warp route deployed + verified (Phase 2)
- [ ] 100M synthetic ON verified in deployer wallet (Phase 2)
- [ ] Warp route ID recorded (Phase 2)
- [ ] ONSwap deployed + seeded atomically (Phase 3)
- [ ] Test swap completed (Phase 3)
- [ ] ISM hardened (Phase 4)
- [ ] Ownership transferred to multisig (Phase 4)
- [ ] Deployer key destroyed (Phase 4)
- [ ] Validator + relayer running (Phase 5)
- [ ] Validator announced (Phase 5)
- [ ] Agent wallets funded (Phase 5)
- [ ] Monitoring operational (Phase 6)
- [ ] Registry PR submitted (Phase 7)
- [ ] CoinGecko/CMC updated with new BSC ON contract
- [ ] Migration announced on all channels

---

## Phase 8: Post-Migration
> GUIDE.md → Section 11

| # | Step | Command | Expected Result |
|---|------|---------|-----------------|
| 1 | Check swap progress | `cast call $SWAP_CONTRACT "totalSwapped()(uint256)" --rpc-url $BSC_RPC_URL` | Approaching 100M * 1e18 |
| 2 | Check remaining new tokens | `cast call $NEW_ON_TOKEN_BSC "balanceOf(address)(uint256)" $SWAP_CONTRACT --rpc-url $BSC_RPC_URL` | Approaching 0 |
| 3 | Migration >95% | `totalSwapped / 100M > 0.95` | Migration considered complete |
| 4 | Recover unswapped tokens (owner) | `cast send $SWAP_CONTRACT "recover(address,address,uint256)" $NEW_ON_TOKEN_BSC $MULTISIG <remaining> --rpc-url $BSC_RPC_URL` | Remaining tokens returned to multisig |
| 5 | Old BSC ON at dead address | `cast call $OLD_ON_TOKEN_BSC "balanceOf(address)(uint256)" 0x000000000000000000000000000000000000dEaD --rpc-url $BSC_RPC_URL` | Equals `totalSwapped` |
| 6 | Update token listings | Contact CoinGecko/CMC | Old contract deprecated, new contract listed |
| 7 | Remove old ON from DEX routing | Contact aggregators | Old ON delisted |
| 8 | Open bridge for ETH↔BSC | Announce bridge is live | Users can bridge freely |

---

## Emergency Reference
> GUIDE.md → Section 12

| Scenario | Action | Command |
|----------|--------|---------|
| Stuck messages | Check relayer queue | `curl http://localhost:9090/list_operations?destination_domain=56` |
| Stuck messages | Restart relayer | `docker restart relayer` |
| Low relayer balance | Refund ETH | `cast send $RELAYER_ADDRESS --value 0.1ether --rpc-url $ETH_RPC_URL` |
| Low relayer balance | Refund BNB | `cast send $RELAYER_ADDRESS --value 0.1ether --rpc-url $BSC_RPC_URL` |
| Pause swap | Owner recovers NEW_TOKEN | `cast send $SWAP_CONTRACT "recover(address,address,uint256)" $NEW_ON_TOKEN_BSC $MULTISIG <amount>` |
| Pause bridge | Update ISM to reject messages | Via Gnosis Safe multisig transaction |
