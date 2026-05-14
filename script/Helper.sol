// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Per-chain CCIP infrastructure config.
///
/// **All `address` fields below are intentionally `address(0)` placeholders.** Look up the
/// current values in the public Chainlink CCIP directory and fill them in immediately before
/// deploying. The deployment scripts call `_requireSet(...)` on every address they read,
/// so attempting to broadcast with placeholders fails fast with a clear `MissingAddress` error.
///
///   Directory: https://docs.chain.link/ccip/directory
///
/// Chain selectors are stable identifiers and rarely change — they are committed here.
abstract contract Helper {
    struct NetworkConfig {
        uint64 chainSelector;
        address router;
        address rmnProxy;
        address tokenAdminRegistry;
        address registryModuleOwnerCustom;
        address linkToken;
        /// @notice Canonical ON ERC20 on this chain. zero address means "deploy a mock or skip".
        address onToken;
    }

    error UnsupportedChain(uint256 chainId);
    error MissingAddress(string what);

    uint64 internal constant ETH_MAINNET_SELECTOR = 5_009_297_550_715_157_269;
    uint64 internal constant SEPOLIA_SELECTOR = 16_015_286_601_757_825_753;
    uint64 internal constant BSC_MAINNET_SELECTOR = 11_344_663_589_394_136_015;
    uint64 internal constant BSC_TESTNET_SELECTOR = 13_264_668_187_771_770_619;

    address internal constant ON_ETH_MAINNET = 0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d;
    address internal constant ON_BSC_MAINNET = 0x0e4F6209eD984b21EDEA43acE6e09559eD051D48;

    function getConfig(uint256 chainId) internal pure returns (NetworkConfig memory cfg) {
        if (chainId == 1) {
            // ── Ethereum Mainnet ── FILL IN from https://docs.chain.link/ccip/directory
            cfg = NetworkConfig({
                chainSelector: ETH_MAINNET_SELECTOR,
                router: address(0),
                rmnProxy: address(0),
                tokenAdminRegistry: address(0),
                registryModuleOwnerCustom: address(0),
                linkToken: address(0),
                onToken: ON_ETH_MAINNET
            });
        } else if (chainId == 11_155_111) {
            // ── Sepolia ── FILL IN from https://docs.chain.link/ccip/directory
            cfg = NetworkConfig({
                chainSelector: SEPOLIA_SELECTOR,
                router: address(0),
                rmnProxy: address(0),
                tokenAdminRegistry: address(0),
                registryModuleOwnerCustom: address(0),
                linkToken: address(0),
                onToken: address(0) // no canonical ON on Sepolia — deploy a mock for testing
            });
        } else if (chainId == 56) {
            // ── BSC Mainnet ── FILL IN from https://docs.chain.link/ccip/directory
            cfg = NetworkConfig({
                chainSelector: BSC_MAINNET_SELECTOR,
                router: address(0),
                rmnProxy: address(0),
                tokenAdminRegistry: address(0),
                registryModuleOwnerCustom: address(0),
                linkToken: address(0),
                onToken: ON_BSC_MAINNET
            });
        } else if (chainId == 97) {
            // ── BSC Testnet ── FILL IN from https://docs.chain.link/ccip/directory
            cfg = NetworkConfig({
                chainSelector: BSC_TESTNET_SELECTOR,
                router: address(0),
                rmnProxy: address(0),
                tokenAdminRegistry: address(0),
                registryModuleOwnerCustom: address(0),
                linkToken: address(0),
                onToken: address(0) // no canonical ON on BSC testnet — deploy a mock for testing
            });
        } else {
            revert UnsupportedChain(chainId);
        }
    }

    function _requireSet(address a, string memory what) internal pure {
        if (a == address(0)) revert MissingAddress(what);
    }
}
