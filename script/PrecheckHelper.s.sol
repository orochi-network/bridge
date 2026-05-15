// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Helper} from "./Helper.sol";

/// @notice Asserts that the production CCIP infrastructure addresses are filled in for BOTH
///         the chain currently being targeted (`block.chainid`) and its bridge counterpart.
///         Call before any broadcast script — the deployment scripts also call `_requireSet`,
///         but failing here means the operator catches placeholders BEFORE spending gas on
///         a partial broadcast.
///
///         Round-1 (bao-ninh #12) added the local-chain check; round-2 ([4]) extends it to
///         the remote chain so a deploy-eth run also catches missing BSC config (script 05's
///         remote-pool wiring read pulls from the remote `Helper` and would only fail
///         mid-broadcast otherwise). `getConfig` is `pure` so the remote-chain check works
///         without any cross-chain RPC.
///
///         Wired into the `deploy-eth` / `deploy-bsc` Make targets as a hard prerequisite.
///         CI does not run this — placeholders are expected during development; the precheck
///         only runs when an operator deploys.
contract PrecheckHelper is Script, Helper {
    error PlaceholderField(uint256 chainId, string field);

    function run() external view {
        _checkChain(block.chainid);
        _checkChain(_remoteChainId(block.chainid));
        console.log("Helper precheck OK for chainId %d (and remote)", block.chainid);
    }

    function _checkChain(uint256 chainId) internal pure {
        NetworkConfig memory cfg = getConfig(chainId);

        _check(chainId, cfg.router, "router");
        _check(chainId, cfg.rmnProxy, "rmnProxy");
        _check(chainId, cfg.tokenAdminRegistry, "tokenAdminRegistry");
        _check(chainId, cfg.registryModuleOwnerCustom, "registryModuleOwnerCustom");
        _check(chainId, cfg.linkToken, "linkToken");

        // onToken: required on mainnet, AND on BSC testnet (script 05 reads it as the
        // remote-token argument; address(0) would fail `_requireSet(remoteToken, …)`).
        // ETH-side (chainId 1 / 11_155_111) reads `wrappedON` from Deployments, not Helper,
        // so the Helper `onToken` for those chains can stay zero.
        bool needsOnToken = chainId == 56 || chainId == 97;
        if (needsOnToken) _check(chainId, cfg.onToken, "onToken");
    }

    function _check(uint256 chainId, address a, string memory field) internal pure {
        if (a == address(0)) revert PlaceholderField(chainId, field);
    }

    function _remoteChainId(uint256 chainId) internal pure returns (uint256) {
        if (chainId == 1) return 56;
        if (chainId == 56) return 1;
        if (chainId == 11_155_111) return 97;
        if (chainId == 97) return 11_155_111;
        revert UnsupportedChain(chainId);
    }
}
