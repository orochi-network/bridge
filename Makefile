.PHONY: help install patch-pragmas build test test-unit test-e2e test-fork test-redeploy-eth fmt fmt-check coverage clean check-links \
        check-storage-layout update-storage-layout \
        precheck-helper validate-config validate-bsc-admin deploy-eth redeploy-eth reconcile-remote-pool deploy-bsc verify-eth verify-bsc handoff handoff-all renounce update-limits

# ─── Defaults ──────────────────────────────────────────────────────────────────
SHELL := /bin/bash
# Deploys are signed by a Foundry encrypted keystore account — no raw private key on the CLI
# or in .env. ACCOUNT defaults to `deployer`; override with `make ... ACCOUNT=<name>`. forge
# prompts for the keystore password per broadcast. Create one with:
#   cast wallet import deployer --interactive
ACCOUNT ?= deployer
DEPLOY_FLAGS := --broadcast --verify --account $(ACCOUNT)
# redeploy-eth knobs (consumed by script/redeploy-eth.sh): simulate unless BROADCAST=1.
BROADCAST ?= 0
CHAIN_ID  ?= 1

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
	@echo "  make check-links     verify Chainlink doc URLs in tracked sources still resolve (pre-release)"
	@echo "  make check-storage-layout   diff wON's WrappedONStorage layout vs the committed snapshot (#50)"
	@echo "  make update-storage-layout  refresh that snapshot after an intentional struct APPEND"
	@echo "  make clean           remove cache/, out/, broadcast/"
	@echo ""
	@echo "Deployment (load .env first; values in capitals come from env):"
	@echo "  ETH_RPC, BSC_RPC, SEPOLIA_RPC, BSC_TESTNET_RPC, ACCOUNT, DEPLOYER, MULTISIG"
	@echo ""
	@echo "  make precheck-helper RPC=...                         # Helper.sol non-zero placeholder check (pure)"
	@echo "  make validate-config RPC=...                         # live staticcall check of CCIP infra addrs (#21)"
	@echo "  make validate-bsc-admin RPC=bsc DEPLOYER=0x..        # probe BSC ON CCIP-admin path (#22)"
	@echo "  make deploy-eth      RPC=sepolia                     # 01 -> 02 -> 03 -> 04 -> 05"
	@echo "  make deploy-bsc      RPC=bsc_testnet                 # 02 -> 04 -> 05"
	@echo "  make verify-eth      RPC=sepolia                     # script 08 view-only"
	@echo "  make verify-bsc      RPC=bsc_testnet"
	@echo "  make handoff         RPC=sepolia MULTISIG=0x.. CONFIRM_HANDOFF=yes   # script 06 (one chain)"
	@echo "  make handoff-all     ETH_RPC=.. BSC_RPC=.. MULTISIG=0x.. CONFIRM_HANDOFF=yes  # two-chain handoff"
	@echo "  make renounce        RPC=sepolia MULTISIG=0x.. CONFIRM_RENOUNCE=yes   # script 06 (renounce step)"
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

# Verify every Chainlink docs URL referenced in tracked sources still resolves
# (issue #20). docs.chain.link restructures periodically and moved pages 404
# silently — e.g. the old `/ccip/concepts/cross-chain-token/{token-pools,tokens,
# registration-and-administration}` paths. Run this as a pre-release gate
# (RUNBOOK §0.0). Network-dependent and external-service-flaky by nature, so it
# is intentionally NOT wired into PR CI; it is an operator/release check.
# Requires `curl`. Exits non-zero if any link does not return HTTP 200.
check-links:
	@urls=$$(git grep -hoE 'https://docs\.chain\.link[^ )>"`]*' -- '*.md' '*.sol' | sed 's/[.,]*$$//' | sort -u); \
	fail=0; \
	for u in $$urls; do \
	  code=$$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 25 --retry 2 "$$u" 2>/dev/null); \
	  if [ "$$code" = "200" ]; then printf '  ok    %s\n' "$$u"; \
	  else printf '  FAIL  %s (HTTP %s)\n' "$$u" "$$code"; fail=1; fi; \
	done; \
	if [ $$fail -ne 0 ]; then echo "One or more Chainlink doc links are broken — update the source files."; exit 1; fi; \
	echo "All Chainlink doc links resolve."

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

# Shell-level regression test for script/redeploy-eth.sh dry-run JSON handling (#59).
# Pure bash + jq (no Foundry); stubs `forge`. Wired into CI.
test-redeploy-eth:
	bash test/redeploy_eth_dryrun_test.sh

fmt:
	forge fmt

fmt-check:
	forge fmt --check

coverage:
	forge coverage --report summary

# wON storage-layout regression guard (issue #50). wON is a UUPS proxy whose entire state
# lives in the ERC-7201 namespaced struct `WrappedONStorage` — which `forge inspect` reports
# as EMPTY on the contract itself, so nothing in CI would catch a field reorder/insert in a
# future impl (silent proxy-state corruption). `check-storage-layout` inspects the dedicated
# probe (test/storage/StorageLayoutProbe.sol), normalises the struct layout, and diffs it
# against the committed snapshot (storage/WrappedON.storage-layout.json), failing on ANY
# change. Run `update-storage-layout` ONLY after an intentional, layout-compatible APPEND.
# Wired into CI (.github/workflows/ci.yml). See script/storage-layout.sh.
check-storage-layout:
	./script/storage-layout.sh check

