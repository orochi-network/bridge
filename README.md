# ON Token Bridge: Ethereum <-> BSC

Hyperlane warp route bridge for [Orochi Network Token (ON)](https://orochi.network/) between Ethereum and BNB Smart Chain, with a one-way swap contract for migrating old BSC ON to the new Hyperlane synthetic.

## Prerequisites

- [Node.js](https://nodejs.org/) v18+
- [Foundry](https://book.getfoundry.sh/)

## Install

```bash
# Install Foundry (if not installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone and install
git clone <repo-url> && cd bridge
forge install          # Solidity dependencies (OpenZeppelin, forge-std)
npm install            # Hyperlane CLI v29.1.0
```

## Build & Test

```bash
forge build
forge test -vv
```

## Project Structure

```
configs/warp-route-deploy.yaml   # Hyperlane warp route config
src/ONSwap.sol                   # 1:1 swap contract (old BSC ON → new synthetic ON)
test/ONSwap.t.sol                # 25 tests
script/DeploySwap.s.sol          # Atomic deploy + seed script
```

## Documentation

- [GUIDE.md](./GUIDE.md) — Full production deployment guide (Phases 0-8)
- [CHECKLIST.md](./CHECKLIST.md) — Step-by-step deployment checklist with expected results
- [CLAUDE.md](./CLAUDE.md) — AI assistant context
