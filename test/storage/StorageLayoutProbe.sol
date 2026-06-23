// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {WrappedON} from "../../src/WrappedON.sol";

/// @notice Storage-layout regression probe for the wON UUPS upgrade guard (issue #50).
///
/// `WrappedON` keeps ALL of its state in the ERC-7201 namespaced struct `WrappedONStorage`,
/// reached via an assembly `slot :=` accessor. Because that struct is never declared as a
/// regular state variable, `forge inspect src/WrappedON.sol:WrappedON storageLayout` reports
/// an EMPTY layout — so a naive snapshot of the contract itself would catch nothing.
///
/// This probe declares `WrappedON.WrappedONStorage` as a plain state variable so the compiler
/// emits the struct's member layout (field order, slots, offsets, types). The guard
/// (`make check-storage-layout`, via `script/storage-layout.sh`) inspects THIS contract,
/// normalises the output, and diffs it against the committed snapshot at
/// `storage/WrappedON.storage-layout.json`, failing on any reorder / insert / removal /
/// type change of a `WrappedONStorage` field.
///
/// This contract is build- and inspect-only; it is never deployed and holds no logic.
contract StorageLayoutProbe {
    WrappedON.WrappedONStorage internal layout;
}
