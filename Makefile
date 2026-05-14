.PHONY: help install patch-pragmas build test test-unit test-e2e test-fork fmt fmt-check coverage clean \
        deploy-eth deploy-bsc verify-eth verify-bsc handoff handoff-all renounce renounce-all update-limits

# ─── Defaults ──────────────────────────────────────────────────────────────────
SHELL := /bin/bash
DEPLOY_FLAGS := --broadcast --verify --private-key $(DEPLOYER_PK)
DRYRUN_FLAGS := --sender $(DEPLOYER_ADDR)

help:
	@echo "Common targets:"
	@echo "  make install         install forge deps"
	@echo "  make build           forge build"
	@echo "  make test            full test suite (unit + E2E, no fork)"
	@echo "  make test-unit       unit tests only"
	@echo "  make test-e2e        integration + E2E only"
	@echo "  make test-fork       fork tests (requires ETH_RPC= BSC_RPC=)"
	@echo "  make fmt-check       forge fmt --check"
	@echo "  make coverage        forge coverage --report summary"
	@echo "  make clean           remove cache/, out/, broadcast/"
	@echo ""
	@echo "Deployment (load .env first; values in capitals come from env):"
	@echo "  ETH_RPC, BSC_RPC, SEPOLIA_RPC, BSC_TESTNET_RPC, DEPLOYER_PK, MULTISIG"
	@echo ""
	@echo "  make deploy-eth      RPC=sepolia                  # 01-03 + 04 + 05"
	@echo "  make deploy-bsc      RPC=bsc_testnet              # 02 + 04 + 05"
	@echo "  make verify-eth      RPC=sepolia                  # script 08 view-only"
	@echo "  make verify-bsc      RPC=bsc_testnet"
	@echo "  make handoff         RPC=sepolia    MULTISIG=0x.. # script 06"
	@echo "  make renounce        RPC=sepolia                  # script 06 (renounce step)"
	@echo "  make update-limits   RPC=...  OUTBOUND_CAPACITY=.. # script 07"

# ─── Dev loop ──────────────────────────────────────────────────────────────────
# Pin to the same submodule revisions recorded in .gitmodules. Run once after
# `git clone` (or after CI's submodules: recursive checkout). Then run
# `patch-pragmas` so the libraries compile under solc 0.8.34.
install:
	git submodule update --init --recursive
	$(MAKE) patch-pragmas

# Rewrite pinned-version pragmas (`pragma solidity 0.8.24;`) in the vendored
# libraries to caret form so they compile with our pinned solc 0.8.34. This is
# documented in CLAUDE.md and is a working-tree-only patch — it is NOT
# committed upstream and must be re-applied after every submodule init/update.
patch-pragmas:
	find lib -name "*.sol" -print0 | xargs -0 sed -i 's/^pragma solidity 0\.8\.24;/pragma solidity ^0.8.24;/'

build:
	forge build --sizes

test:
	forge test -vvv

test-unit:
	forge test --match-path 'test/WrappedON.t.sol' -vvv

test-e2e:
	forge test --match-path 'test/{PoolRoundtrip,DeploymentE2E}.t.sol' -vvv

test-fork:
	@test -n "$(ETH_RPC)" || (echo "ETH_RPC env var required"; exit 1)
	@test -n "$(BSC_RPC)" || (echo "BSC_RPC env var required"; exit 1)
	ETH_RPC=$(ETH_RPC) BSC_RPC=$(BSC_RPC) forge test --match-path 'test/fork/**' -vvv

fmt:
	forge fmt

fmt-check:
	forge fmt --check

coverage:
	forge coverage --report summary

clean:
	forge clean
	rm -rf broadcast/

# ─── Deployment ─────────────────────────────────────────────────────────────────
# Ethereum sequence (Sepolia or mainnet).
deploy-eth:
	@test -n "$(RPC)"         || (echo "RPC=sepolia|eth required"; exit 1)
	@test -n "$(DEPLOYER_PK)" || (echo "DEPLOYER_PK env var required"; exit 1)
	forge script script/01_DeployWrappedON.s.sol      --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/02_DeployPools.s.sol          --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/03_GrantRoles.s.sol           --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/04_RegisterAdminAndPool.s.sol --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/05_ApplyChainUpdates.s.sol    --rpc-url $(RPC) $(DEPLOY_FLAGS)

