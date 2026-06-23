// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Per-chain CCIP infrastructure config.
///
/// Address fields are populated from the public Chainlink CCIP directory (the same data the
/// `smartcontractkit/documentation` config renders). **Re-verify against the live chain before
/// any broadcast** with `make validate-config RPC=<target-chain rpc>`, which staticcalls each
/// address and checks `typeAndVersion()` / `isChainSupported()`. The deployment scripts also call
/// `_requireSet(...)` on every address they read, so any unset field fails fast with a clear
/// `MissingAddress` error.
///
///   Directory: https://docs.chain.link/ccip/directory
///   Expected on-chain versions: Router 1.2.0, ARMProxy 1.0.0, TokenAdminRegistry 1.5.0,
///   RegistryModuleOwnerCustom 1.6.0.
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
            // ── Ethereum Mainnet ── from https://docs.chain.link/ccip/directory (re-verify: make validate-config)
            cfg = NetworkConfig({
                chainSelector: ETH_MAINNET_SELECTOR,
                router: 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D,
                rmnProxy: 0x411dE17f12D1A34ecC7F45f49844626267c75e81,
                tokenAdminRegistry: 0xb22764f98dD05c789929716D677382Df22C05Cb6,
                registryModuleOwnerCustom: 0x4855174E9479E211337832E109E7721d43A4CA64,
                linkToken: 0x514910771AF9Ca656af840dff83E8264EcF986CA,
                onToken: ON_ETH_MAINNET
            });
        } else if (chainId == 11_155_111) {
            // ── Sepolia ── from https://docs.chain.link/ccip/directory (re-verify: make validate-config)
            cfg = NetworkConfig({
                chainSelector: SEPOLIA_SELECTOR,
                router: 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59,
                rmnProxy: 0xba3f6251de62dED61Ff98590cB2fDf6871FbB991,
                tokenAdminRegistry: 0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82,
                registryModuleOwnerCustom: 0xa3c796d480638d7476792230da1E2ADa86e031b0,
                linkToken: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
                onToken: address(0) // no canonical ON on Sepolia — deploy a mock for testing
            });
        } else if (chainId == 56) {
            // ── BSC Mainnet ── from https://docs.chain.link/ccip/directory (re-verify: make validate-config)
            cfg = NetworkConfig({
                chainSelector: BSC_MAINNET_SELECTOR,
                router: 0x34B03Cb9086d7D758AC55af71584F81A598759FE,
                rmnProxy: 0x9e09697842194f77d315E0907F1Bda77922e8f84,
                tokenAdminRegistry: 0x736Fd8660c443547a85e4Eaf70A49C1b7Bb008fc,
                registryModuleOwnerCustom: 0x47Db76c9c97F4bcFd54D8872FDb848Cab696092d,
                linkToken: 0x404460C6A5EdE2D891e8297795264fDe62ADBB75,
                onToken: ON_BSC_MAINNET
            });
        } else if (chainId == 97) {
            // ── BSC Testnet ── from https://docs.chain.link/ccip/directory (re-verify: make validate-config)
            cfg = NetworkConfig({
                chainSelector: BSC_TESTNET_SELECTOR,
                router: 0xE1053aE1857476f36A3C62580FF9b016E8EE8F6f,
                rmnProxy: 0xA8C0c11bf64AF62CDCA6f93D3769B88BdD7cb93D,
                tokenAdminRegistry: 0xF8f2A4466039Ac8adf9944fD67DBb3bb13888f2B,
                registryModuleOwnerCustom: 0x8Cd87FeAC14D69D770E67Bedf029e6fd3F33D0C7,
                linkToken: 0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06,
                onToken: address(0) // no canonical ON on BSC testnet — deploy a mock for testing
            });
        } else {
            revert UnsupportedChain(chainId);
        }
    }

    function _requireSet(address a, string memory what) internal pure {
        if (a == address(0)) {
            revert MissingAddress(what);
        }
    }

    /// @notice True if `s` begins with `prefix`. Shared by the scripts that do CCIP
    ///         `typeAndVersion()` identity checks (`ValidateConfig`, `03_GrantRoles`) so a
    ///         contract's patch-version suffix can drift across submodule bumps without a
    ///         source edit — the check anchors on the immutable TYPE name, not the version.
    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(prefix);
        if (sb.length < pb.length) return false;
        for (uint256 i = 0; i < pb.length; i++) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }

    /// @notice Chain id of the CCIP counterpart (ETH <-> BSC, Sepolia <-> BSC testnet).
    /// @dev Shared by the deploy/ops scripts that wire or verify the remote side. Reverts
    ///      `UnsupportedChain` for any chain the bridge is not configured for.
    function _remoteChainId(uint256 chainId) internal pure returns (uint256) {
        if (chainId == 1) {
            return 56;
        }
        if (chainId == 56) {
            return 1;
        }
        if (chainId == 11_155_111) {
            return 97;
        }
        if (chainId == 97) {
            return 11_155_111;
        }
        revert UnsupportedChain(chainId);
    }

    /// @notice CCIP chain *selector* of the remote counterpart. Pairs with `_remoteChainId`.
    function _remoteSelector(uint256 chainId) internal pure returns (uint64) {
        if (chainId == 1) {
            return BSC_MAINNET_SELECTOR;
        }
        if (chainId == 56) {
            return ETH_MAINNET_SELECTOR;
        }
        if (chainId == 11_155_111) {
            return BSC_TESTNET_SELECTOR;
        }
        if (chainId == 97) {
            return SEPOLIA_SELECTOR;
        }
        revert UnsupportedChain(chainId);
    }
}
