// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {WrappedON} from "../../src/WrappedON.sol";

/// @dev Trivial V2: adds a new function + a reinitializer to prove upgrades work and state
///      survives. Reuses V1 storage (ERC-7201 namespace identical via inheritance).
contract WrappedONV2Mock is WrappedON {
    function version() external pure returns (uint256) {
        return 2;
    }
}