# BSC sequence (testnet or mainnet). Skips 01 and 03 (wON only exists on ETH).
deploy-bsc:
	@test -n "$(RPC)"         || (echo "RPC=bsc_testnet|bsc required"; exit 1)
	@test -n "$(DEPLOYER_PK)" || (echo "DEPLOYER_PK env var required"; exit 1)
	forge script script/02_DeployPools.s.sol          --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/04_RegisterAdminAndPool.s.sol --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/05_ApplyChainUpdates.s.sol    --rpc-url $(RPC) $(DEPLOY_FLAGS)

verify-eth:
	@test -n "$(RPC)" || (echo "RPC=sepolia|eth required"; exit 1)
	forge script script/08_PostDeployVerify.s.sol --rpc-url $(RPC)

verify-bsc:
	@test -n "$(RPC)" || (echo "RPC=bsc_testnet|bsc required"; exit 1)
	forge script script/08_PostDeployVerify.s.sol --rpc-url $(RPC)

handoff:
	@test -n "$(MULTISIG)"    || (echo "MULTISIG env var required"; exit 1)
	@test -n "$(RPC)"         || (echo "RPC required"; exit 1)
	@test -n "$(DEPLOYER_PK)" || (echo "DEPLOYER_PK env var required"; exit 1)
	MULTISIG=$(MULTISIG) forge script script/06_TransferOwnership.s.sol:TransferOwnership \
	    --rpc-url $(RPC) $(DEPLOY_FLAGS) --sig "run()"

# Atomic two-chain handoff. Both ETH_RPC and BSC_RPC must point at the same operational
# environment (testnet pair OR mainnet pair) so the same MULTISIG ends up wired on both sides.
handoff-all:
	@test -n "$(MULTISIG)"    || (echo "MULTISIG env var required"; exit 1)
	@test -n "$(ETH_RPC)"     || (echo "ETH_RPC env var required"; exit 1)
	@test -n "$(BSC_RPC)"     || (echo "BSC_RPC env var required"; exit 1)
	@test -n "$(DEPLOYER_PK)" || (echo "DEPLOYER_PK env var required"; exit 1)
	$(MAKE) handoff MULTISIG=$(MULTISIG) RPC=$(ETH_RPC)
	$(MAKE) handoff MULTISIG=$(MULTISIG) RPC=$(BSC_RPC)

# Final renounce — only after multisig has accepted everything on both chains.
renounce:
	@test -n "$(MULTISIG)"    || (echo "MULTISIG env var required"; exit 1)
	@test -n "$(RPC)"         || (echo "RPC required"; exit 1)
	@test -n "$(DEPLOYER_PK)" || (echo "DEPLOYER_PK env var required"; exit 1)
	MULTISIG=$(MULTISIG) forge script script/06_TransferOwnership.s.sol:RenounceDeployerAdmin \
	    --rpc-url $(RPC) $(DEPLOY_FLAGS) --sig "run()"

# Renounce on ETH only — wON does not exist on BSC, so this is single-chain by design.
# We keep a `renounce-all` alias for symmetry with `handoff-all`.
renounce-all: renounce

update-limits:
	@test -n "$(RPC)"               || (echo "RPC required"; exit 1)
	@test -n "$(DEPLOYER_PK)"       || (echo "DEPLOYER_PK env var required"; exit 1)
	@test -n "$(OUTBOUND_CAPACITY)" || (echo "OUTBOUND_CAPACITY required"; exit 1)
	@test -n "$(OUTBOUND_RATE)"     || (echo "OUTBOUND_RATE required"; exit 1)
	@test -n "$(INBOUND_CAPACITY)"  || (echo "INBOUND_CAPACITY required"; exit 1)
	@test -n "$(INBOUND_RATE)"      || (echo "INBOUND_RATE required"; exit 1)
	forge script script/07_UpdateRateLimits.s.sol --rpc-url $(RPC) $(DEPLOY_FLAGS)
