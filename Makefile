.PHONY: help install patch-pragmas build test test-unit test-e2e test-fork fmt fmt-check coverage clean \
        precheck-helper deploy-eth deploy-bsc verify-eth verify-bsc handoff handoff-all renounce update-limits

# ─── Defaults ──────────────────────────────────────────────────────────────────
SHELL := /bin/bash
DEPLOY_FLAGS := --broadcast --verify --private-key $(DEPLOYER_PK)

help:
	@echo "Common targets:"
	@echo "  make install         install forge deps"
	@echo "  make patch-pragmas   re-apply the vendored pragma patch (run after submodule update)"
	@echo "  make build           forge build"
	@echo "  make test            full test suite (unit + integration + invariants, no fork)"
	@echo "  make test-unit       WrappedON.t.sol only"
	@echo "  make test-e2e        everything except WrappedON.t.sol and forks (OPS-24)"
	@echo "  make test-fork       fork tests (requires ETH_RPC= BSC_RPC=)"
	@echo "  make fmt             forge fmt"
	@echo "  make fmt-check       forge fmt --check"
	@echo "  make coverage        forge coverage --report summary"
	@echo "  make clean           remove cache/, out/, broadcast/"
	@echo ""
	@echo "Deployment (load .env first; values in capitals come from env):"
	@echo "  ETH_RPC, BSC_RPC, SEPOLIA_RPC, BSC_TESTNET_RPC, DEPLOYER_PK, DEPLOYER, MULTISIG"
	@echo ""
	@echo "  make precheck-helper RPC=...                         # validate Helper.sol placeholders"
	@echo "  make deploy-eth      RPC=sepolia                     # 01-03 + 04 + 05"
	@echo "  make deploy-bsc      RPC=bsc_testnet                 # 02 + 04 + 05"
	@echo "  make verify-eth      RPC=sepolia                     # script 08 view-only"
	@echo "  make verify-bsc      RPC=bsc_testnet"
	@echo "  make handoff         RPC=sepolia     MULTISIG=0x..   # script 06 (one chain)"
	@echo "  make handoff-all     ETH_RPC=.. BSC_RPC=.. MULTISIG=0x..   # two-chain handoff"
	@echo "  make renounce        RPC=sepolia                     # script 06 (renounce step)"
	@echo "  make update-limits   RPC=...  OUTBOUND_CAPACITY=..   # script 07"

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
#
# `sed -i.bak` works on both GNU sed (Linux/CI) and BSD sed (macOS) — GNU
# accepts both `-i` and `-i.bak`; BSD requires an explicit suffix argument.
# The `.bak` files are deleted immediately after.
patch-pragmas:
	find lib -name "*.sol" -print0 | xargs -0 sed -i.bak 's/^pragma solidity 0\.8\.24;/pragma solidity ^0.8.24;/'
	find lib -name "*.sol.bak" -delete

build:
	forge build --sizes

test:
	forge test -vvv

test-unit:
	forge test --match-path 'test/WrappedON.t.sol' -vvv

test-e2e:
	forge test --no-match-path 'test/{WrappedON.t.sol,fork/**}' -vvv

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
# Asserts that script/Helper.sol has non-placeholder addresses for the target chain
# (mainnet onToken required; testnet allows a zero onToken since a mock is deployed).
# Wired as a prerequisite to deploy-eth / deploy-bsc so an operator cannot broadcast
# against placeholder Helper config. See script/PrecheckHelper.s.sol.
precheck-helper:
	@test -n "$(RPC)" || (echo "RPC required"; exit 1)
	forge script script/PrecheckHelper.s.sol --rpc-url $(RPC)

# Ethereum sequence (Sepolia or mainnet).
deploy-eth: precheck-helper
	@test -n "$(RPC)"         || (echo "RPC=sepolia|eth required"; exit 1)
	@test -n "$(DEPLOYER_PK)" || (echo "DEPLOYER_PK env var required"; exit 1)
	forge script script/01_DeployWrappedON.s.sol      --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/02_DeployPools.s.sol          --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/03_GrantRoles.s.sol           --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/04_RegisterAdminAndPool.s.sol --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/05_ApplyChainUpdates.s.sol    --rpc-url $(RPC) $(DEPLOY_FLAGS)

# BSC sequence (testnet or mainnet). Skips 01 and 03 (wON only exists on ETH).
deploy-bsc: precheck-helper
	@test -n "$(RPC)"         || (echo "RPC=bsc_testnet|bsc required"; exit 1)
	@test -n "$(DEPLOYER_PK)" || (echo "DEPLOYER_PK env var required"; exit 1)
	forge script script/02_DeployPools.s.sol          --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/04_RegisterAdminAndPool.s.sol --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/05_ApplyChainUpdates.s.sol    --rpc-url $(RPC) $(DEPLOY_FLAGS)

