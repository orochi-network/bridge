// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";

import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

/// @notice Wires each pool to its remote counterpart with rate limits.
///
/// Initial limits (calibrate from production traffic):
///   capacity = 100_000 ON   (USD value tracks the ON price — calibrate before mainnet)
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
            // CCIP 1.6.1: a chain can hold MULTIPLE remote pools; `getRemotePools` returns
            // `bytes[]`. Treat the wiring as current if our expected remotePool is among them.
            // `abi.encode(address)` is exactly 32 bytes (left-padded), matching each entry's shape;
            // compare as bytes32 rather than hashing — same intent, cheaper (round-3 review [10]).
            bytes[] memory wiredRemotes = TokenPool(localPool).getRemotePools(remote.chainSelector);
            bool wired = false;
            for (uint256 i = 0; i < wiredRemotes.length; i++) {
                if (wiredRemotes[i].length == 32 && bytes32(wiredRemotes[i]) == bytes32(uint256(uint160(remotePool)))) {
                    wired = true;
                    break;
                }
            }
            // #55: script 05 only ADDS new lanes — it cannot re-point an existing one (the
            // protocol rejects a re-add with `ChainAlreadyExists`, and there is no `setRemoteToken`
            // to change the lane's remote token). When a remote redeploy leaves this lane stale,
            // reconcile it with script 09 (atomic `applyChainUpdates` remove+add), NOT by re-running
            // script 05 (which would just hit this revert again).
            require(
                wired,
                "stale remote pool wiring: this lane does not include the remotePool in deployments JSON (remote redeploy?). Reconcile with `make reconcile-remote-pool RPC=<chain>` (script 09); re-running script 05 will not help."
            );
            console.log(
                "Pool %s already wired to remote selector %d - skipping (rate-limit changes are NOT applied here; use `make update-limits`)",
                localPool,
                remote.chainSelector
            );
            return;
        }

        // CCIP 1.6.1: `ChainUpdate` drops `bool allowed` (removal is the separate
        // `applyChainUpdates` first arg) and takes `bytes[] remotePoolAddresses`.
        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(remotePool);
        TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remote.chainSelector,
            remotePoolAddresses: remotePoolAddresses,
            remoteTokenAddress: abi.encode(remoteToken),
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: true, capacity: DEFAULT_CAPACITY, rate: DEFAULT_RATE
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: true, capacity: DEFAULT_CAPACITY, rate: DEFAULT_RATE
            })
        });

        vm.startBroadcast();
        // First arg = chain selectors to REMOVE (none here); second = chains to add.
        TokenPool(localPool).applyChainUpdates(new uint64[](0), updates);
        vm.stopBroadcast();

        console.log(
            "Linked pool %s (remote selector %d) -> remote pool %s", localPool, remote.chainSelector, remotePool
        );
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
