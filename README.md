# Orochi Network ON Bridge (Ethereum ⇄ BSC, Chainlink CCIP)

A Chainlink CCIP Cross-Chain Token (CCT) bridge for the Orochi Network **ON** token between Ethereum Mainnet and BNB Smart Chain.

## Tokens

| Chain | Token | Address | Supply | Mintable? |
|---|---|---|---|---|
| Ethereum Mainnet | ON (existing) | `0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d` | 600,000,000 | No |
| Ethereum Mainnet | wON (this repo) | deployed | dynamic | Yes (pool only) |
| BSC Mainnet | ON (existing) | `0x0e4F6209eD984b21EDEA43acE6e09559eD051D48` | 100,000,000 | Lock/Release |

## Architecture

- **BSC side**: stock `LockReleaseTokenPool` against the existing ON token. Outbound locks; inbound releases.
- **Ethereum side**: stock `BurnMintTokenPool` against the new wON token. Outbound burns; inbound mints.
- **wON** is also a 1:1 wrapper holding a reserve of native ETH-side ON, with `deposit` / `withdraw` for users who want native ON.

## Quick start

```bash
forge install
forge build
forge test -vvv --no-match-path "test/fork/**"
```

For fork tests, set `ETH_RPC` and `BSC_RPC` in `.env`, then:

```bash
source .env
forge test -vvv --match-path "test/fork/**"
```

## Deployment

See [`/home/parallels/.claude/plans/orochi-network-token-on-gleaming-cat.md`](../../../.claude/plans/orochi-network-token-on-gleaming-cat.md) for the full playbook, or [`CLAUDE.md`](CLAUDE.md) for project conventions.

Sequence (testnet first):

```bash
forge script script/01_DeployWrappedON.s.sol      --rpc-url sepolia     --broadcast --verify --private-key $DEPLOYER_PK
forge script script/02_DeployPools.s.sol          --rpc-url sepolia     --broadcast --verify --private-key $DEPLOYER_PK
forge script script/02_DeployPools.s.sol          --rpc-url bsc_testnet --broadcast --verify --private-key $DEPLOYER_PK
forge script script/03_GrantRoles.s.sol           --rpc-url sepolia     --broadcast --private-key $DEPLOYER_PK
forge script script/04_RegisterAdminAndPool.s.sol --rpc-url sepolia     --broadcast --private-key $DEPLOYER_PK
forge script script/04_RegisterAdminAndPool.s.sol --rpc-url bsc_testnet --broadcast --private-key $DEPLOYER_PK
forge script script/05_ApplyChainUpdates.s.sol    --rpc-url sepolia     --broadcast --private-key $DEPLOYER_PK
forge script script/05_ApplyChainUpdates.s.sol    --rpc-url bsc_testnet --broadcast --private-key $DEPLOYER_PK
```

## Layout

```
src/WrappedON.sol                custom wON token (ERC20 + AccessControl + IBurnMintERC20)
script/Helper.sol                per-chain CCIP config (router, RMN, registry, selectors)
script/01..05*.s.sol             deploy + registry + chain-updates scripts
test/WrappedON.t.sol             unit tests
test/fork/                       fork tests + CCIP roundtrip via CCIPLocalSimulatorFork
deployments/<chainId>.json       written by scripts via vm.writeJson
```
