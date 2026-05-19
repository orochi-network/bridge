// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal IRouter mock for pool tests. Returns a configurable onRamp / offRamp
///         address per chain selector. Pools call `getOnRamp` (for `lockOrBurn`) and
///         `isOffRamp` (for `releaseOrMint`); both gates rely on a single per-chain ramp here.
contract MockRouter {
    mapping(uint64 => address) public onRamps;
    mapping(uint64 => mapping(address => bool)) public offRamps;

    function setOnRamp(uint64 selector, address ramp) external {
        onRamps[selector] = ramp;
    }

    function setOffRamp(uint64 selector, address ramp, bool ok) external {
        offRamps[selector][ramp] = ok;
    }

    function getOnRamp(uint64 selector) external view returns (address) {
        return onRamps[selector];
    }

    function isOffRamp(uint64 selector, address ramp) external view returns (bool) {
        return offRamps[selector][ramp];
    }
}
