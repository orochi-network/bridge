// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {TokenPool} from "@chainlink/contracts-ccip/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/ccip/libraries/RateLimiter.sol";

import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

/// @notice Wires each pool to its remote counterpart with rate limits.
///
/// Initial limits (calibrate from production traffic):
///   capacity = 100_000 ON   (~$X TODO depending on price)
///   rate     = 10 ON/sec    (~864,000 ON / day)
///
/// Re-tune via `setChainRateLimiterConfig` on the pool after launch.
contract ApplyChainUpdates is Script, Helper {
    uint128 internal constant DEFAULT_CAPACITY = 100_000 ether;
    uint128 internal constant DEFAULT_RATE = 10 ether;

    function run() external {
        NetworkConfig memory local = getConfig(block.chainid);
        NetworkConfig memory remote = _remoteConfig(block.chainid);

        address localPool = Deployments.readAddress(block.chainid, "pool");
        address remotePool = Deployments.readAddress(_remoteChainId(block.chainid), "pool");
        address remoteToken = _remoteTokenAddress(block.chainid, remote);

        TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remote.chainSelector,
            allowed: true,
            remotePoolAddress: abi.encode(remotePool),
            remoteTokenAddress: abi.encode(remoteToken),
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: true, capacity: DEFAULT_CAPACITY, rate: DEFAULT_RATE
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: true, capacity: DEFAULT_CAPACITY, rate: DEFAULT_RATE
            })
        });

        vm.startBroadcast();
        TokenPool(localPool).applyChainUpdates(updates);
        vm.stopBroadcast();

        console.log("Linked pool %s (selector %d) -> remote pool %s", localPool, local.chainSelector, remotePool);
    }

    function _remoteChainId(uint256 chainId) internal pure returns (uint256) {
        if (chainId == 1) return 56;
        if (chainId == 56) return 1;
        if (chainId == 11_155_111) return 97;
        if (chainId == 97) return 11_155_111;
        revert UnsupportedChain(chainId);
    }

    function _remoteConfig(uint256 chainId) internal pure returns (NetworkConfig memory) {
        return getConfig(_remoteChainId(chainId));
    }

    /// @notice The "remote token" written into the pool config is the token bridged on the OTHER chain.
    ///         ETH-side pool points at the canonical ON on BSC; BSC-side pool points at wON on ETH.
    function _remoteTokenAddress(uint256 chainId, NetworkConfig memory remote) internal view returns (address) {
        uint256 remoteChainId = _remoteChainId(chainId);
        if (remoteChainId == 1 || remoteChainId == 11_155_111) {
            return Deployments.readAddress(remoteChainId, "wrappedON");
        }
        return remote.onToken;
    }
}
