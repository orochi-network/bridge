// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Helper} from "./Helper.sol";

/// @notice Asserts that the production CCIP infrastructure addresses for the chain
///         currently being targeted (`block.chainid`) are filled in. Call before any
///         broadcast script — the deployment scripts also call `_requireSet`, but failing
///         here means the operator catches placeholders BEFORE spending gas on a partial
///         broadcast (and BEFORE pre-flight steps like script 01 / 02 reach the chain).
///
///         Per PR #19 review (bao-ninh #12). Wired into the `deploy-eth` / `deploy-bsc`
///         Make targets as a hard prerequisite. CI does not run this — placeholders are
///         expected during development; the precheck only runs when an operator deploys.
contract PrecheckHelper is Script, Helper {
    error PlaceholderField(uint256 chainId, string field);

    function run() external view {
        NetworkConfig memory cfg = getConfig(block.chainid);

        _check(cfg.router, "router");
        _check(cfg.rmnProxy, "rmnProxy");
        _check(cfg.tokenAdminRegistry, "tokenAdminRegistry");
        _check(cfg.registryModuleOwnerCustom, "registryModuleOwnerCustom");
        _check(cfg.linkToken, "linkToken");

        // onToken is allowed to be zero on testnet (no canonical ON; deploy a mock instead).
        if (block.chainid == 1 || block.chainid == 56) _check(cfg.onToken, "onToken");

        console.log("Helper precheck OK for chainId %d", block.chainid);
    }

    function _check(address a, string memory field) internal view {
        if (a == address(0)) revert PlaceholderField(block.chainid, field);
    }
}
