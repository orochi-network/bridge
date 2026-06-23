#!/usr/bin/env python3
"""Normalise a `forge inspect StorageLayoutProbe storageLayout --json` blob into a stable
snapshot of WrappedON's ERC-7201 `WrappedONStorage` struct layout (issue #50).

`StorageLayoutProbe` declares `WrappedON.WrappedONStorage` as its single state variable, so the
compiler emits the struct's member layout. We keep only what defines upgrade-safety — the
ordered fields and their slot / offset / resolved type — and drop volatile noise (`astId`,
source-file paths) so the committed snapshot diffs cleanly and only on real layout changes.

Reads the forge JSON on stdin, writes the normalised JSON to stdout (sorted keys, trailing
newline) so the output is deterministic across machines and forge versions.
"""

import json
import sys


def _resolve_type(types: dict, type_id: str) -> dict:
    """Flatten a forge type entry to its layout-relevant fields, recursing into struct members."""
    t = types.get(type_id, {})
    out = {
        "label": t.get("label"),
        "encoding": t.get("encoding"),
        "numberOfBytes": t.get("numberOfBytes"),
    }
    if "members" in t:
        out["members"] = [_member(types, m) for m in t["members"]]
    return out


def _member(types: dict, m: dict) -> dict:
    """A single struct member: keep label/slot/offset + the resolved type; drop astId/contract."""
    return {
        "label": m.get("label"),
        "slot": m.get("slot"),
        "offset": m.get("offset"),
        "type": _resolve_type(types, m.get("type")),
    }


def main() -> int:
    raw = json.load(sys.stdin)
    types = raw.get("types") or {}
    storage = raw.get("storage") or []

    # The probe declares exactly one state variable (the WrappedONStorage struct). Find it and
    # emit ITS struct layout — not the probe variable's own slot (which is always 0 and is not
    # what we are guarding).
    struct = None
    for var in storage:
        resolved = types.get(var.get("type"), {})
        if "members" in resolved:
            struct = _resolve_type(types, var["type"])
            break

    if struct is None:
        sys.stderr.write(
            "storage-layout.py: could not find the WrappedONStorage struct in the probe layout.\n"
            "The probe (test/storage/StorageLayoutProbe.sol) must declare exactly one\n"
            "WrappedON.WrappedONStorage state variable.\n"
        )
        return 1

    snapshot = {
        "_comment": (
            "Storage-layout snapshot of WrappedON.WrappedONStorage (ERC-7201 slot "
            "orochi.storage.WrappedON). Guards wON UUPS upgrades (issue #50). Regenerate with "
            "`make update-storage-layout` ONLY for an intentional append; any reorder/insert/"
            "remove/retype is a proxy-state-corrupting change."
        ),
        "struct": struct,
    }
    json.dump(snapshot, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
