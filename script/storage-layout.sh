#!/usr/bin/env bash
#
# storage-layout.sh — wON storage-layout regression guard (issue #50).
#
# `WrappedON` is UUPS-upgradeable with ALL state in the ERC-7201 namespaced struct
# `WrappedONStorage` (slot `orochi.storage.WrappedON`), reached via an assembly accessor.
# Because that struct is never a regular state variable, `forge inspect` on the contract
# itself reports an EMPTY layout — so there is no build/CI-time check that a future impl
# preserves the field order. A PR that reorders or inserts a field (instead of appending)
# would silently corrupt proxy state while CI stayed green.
#
# This guard inspects the dedicated probe `test/storage/StorageLayoutProbe.sol`, which
# declares `WrappedON.WrappedONStorage` as a plain state variable so the compiler emits the
# struct's member layout. It normalises that layout (via script/storage-layout.py: drops
# volatile astId / source-path noise, keeps field order + slot + offset + resolved type) into
# a stable JSON snapshot at storage/WrappedON.storage-layout.json.
#
# Scope note (UPG-5): this snapshot guards the MEMBER layout (order/slot/offset/type). It does
# NOT catch a relocation of the whole WrappedONStorage struct via a changed _STORAGE_LOCATION /
# namespace annotation — the members stay byte-identical relative to the (moved) base slot.
# That case is covered separately by `test_Erc7201BaseSlotMatchesNamespace`, which derives the
# base slot from the "orochi.storage.WrappedON" namespace and asserts V1 state lives there.
# The snapshot diff and that test together are the full guard.
#
# Modes:
#   check  (default) — regenerate the layout and diff it against the committed snapshot.
#                      Exits non-zero on ANY difference (including appends — by design: an
#                      append is a deliberate, reviewable change and must be snapshotted).
#   update           — overwrite the committed snapshot with the current layout.
#
# Usage:
#   ./script/storage-layout.sh check     # CI / pre-commit guard
#   ./script/storage-layout.sh update    # after an intentional, layout-compatible append
#
# Requires: forge, python3.
set -euo pipefail

MODE="${1:-check}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT="${ROOT}/storage/WrappedON.storage-layout.json"
PROBE_CONTRACT="StorageLayoutProbe"

cd "${ROOT}"

# `forge inspect ... --force` recompiles WITH storage-layout output (the cached artifact omits
# it). The python normaliser emits only the WrappedONStorage members in declaration order, each
# with label/slot/offset and the resolved type — deterministic and meaningful to diff.
generate() {
  forge inspect "${PROBE_CONTRACT}" storageLayout --json --force \
    | python3 "${ROOT}/script/storage-layout.py"
}

case "${MODE}" in
  update)
    mkdir -p "$(dirname "${SNAPSHOT}")"
    generate > "${SNAPSHOT}"
    echo "Wrote storage-layout snapshot: ${SNAPSHOT#"${ROOT}"/}"
    ;;
  check)
    if [[ ! -f "${SNAPSHOT}" ]]; then
      echo "ERROR: no committed snapshot at ${SNAPSHOT#"${ROOT}"/}." >&2
      echo "       Run 'make update-storage-layout' to create it." >&2
      exit 1
    fi
    CURRENT="$(generate)"
    if diff -u "${SNAPSHOT}" <(printf '%s\n' "${CURRENT}"); then
      echo "OK: WrappedON storage layout matches the committed snapshot."
    else
      cat >&2 <<'MSG'

────────────────────────────────────────────────────────────────────────────────
STORAGE-LAYOUT REGRESSION: WrappedON's WrappedONStorage layout changed.

wON is a UUPS proxy. Reordering, inserting, removing, or retyping a field in
WrappedONStorage CORRUPTS live proxy state. The ONLY safe change is APPENDING a
new field to the end of the struct.

  • If you APPENDED a field (and only appended): this is intentional. Run
        make update-storage-layout
    to refresh the snapshot, and commit it alongside the WrappedON.sol change.

  • If the diff above shows a field moved, was inserted in the middle, was removed,
    or changed type: this is a layout-breaking change. STOP — it must not ship as
    an upgrade. Revert it.
────────────────────────────────────────────────────────────────────────────────
MSG
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [check|update]" >&2
    exit 2
    ;;
esac
