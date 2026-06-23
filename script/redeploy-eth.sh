#!/usr/bin/env bash
#
# redeploy-eth.sh — Redeploy the ETHEREUM side of the ON bridge (RUNBOOK §4.4, Step 1).
#
# Replaces wON (UUPS proxy + impl + TimelockController) and its BurnMintTokenPool on Ethereum
# by re-running the audited modular scripts 01 → 05. It does NOT reimplement them — it backs up
# and clears the stale ETH artifact entries in deployments/<chainId>.json so scripts 01/02
# deploy fresh instead of skipping (their built-in idempotency guard), then runs the sequence.
#
# It deliberately does NOT touch BSC. After this completes, finish RUNBOOK §4.4 yourself:
#   Step 2  reconcile the existing BSC LockReleaseTokenPool's ETH lane onto the NEW ETH pool +
#           NEW wON via script 09 (`make reconcile-remote-pool RPC=bsc`) — an atomic
#           applyChainUpdates remove+add. NEVER `make deploy-bsc`, never script 04 on BSC
#           (path-4 blocker, CannotResolveCCIPAdmin); NEVER re-run script 05 (it only ADDS
#           lanes — a re-add reverts ChainAlreadyExists; #55).
#   Step 3  (optional) deregister the old wON in the TokenAdminRegistry.
#   Step 4  verify both chains: `make verify-eth` && `make verify-bsc`.
#
# SAFETY
#   - Simulates by default (no on-chain effect). Set BROADCAST=1 to send transactions.
#   - Always backs up deployments/<chainId>.json before clearing it.
#   - In simulation, the JSON is restored from that backup afterwards (so the dry run's
#     simulated addresses, written by vm.writeJson, never persist).
#   - Broadcasting prompts for confirmation unless ASSUME_YES=1.
#
# USAGE
#   RPC=<url|foundry-alias> ./script/redeploy-eth.sh            # simulate (safe)
#   RPC=eth BROADCAST=1 ./script/redeploy-eth.sh               # broadcast for real
#   RPC=sepolia CHAIN_ID=11155111 BROADCAST=1 ./script/redeploy-eth.sh
#
# ENV
#   RPC         (required) RPC url or foundry rpc-endpoints alias. Also accepted as $1.
#   CHAIN_ID    (default 1) 1 = mainnet, 11155111 = sepolia. Selects deployments/<id>.json.
#   ACCOUNT     (default deployer) foundry keystore account to sign with (--account).
#   BROADCAST   (default 0) 1 = send transactions; 0 = simulate only.
#   ASSUME_YES  (default 0) 1 = skip the broadcast confirmation prompt (for CI).
#
set -euo pipefail

RPC="${RPC:-${1:-}}"
CHAIN_ID="${CHAIN_ID:-1}"
ACCOUNT="${ACCOUNT:-deployer}"
BROADCAST="${BROADCAST:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# Stale ETH artifacts whose presence makes scripts 01/02 skip. The BSC `LockReleaseTokenPool`
# (BSC artifact) is intentionally untouched. `deployer` is left as-is (script 01 rewrites it).
STALE_KEYS=(wrappedON wrappedONImpl wrappedONTimelock pool)

err() { printf 'redeploy-eth: %s\n' "$1" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────
[ -n "$RPC" ] || err "RPC is required (RPC=<url|alias> or pass as the first argument)."
command -v forge >/dev/null 2>&1 || err "forge not found on PATH."
command -v jq    >/dev/null 2>&1 || err "jq is required to edit the deployments JSON."

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSON="$ROOT/deployments/${CHAIN_ID}.json"
cd "$ROOT"

if [ "$BROADCAST" = "1" ]; then
  echo "MODE: BROADCAST — real transactions will be sent on chain $CHAIN_ID via account '$ACCOUNT'."
  if [ "$ASSUME_YES" != "1" ]; then
    read -r -p "Type 'redeploy' to proceed: " reply
    [ "$reply" = "redeploy" ] || err "Aborted."
  fi
  FLAGS=(--rpc-url "$RPC" --broadcast --verify --account "$ACCOUNT")
else
  echo "MODE: SIMULATION — no transactions sent, deployments JSON restored afterwards."
  echo "      (set BROADCAST=1 to send transactions for real.)"
  FLAGS=(--rpc-url "$RPC" --account "$ACCOUNT")
fi

# ── Back up + clear the stale ETH artifacts so 01/02 redeploy ────────────────
BACKUP=""
JSON_WAS_ABSENT=0
if [ -f "$JSON" ]; then
  BACKUP="$JSON.superseded-$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$JSON" "$BACKUP"
  echo "Backed up $JSON -> $BACKUP"
  del_filter="del(.${STALE_KEYS[0]}"
  for k in "${STALE_KEYS[@]:1}"; do del_filter+=", .$k"; done
  del_filter+=")"
  tmp="$(mktemp)"
  jq "$del_filter" "$JSON" > "$tmp" && mv "$tmp" "$JSON"
  echo "Cleared stale ETH artifact keys: ${STALE_KEYS[*]}"
else
  JSON_WAS_ABSENT=1
  echo "No existing $JSON — treating as a fresh deploy."
fi

# In simulation, undo any deployments JSON that Foundry's FS cheatcodes wrote. The FS
# cheatcodes (vm.writeJson) run during simulation too — they are NOT gated on --broadcast —
# so a dry run otherwise persists SIMULATED addresses, and the next real run's idempotency
# guard would treat them as "already deployed" and skip. Undo on exit so a dry run leaves no
# trace (#59):
#   - file pre-existed -> restore it from the backup;
#   - file was absent  -> delete the file the simulation created.
# On a real broadcast the new (real) addresses are kept.
restore_on_sim() {
  if [ "$BROADCAST" = "1" ]; then
    return
  fi
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$JSON"
    echo "Simulation: restored $JSON from backup (no addresses written)."
  elif [ "$JSON_WAS_ABSENT" = "1" ] && [ -f "$JSON" ]; then
    rm -f "$JSON"
    echo "Simulation: removed $JSON created during the dry run (no addresses written)."
  fi
}
trap restore_on_sim EXIT

# ── Run the ETH deploy sequence (01 → 05) ────────────────────────────────────
for s in \
  01_DeployWrappedON \
  02_DeployPools \
  03_GrantRoles \
  04_RegisterAdminAndPool \
  05_ApplyChainUpdates
do
  echo "=== script/$s.s.sol ==="
  forge script "script/$s.s.sol" "${FLAGS[@]}"
done

# ── Next steps ───────────────────────────────────────────────────────────────
cat <<NEXT

ETH redeploy ${BROADCAST:+}$([ "$BROADCAST" = 1 ] && echo "BROADCAST" || echo "SIMULATION") complete.
New addresses are in $JSON (old values preserved in the .superseded-* backup).

Finish RUNBOOK §4.4:
  Step 2  BSC reconcile — re-point the existing BSC pool's ETH lane at the NEW ETH pool + NEW
          wON (script 09 ONLY — do NOT use 'make deploy-bsc', do NOT run script 04, do NOT
          re-run script 05 which only ADDS lanes and reverts ChainAlreadyExists on a re-add):
            make reconcile-remote-pool RPC=bsc
            # or: forge script script/09_ReconcileRemotePool.s.sol --rpc-url bsc --broadcast --account $ACCOUNT
  Step 3  (optional) deregister the old wON in the TokenAdminRegistry (see RUNBOOK §4.4 Step 3).
  Step 4  verify both chains:
            make verify-eth RPC=$RPC
            make verify-bsc RPC=bsc
NEXT
