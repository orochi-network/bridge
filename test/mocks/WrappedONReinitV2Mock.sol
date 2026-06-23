// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {WrappedON} from "../../src/WrappedON.sol";

/// @notice Scaffold for the FIRST stateful wON upgrade (#60). Demonstrates the `reinitializer(2)`
///         pattern WITHOUT touching the V1 `WrappedONStorage` struct (which the storage-layout
///         guard freezes — `make check-storage-layout`):
///
///           - the new field lives in its OWN ERC-7201 namespace (`orochi.storage.WrappedON.v2`),
///             so it can never collide with V1 state regardless of V1's field count; and
///           - `initializeV2` is gated by `reinitializer(2)`, so it runs **exactly once** after
///             the V1 `initialize` (version 1) — a second call reverts `InvalidInitialization`.
///
///         Production stateful upgrade pattern: execute it atomically with the upgrade —
///         `upgradeToAndCall(newImpl, abi.encodeCall(WrappedONReinitV2Mock.initializeV2, (x)))` —
///         so the proxy is never live in a half-initialised state. Test-only; never deployed.
contract WrappedONReinitV2Mock is WrappedON {
    /// @custom:storage-location erc7201:orochi.storage.WrappedON.v2
    struct V2Storage {
        uint256 newField;
    }

    // = keccak256(abi.encode(uint256(keccak256("orochi.storage.WrappedON.v2")) - 1)) & ~bytes32(uint256(0xff))
    // Verified with `cast index-erc7201 orochi.storage.WrappedON.v2`.
    bytes32 private constant _V2_STORAGE_LOCATION = 0x0267614e6383fdf9dc8b44117997cdaf3fa294518966035ce2ebe30bf8e80400;

    function _v2() private pure returns (V2Storage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := _V2_STORAGE_LOCATION
        }
    }

    /// @notice First stateful-upgrade initializer. `reinitializer(2)` lets it run exactly once,
    ///         after V1's `initialize` (version 1) and before any version-3 reinitializer.
    function initializeV2(uint256 newField_) external reinitializer(2) {
        _v2().newField = newField_;
    }

    function newField() external view returns (uint256) {
        return _v2().newField;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