# SECURITY: DEP-8 — the post-handoff renounce check needs the deployer EOA's address. In
# view-only mode `forge script` resolves `msg.sender` to Foundry's default sender, so
# reading `msg.sender` inside the script wouldn't validate anything. The script reads
# `DEPLOYER` from env when `MULTISIG` is set; if unset the renounce assertion is skipped
# (the rest of the verification still runs). Pre-handoff verifications need neither
# `MULTISIG` nor `DEPLOYER`.
verify-eth:
	@test -n "$(RPC)" || (echo "RPC=sepolia|eth required"; exit 1)
	forge script script/08_PostDeployVerify.s.sol --rpc-url $(RPC)

verify-bsc:
	@test -n "$(RPC)" || (echo "RPC=bsc_testnet|bsc required"; exit 1)
	forge script script/08_PostDeployVerify.s.sol --rpc-url $(RPC)

# SECURITY: DEP-2 — gate handoff and renounce on precheck-helper to surface unfilled
# Helper placeholders BEFORE the deployer-EOA broadcast moves authority around.
handoff: precheck-helper
	@test -n "$(MULTISIG)"    || (echo "MULTISIG env var required"; exit 1)
	@test -n "$(RPC)"         || (echo "RPC required"; exit 1)
	@test -n "$(DEPLOYER_PK)" || (echo "DEPLOYER_PK env var required"; exit 1)
	MULTISIG=$(MULTISIG) forge script script/06_TransferOwnership.s.sol:TransferOwnership \
	    --rpc-url $(RPC) $(DEPLOY_FLAGS) --sig "run()"

# Two-chain handoff. Sequential, NOT atomic — if the BSC leg fails after the ETH leg
# succeeds, the bridge is half-handed-off until the operator re-runs the BSC leg. The
# handoff calls are idempotent so re-running is safe. Both ETH_RPC and BSC_RPC must point
# at the same operational environment (testnet pair OR mainnet pair) so the same MULTISIG
# ends up wired on both sides.
handoff-all:
	@test -n "$(MULTISIG)"    || (echo "MULTISIG env var required"; exit 1)
	@test -n "$(ETH_RPC)"     || (echo "ETH_RPC env var required"; exit 1)
	@test -n "$(BSC_RPC)"     || (echo "BSC_RPC env var required"; exit 1)
	@test -n "$(DEPLOYER_PK)" || (echo "DEPLOYER_PK env var required"; exit 1)
	$(MAKE) handoff MULTISIG=$(MULTISIG) RPC=$(ETH_RPC)
	$(MAKE) handoff MULTISIG=$(MULTISIG) RPC=$(BSC_RPC)

# Final renounce — only after multisig has accepted everything on both chains.
renounce: precheck-helper
	@test -n "$(MULTISIG)"    || (echo "MULTISIG env var required"; exit 1)
	@test -n "$(RPC)"         || (echo "RPC required"; exit 1)
	@test -n "$(DEPLOYER_PK)" || (echo "DEPLOYER_PK env var required"; exit 1)
	MULTISIG=$(MULTISIG) forge script script/06_TransferOwnership.s.sol:RenounceDeployerAdmin \
	    --rpc-url $(RPC) $(DEPLOY_FLAGS) --sig "run()"

# SECURITY: OPS-2 — post-handoff, the deployer EOA is neither pool owner nor rate-limit
# admin, so `--private-key $(DEPLOYER_PK)` would broadcast a tx that reverts on `onlyOwner`.
# Operators must supply a caller authorised at the time of the call:
#   - pre-handoff   : CALLER_FLAGS unset → falls back to DEPLOYER_PK (current behaviour).
#   - post-handoff  : CALLER_FLAGS='--account multisig-signer' (or an encrypted keystore
#                     for the delegated `rateLimitAdmin`). The multisig itself queues this
#                     call via the Safe UI; this Makefile target is for the delegated
#                     hot-key path described in RUNBOOK §4.1.1.
update-limits:
	@test -n "$(RPC)"               || (echo "RPC required"; exit 1)
	@test -n "$(OUTBOUND_CAPACITY)" || (echo "OUTBOUND_CAPACITY required"; exit 1)
	@test -n "$(OUTBOUND_RATE)"     || (echo "OUTBOUND_RATE required"; exit 1)
	@test -n "$(INBOUND_CAPACITY)"  || (echo "INBOUND_CAPACITY required"; exit 1)
	@test -n "$(INBOUND_RATE)"      || (echo "INBOUND_RATE required"; exit 1)
	@test -n "$(CALLER_FLAGS)$(DEPLOYER_PK)" || \
	    (echo "Set CALLER_FLAGS=--account ... (post-handoff) OR DEPLOYER_PK (pre-handoff)"; exit 1)
	forge script script/07_UpdateRateLimits.s.sol --rpc-url $(RPC) --broadcast \
	    $(if $(CALLER_FLAGS),$(CALLER_FLAGS),--private-key $(DEPLOYER_PK))