update-storage-layout:
	./script/storage-layout.sh update

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

# Live (RPC-backed) validation of the filled-in CCIP infra addresses in Helper.sol
# (issue #21). Unlike `precheck-helper` (pure, non-zero only) this staticcalls each
# address on the TARGET chain to confirm it is the expected CCIP contract
# (typeAndVersion), that the router supports the remote lane (chain selector is real),
# and that LINK / canonical-ON look right. Run after filling Helper.sol, before deploy.
validate-config:
	@test -n "$(RPC)" || (echo "RPC required (target chain RPC)"; exit 1)
	forge script script/ValidateConfig.s.sol --rpc-url $(RPC)

# Read-only probe of the BSC ON token's CCIP-admin registration path (issue #22).
# Runs the same path-resolution as script 04 WITHOUT broadcasting, so the operator
# can confirm on live BSC which path (1 getCCIPAdmin / 2 owner / 3 AccessControl)
# script 04 will take before mainnet — or catch the path-4 blocker early. Reads the
# deployer EOA from the DEPLOYER env var; on testnet point at a mock via BSC_ON=0x..
validate-bsc-admin:
	@test -n "$(RPC)" || (echo "RPC required (BSC RPC)"; exit 1)
	forge script script/ValidateBscAdmin.s.sol --rpc-url $(RPC)

# Ethereum sequence (Sepolia or mainnet). Signed by the keystore ACCOUNT (see top of file);
# forge prompts for the keystore password per script. --verify needs ETHERSCAN_API_KEY set.
deploy-eth: precheck-helper
	@test -n "$(RPC)" || (echo "RPC=sepolia|eth required"; exit 1)
	forge script script/01_DeployWrappedON.s.sol      --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/02_DeployPools.s.sol          --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/03_GrantRoles.s.sol           --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/04_RegisterAdminAndPool.s.sol --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/05_ApplyChainUpdates.s.sol    --rpc-url $(RPC) $(DEPLOY_FLAGS)

# Redeploy the ETH side (RUNBOOK §4.4 Step 1): backs up + clears the stale ETH artifacts in
# deployments/<chainId>.json so scripts 01/02 deploy fresh, then runs 01->05. Simulates by
# default; pass BROADCAST=1 to send transactions. Does NOT touch BSC — finish §4.4 by hand.
#   make redeploy-eth RPC=eth                 # simulate (safe)
#   make redeploy-eth RPC=eth BROADCAST=1     # broadcast for real
redeploy-eth: precheck-helper
	@test -n "$(RPC)" || (echo "RPC=sepolia|eth required"; exit 1)
	RPC=$(RPC) ACCOUNT=$(ACCOUNT) BROADCAST=$(BROADCAST) CHAIN_ID=$(CHAIN_ID) ./script/redeploy-eth.sh

# BSC sequence (testnet or mainnet). Skips 01 and 03 (wON only exists on ETH). Signed by the
# keystore ACCOUNT. Note: on BSC mainnet script 04 reverts CannotResolveCCIPAdmin (path-4)
# until the ON CCIP-admin is registered out-of-band with Chainlink — see RUNBOOK §0.2.
deploy-bsc: precheck-helper
	@test -n "$(RPC)" || (echo "RPC=bsc_testnet|bsc required"; exit 1)
	forge script script/02_DeployPools.s.sol          --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/04_RegisterAdminAndPool.s.sol --rpc-url $(RPC) $(DEPLOY_FLAGS)
	forge script script/05_ApplyChainUpdates.s.sol    --rpc-url $(RPC) $(DEPLOY_FLAGS)

# Reconcile a stale lane after a remote redeploy (RUNBOOK §4.4 Step 2, #55). Re-points the
# local pool's lane at the NEW remote pool + NEW remote token via an atomic applyChainUpdates
# remove+add. Use this — NOT `make deploy-bsc` (runs 02+04) and NOT re-running script 05 (only
# ADDS lanes; a re-add reverts ChainAlreadyExists). Idempotent: a no-op if already reconciled.
#   make reconcile-remote-pool RPC=bsc                 # broadcast the re-wire
reconcile-remote-pool: precheck-helper
	@test -n "$(RPC)" || (echo "RPC=bsc|eth|... required"; exit 1)
	forge script script/09_ReconcileRemotePool.s.sol  --rpc-url $(RPC) $(DEPLOY_FLAGS)

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
#
# Manual-trigger guard (decision 2026-06-19, see STATE.md): the handoff is a deliberate,
# custody-grade step run ONLY after the bridge is wired + verified end-to-end. It will NOT
# run by default — it requires an explicit `CONFIRM_HANDOFF=yes`, so it can never fire
# accidentally, while remaining triggerable by hand WITHOUT editing this file (mirrors the
# redeploy-eth.sh type-to-confirm pattern).
handoff: precheck-helper
	@if [ "$(CONFIRM_HANDOFF)" != "yes" ]; then \
	  echo "handoff is GATED (decision 2026-06-19, see STATE.md): keep the deployer EOA in"; \
	  echo "control until the bridge is wired + verified end-to-end, then run it deliberately."; \
	  echo "This is a custody-grade step."; \
	  echo ""; \
	  echo "Trigger manually:  make handoff RPC=<rpc> MULTISIG=0x.. CONFIRM_HANDOFF=yes"; \
	  exit 1; \
	fi
	@test -n "$(MULTISIG)"    || (echo "MULTISIG env var required"; exit 1)
	@test -n "$(RPC)"         || (echo "RPC required"; exit 1)
	MULTISIG=$(MULTISIG) forge script script/06_TransferOwnership.s.sol:TransferOwnership \
	    --rpc-url $(RPC) $(DEPLOY_FLAGS) --sig "run()"

