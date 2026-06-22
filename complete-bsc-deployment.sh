#!/usr/bin/env bash
#
# complete-bsc-deployment.sh
#
# Finishes the ON bridge once the BSC LockReleaseTokenPool is deployed:
#   1. Registry registration on BSC (script 04: register admin + accept + setPool)
#   2. Chain wiring on BSC        (script 05: wire ETH remote + rate limits)
#   3. Chain wiring re-run on ETH (script 05: wire the now-known BSC remote)
#   4. View-only verification of both sides
#
# Signs with an encrypted keystore account (--account), never a raw private key.
# `forge` will prompt for the keystore password per broadcast.
#
# PRECONDITION (BSC path-4): the canonical BSC ON token has a renounced owner and no
# getCCIPAdmin, so you cannot self-register as its TokenAdminRegistry administrator.
# Chainlink (the registry owner) must register your deployer EOA as ON's administrator
# FIRST. This script verifies that gate and refuses to spend gas until it is cleared.
#
# Usage:
#   ./complete-bsc-deployment.sh            # do it (broadcasts)
#   DRY_RUN=1 ./complete-bsc-deployment.sh  # simulate only, no --broadcast
#
# Env overrides:
#   ACCOUNT     keystore account name           (default: deployer)
#   ETH_ALIAS   foundry rpc_endpoints alias      (default: eth)
#   BSC_ALIAS   foundry rpc_endpoints alias      (default: bsc)
#
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────────
ACCOUNT="${ACCOUNT:-deployer}"
ETH_ALIAS="${ETH_ALIAS:-eth}"
BSC_ALIAS="${BSC_ALIAS:-bsc}"
DRY_RUN="${DRY_RUN:-0}"

# Canonical mainnet constants (cross-check against script/Helper.sol).
BSC_ON="0x0e4F6209eD984b21EDEA43acE6e09559eD051D48"
BSC_REGISTRY="0x736Fd8660c443547a85e4Eaf70A49C1b7Bb008fc"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# ── Helpers ─────────────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die()   { red "ERROR: $*"; exit 1; }

# Broadcast flag is omitted in DRY_RUN so nothing hits the chain.
BROADCAST="--broadcast"
[ "$DRY_RUN" = "1" ] && { BROADCAST=""; printf '(DRY RUN — no transactions will be broadcast)\n'; }

json_addr() { # $1=chainId $2=key
  python3 -c "import json,sys;print(json.load(open('deployments/'+sys.argv[1]+'.json')).get(sys.argv[2],''))" "$1" "$2" 2>/dev/null
}

# ── 0. Preconditions ─────────────────────────────────────────────────────────────
command -v cast  >/dev/null || die "foundry 'cast' not found on PATH"
command -v forge >/dev/null || die "foundry 'forge' not found on PATH"

# RPC aliases resolve ${ETH_RPC}/${BSC_RPC} from the environment via foundry.toml.
# Source .env (if present) so they are populated; never printed.
if [ -f .env ]; then set -a; . ./.env; set +a; fi

# Confirm the keystore account exists. Check the keystore file directly — `cast wallet list`
# renders entries like "0xdeployer (Local)", so a whole-word grep gives false negatives.
KEYSTORE_DIR="${FOUNDRY_KEYSTORES:-$HOME/.foundry/keystores}"
[ -f "$KEYSTORE_DIR/$ACCOUNT" ] || cast wallet list 2>/dev/null | grep -qi -- "$ACCOUNT" \
  || die "keystore account '$ACCOUNT' not found in $KEYSTORE_DIR (create with: cast wallet new ~/.foundry/keystores $ACCOUNT)"

DEPLOYER="$(cast wallet address --account "$ACCOUNT" 2>/dev/null || true)"
[ -n "$DEPLOYER" ] || die "could not resolve address for keystore account '$ACCOUNT'"
green "Deployer (account '$ACCOUNT'): $DEPLOYER"

ETH_POOL="$(json_addr 1 pool)"
BSC_POOL="$(json_addr 56 pool)"
WON="$(json_addr 1 wrappedON)"
[ -n "$ETH_POOL" ] || die "deployments/1.json missing 'pool' — run the ETH deploy first"
[ -n "$BSC_POOL" ] || die "deployments/56.json missing 'pool' — run script 02 on BSC first"
printf 'ETH pool: %s\nBSC pool: %s\nwON:      %s\n' "$ETH_POOL" "$BSC_POOL" "$WON"

# ── 1. Path-4 gate: is the deployer ON's administrator on BSC? ────────────────────
step "Checking BSC ON administrator (path-4 gate)"
# getTokenConfig -> (administrator, pendingAdministrator, tokenPool)
CFG="$(cast call "$BSC_REGISTRY" 'getTokenConfig(address)(address,address,address)' "$BSC_ON" --rpc-url "$BSC_ALIAS")"
ADMIN="$(echo "$CFG"   | sed -n '1p')"
PENDING="$(echo "$CFG" | sed -n '2p')"
printf 'registry administrator:        %s\nregistry pendingAdministrator: %s\n' "$ADMIN" "$PENDING"

lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
if [ "$(lc "$ADMIN")" = "$(lc "$DEPLOYER")" ]; then
  green "Deployer is already the administrator — proceeding."
elif [ "$(lc "$PENDING")" = "$(lc "$DEPLOYER")" ]; then
  green "Deployer is the PENDING administrator — script 04 will acceptAdminRole then setPool."
else
  red "BLOCKED: deployer is neither administrator nor pendingAdministrator for BSC ON."
  cat <<EOF

This is the path-4 blocker. The BSC ON token ($BSC_ON) has a renounced owner and no
getCCIPAdmin, so 'proposeAdministrator' is not operator-callable. Chainlink (the owner of
TokenAdminRegistry $BSC_REGISTRY) must register your deployer
  $DEPLOYER
as ON's administrator before this script can register the pool.

Once Chainlink has done that (you should see your address as administrator or
pendingAdministrator above), re-run this script.
EOF
  exit 2
fi

# ── 2. BSC registry registration (script 04) ─────────────────────────────────────
step "BSC: register admin + setPool (script 04)"
forge script script/04_RegisterAdminAndPool.s.sol --rpc-url "$BSC_ALIAS" $BROADCAST --account "$ACCOUNT"

# ── 3. BSC chain wiring (script 05) ──────────────────────────────────────────────
step "BSC: applyChainUpdates — wire ETH remote + rate limits (script 05)"
forge script script/05_ApplyChainUpdates.s.sol --rpc-url "$BSC_ALIAS" $BROADCAST --account "$ACCOUNT"

# ── 4. ETH chain wiring re-run (script 05) ───────────────────────────────────────
step "ETH: applyChainUpdates — wire the BSC remote (script 05 re-run)"
forge script script/05_ApplyChainUpdates.s.sol --rpc-url "$ETH_ALIAS" $BROADCAST --account "$ACCOUNT"

# ── 5. Verify both sides ─────────────────────────────────────────────────────────
step "Verify ETH"
forge script script/08_PostDeployVerify.s.sol --rpc-url "$ETH_ALIAS"
step "Verify BSC"
forge script script/08_PostDeployVerify.s.sol --rpc-url "$BSC_ALIAS"

green "\nDone. Both sides registered and wired. Do NOT hand off to the multisig until the"
green "two verifications above are clean and you've run a small live bridge test (RUNBOOK §2.5)."
