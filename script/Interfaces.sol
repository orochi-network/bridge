// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// Minimal read interfaces shared by the scripts that probe a token's CCIP-admin
// registration path (04_RegisterAdminAndPool, ValidateBscAdmin). Kept here so the two
// scripts cannot drift apart in how they detect path-1/2/3 admin ownership.

interface IGetCCIPAdmin {
    function getCCIPAdmin() external view returns (address);
}

interface IOwnable {
    function owner() external view returns (address);
}

interface IAccessControlRead {
    function hasRole(bytes32 role, address account) external view returns (bool);
}
