#!/usr/bin/env bash
#
# Regression test for script/redeploy-eth.sh dry-run JSON handling (#59).
#
# Foundry's FS cheatcodes (vm.writeJson) run during SIMULATION too — they are not gated on
# --broadcast — so a dry run writes simulated addresses into deployments/<chainId>.json. The
# bug: the restore trap only fired when a backup was taken (i.e. only when the file pre-existed),
# so a dry run on a FRESH chain (no prior file) persisted simulated addresses, and the next real
# run's idempotency guard would treat them as "already deployed" and skip.
#
# This test stubs `forge` (to simulate vm.writeJson) and runs the real script in an isolated
# sandbox, asserting:
#   1. absent JSON + dry run      -> the simulation-created file is REMOVED
#   2. absent JSON + broadcast    -> the (real) file is KEPT
#   3. pre-existing JSON + dry run -> the file is RESTORED to its original content
#
# Pure bash + jq (already a redeploy-eth.sh dependency). No Foundry required.
set -euo pipefail

SCRIPT_UNDER_TEST="$(cd "$(dirname "$0")/.." && pwd)/script/redeploy-eth.sh"
[ -f "$SCRIPT_UNDER_TEST" ] || { echo "FAIL: cannot find $SCRIPT_UNDER_TEST" >&2; exit 1; }

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/script" "$SBX/deployments" "$SBX/bin"
cp "$SCRIPT_UNDER_TEST" "$SBX/script/redeploy-eth.sh"
chmod +x "$SBX/script/redeploy-eth.sh"

CHAIN_ID=31337999
JSON="$SBX/deployments/$CHAIN_ID.json"

# Stub `forge`: simulate `vm.writeJson` by writing simulated addresses into $JSON, like the deploy
# scripts do during simulation. Shadows the real forge on PATH; real jq is still resolved.
cat > "$SBX/bin/forge" <<EOF
#!/usr/bin/env bash
printf '{"wrappedON":"0xSIMULATED","pool":"0xSIMPOOL"}\n' > "$JSON"
exit 0
EOF
chmod +x "$SBX/bin/forge"
export PATH="$SBX/bin:$PATH"

# `env` (not a bare prefix) so the per-case VAR=VALUE args in "$@" are applied as assignments —
# a post-expansion `NAME=value` word is otherwise treated as a command, not an assignment.
run() { env RPC=dummy CHAIN_ID="$CHAIN_ID" "$@" bash "$SBX/script/redeploy-eth.sh" >/dev/null 2>&1; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# ── Case 1: absent JSON + dry run -> simulation-created file must be REMOVED ──
rm -f "$JSON"
run BROADCAST=0
[ ! -f "$JSON" ] || fail "dry-run on absent JSON left a simulated file behind (#59 regression)"
echo "ok 1/3: absent + dry-run -> simulated file removed"

# ── Case 2: absent JSON + broadcast -> real file must be KEPT ─────────────────
rm -f "$JSON"
run BROADCAST=1 ASSUME_YES=1
[ -f "$JSON" ] || fail "broadcast on absent JSON did not keep the real file"
echo "ok 2/3: absent + broadcast -> real file kept"

# ── Case 3: pre-existing JSON + dry run -> file RESTORED to original content ──
printf '{"wrappedON":"0xORIGINAL"}\n' > "$JSON"
ORIG="$(cat "$JSON")"
run BROADCAST=0
[ -f "$JSON" ] || fail "dry-run deleted a PRE-EXISTING JSON (should restore it)"
[ "$(cat "$JSON")" = "$ORIG" ] || fail "dry-run did not restore pre-existing JSON content"
echo "ok 3/3: pre-existing + dry-run -> restored to original"

echo "ALL PASS: redeploy-eth dry-run JSON handling (#59)"
