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
///
/// SECURITY: CCIP-2 + CCIP-3 — design notes:
///   - Symmetric capacity/rate in both directions is intentional. The bridge is
///     directionally asymmetric (ETH has the hard `MAX_CCIP_MINTED = 100M` cap; BSC has
///     no equivalent wON-side cap), but ETH-inbound is the side the cap already protects,
///     so symmetric rate limits keep the operator surface predictable. Confirm before
///     mainnet broadcast — if you want ETH-inbound throttled tighter than BSC-outbound,
///     adjust these constants before running script 05.
///   - The 100k cap : 10/sec rate ratio = ~2.8h to refill from zero. A single user can
///     saturate the bucket for that window. Reduce capacity (or raise rate) if a tighter
///     refill window is desired.
contract ApplyChainUpdates is Script, Helper {
    uint128 internal constant DEFAULT_CAPACITY = 100_000 ether;
    uint128 internal constant DEFAULT_RATE = 10 ether;

    function run() external {
        NetworkConfig memory remote = _remoteConfig(block.chainid);

        // Use `tryReadAddress` so a missing `deployments/<chainId>.json` (e.g. first-ever
        // run of `make deploy-eth` before `make deploy-bsc` has populated the remote
        // artifact) surfaces with the friendly `_requireSet` diagnostic below instead of a
        // low-level `vm.readFile` revert. Round-7 review [1].
        address localPool = Deployments.tryReadAddress(block.chainid, "pool");
        address remotePool = Deployments.tryReadAddress(_remoteChainId(block.chainid), "pool");
        address remoteToken = _remoteTokenAddress(block.chainid, remote);

        _requireSet(localPool, "localPool (run script 02 on this chain first)");
        _requireSet(remotePool, "remotePool (run script 02 on the remote chain first)");
        _requireSet(remoteToken, "remoteToken");

        // Idempotency: `applyChainUpdates` reverts with `ChainAlreadyExists(remoteSelector)`
        // when the remote chain is already wired. Skip cleanly so a partial-broadcast retry
        // (e.g. script 02 succeeded, script 05 failed mid-way and is being re-run) doesn't
        // hard-fail the operator. The wiring itself is owner-only, so a no-op here is safe.
        if (TokenPool(localPool).isSupportedChain(remote.chainSelector)) {
            // Round-2 review [6]: detect stale wiring — a remote pool redeploy will leave
            // the local pool pointed at the old (dead) address until we re-wire. Revert
            // with a clear instruction rather than silently skipping.
            bytes memory wiredRemote = TokenPool(localPool).getRemotePool(remote.chainSelector);
            // `abi.encode(address)` produces exactly 32 bytes (left-padded), and the
            // pool's `getRemotePool` returns the same shape. Compare directly as bytes32
            // rather than hashing both sides — same intent, cheaper, and clearer about
            // the assumed shape (round-3 review [10]).
            require(
                wiredRemote.length == 32 && bytes32(wiredRemote) == bytes32(uint256(uint160(remotePool))),
                "stale remote pool wiring: local pool points at a different remotePool than deployments JSON. Owner must remove the chain via applyChainUpdates(removed) and re-run, or call setRemotePool directly."
            );
            console.log(
                "Pool %s already wired to remote selector %d - skipping (rate-limit changes are NOT applied here; use `make update-limits`)",
                localPool,
                remote.chainSelector
            );
            return;
        }

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

        console.log(
            "Linked pool %s (remote selector %d) -> remote pool %s", localPool, remote.chainSelector, remotePool
        );
    }

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

    function _remoteConfig(uint256 chainId) internal pure returns (NetworkConfig memory) {
        return getConfig(_remoteChainId(chainId));
    }

    /// @notice The "remote token" written into the pool config is the token bridged on the OTHER chain.
    ///         ETH-side pool points at the canonical ON on BSC; BSC-side pool points at wON on ETH.
    function _remoteTokenAddress(uint256 chainId, NetworkConfig memory remote) internal view returns (address) {
        uint256 remoteChainId = _remoteChainId(chainId);
        if (remoteChainId == 1 || remoteChainId == 11_155_111) {
            // tryReadAddress so a missing remote deployments file surfaces with our
            // `_requireSet(remoteToken, …)` diagnostic rather than vm.readFile reverting.
            return Deployments.tryReadAddress(remoteChainId, "wrappedON");
        }
        return remote.onToken;
    }
}
