// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal IRMN mock — pools call `isCursed(bytes16)` per chain. Default: not cursed.
contract MockRMN {
    bool public cursedGlobally;
    mapping(bytes16 => bool) public cursedPerSubject;

    function setGlobalCurse(bool v) external {
        cursedGlobally = v;
    }

    function setSubjectCurse(bytes16 subject, bool v) external {
        cursedPerSubject[subject] = v;
    }

    function isCursed() external view returns (bool) {
        return cursedGlobally;
    }

    function isCursed(bytes16 subject) external view returns (bool) {
        return cursedGlobally || cursedPerSubject[subject];
    }
}
