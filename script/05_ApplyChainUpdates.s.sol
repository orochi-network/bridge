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
///   inbound : capacity = 100_000 ON, rate = 10 ON/sec  (~864,000 ON / day)
///   outbound: capacity =  80_000 ON, rate =  8 ON/sec
///
/// Re-tune per direction via `setChainRateLimiterConfig` on the pool after launch (script 07).
///
/// SECURITY: CCIP-2 + CCIP-3 — directional rate-limit design (#61):
///   - Per Chainlink, Token Pool Rate Limits are STRONGLY RECOMMENDED on all lanes, and inbound
///     and outbound are configured SEPARATELY so risk can be tuned asymmetrically by direction.
///     Chainlink's concrete heuristic: "outbound limits are often configured to be slightly lower
///     than inbound limits to provide buffer room and reduce the risk of in-flight congestion."
///     We adopt that here — outbound (80k/8) is set below inbound (100k/10) on BOTH pools.
///     Refs: https://docs.chain.link/ccip/concepts/rate-limit-management/how-rate-limits-work
///           https://docs.chain.link/ccip/concepts/rate-limit-management/overview
///   - Chainlink prescribes NO specific numbers — calibrate to liquidity/risk. The bridge is
///     directionally asymmetric: ETH-inbound (BSC->ETH mint) is bounded by the hard
///     `MAX_CCIP_MINTED = 100M` cap (stuck-mint mode — SECURITY CCIP-15); BSC-inbound
///     (ETH->BSC release) is bounded by the BSC pool's reserve LIQUIDITY (stuck-release — M2).
///     >>> BEFORE MAINNET BROADCAST: finalize BSC-inbound capacity/rate against the actual
///     >>> seeded BSC liquidity (M2 / CCIP-2). These constants are a deliberate, documented
///     >>> launch default, not a final calibration.
///   - Refill window: 100k cap : 10/sec = ~2.8h from zero (inbound); 80k : 8/sec is the same
///     ~2.8h ratio (outbound). A single user can saturate a bucket for that window. Reduce
///     capacity (or raise rate) if a tighter refill window is desired.
contract ApplyChainUpdates is Script, Helper {
    // Asymmetric defaults (#61): outbound slightly below inbound, per Chainlink's heuristic.
    // Same direction split is mirrored in script 09 (ReconcileRemotePool) — keep in lockstep.
    uint128 internal constant INBOUND_CAPACITY = 100_000 ether;
    uint128 internal constant INBOUND_RATE = 10 ether;
    uint128 internal constant OUTBOUND_CAPACITY = 80_000 ether;
    uint128 internal constant OUTBOUND_RATE = 8 ether;

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
                isEnabled: true, capacity: OUTBOUND_CAPACITY, rate: OUTBOUND_RATE
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: true, capacity: INBOUND_CAPACITY, rate: INBOUND_RATE
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