# Two-chain handoff. Sequential, NOT atomic — if the BSC leg fails after the ETH leg
# succeeds, the bridge is half-handed-off until the operator re-runs the BSC leg. The
# handoff calls are idempotent so re-running is safe. Both ETH_RPC and BSC_RPC must point
# at the same operational environment (testnet pair OR mainnet pair) so the same MULTISIG
# ends up wired on both sides.
handoff-all:
	@if [ "$(CONFIRM_HANDOFF)" != "yes" ]; then \
	  echo "handoff-all is GATED (decision 2026-06-19, see STATE.md). Sequential, NOT atomic —"; \
	  echo "if the BSC leg fails after the ETH leg, the bridge is half-handed-off until you"; \
	  echo "re-run (the calls are idempotent)."; \
	  echo ""; \
	  echo "Trigger manually:  make handoff-all ETH_RPC=.. BSC_RPC=.. MULTISIG=0x.. CONFIRM_HANDOFF=yes"; \
	  exit 1; \
	fi
	@test -n "$(MULTISIG)"    || (echo "MULTISIG env var required"; exit 1)
	@test -n "$(ETH_RPC)"     || (echo "ETH_RPC env var required"; exit 1)
	@test -n "$(BSC_RPC)"     || (echo "BSC_RPC env var required"; exit 1)
	$(MAKE) handoff MULTISIG=$(MULTISIG) RPC=$(ETH_RPC) CONFIRM_HANDOFF=yes
	$(MAKE) handoff MULTISIG=$(MULTISIG) RPC=$(BSC_RPC) CONFIRM_HANDOFF=yes

# Final renounce — only after multisig has accepted everything on both chains.
# Renounce is even more final than handoff (it irreversibly drops the deployer's roles), so
# it has its OWN confirmation var — a handoff confirmation can never cascade into a renounce.
renounce: precheck-helper
	@if [ "$(CONFIRM_RENOUNCE)" != "yes" ]; then \
	  echo "renounce is GATED (decision 2026-06-19, see STATE.md): run ONLY after the multisig"; \
	  echo "has accepted everything on BOTH chains. This irreversibly drops the deployer's roles."; \
	  echo ""; \
	  echo "Trigger manually:  make renounce RPC=<rpc> MULTISIG=0x.. CONFIRM_RENOUNCE=yes"; \
	  exit 1; \
	fi
	@test -n "$(MULTISIG)"    || (echo "MULTISIG env var required"; exit 1)
	@test -n "$(RPC)"         || (echo "RPC required"; exit 1)
	MULTISIG=$(MULTISIG) forge script script/06_TransferOwnership.s.sol:RenounceDeployerAdmin \
	    --rpc-url $(RPC) $(DEPLOY_FLAGS) --sig "run()"

# SECURITY: OPS-2 — the caller must be authorised on the pool at the time of the call:
#   - pre-handoff   : CALLER_FLAGS unset → falls back to the keystore ACCOUNT (`deployer`).
#   - post-handoff  : CALLER_FLAGS='--account multisig-signer' (or another keystore account
#                     for the delegated `rateLimitAdmin`). The multisig itself queues this
#                     call via the Safe UI; this Makefile target is for the delegated
#                     hot-key path described in RUNBOOK §4.1.1.
update-limits:
	@test -n "$(RPC)"               || (echo "RPC required"; exit 1)
	@test -n "$(OUTBOUND_CAPACITY)" || (echo "OUTBOUND_CAPACITY required"; exit 1)
	@test -n "$(OUTBOUND_RATE)"     || (echo "OUTBOUND_RATE required"; exit 1)
	@test -n "$(INBOUND_CAPACITY)"  || (echo "INBOUND_CAPACITY required"; exit 1)
	@test -n "$(INBOUND_RATE)"      || (echo "INBOUND_RATE required"; exit 1)
	forge script script/07_UpdateRateLimits.s.sol --rpc-url $(RPC) --broadcast \
	    $(if $(CALLER_FLAGS),$(CALLER_FLAGS),--account $(ACCOUNT))
