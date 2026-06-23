// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";

import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

/// @notice Re-points an already-wired local pool's lane at a NEW remote pool AND/OR NEW remote
///         token — the reconcile step the redeploy flow was missing (#55).
///
/// Background. After `redeploy-eth.sh` (RUNBOOK §4.4 Step 1) replaces the ETH wON proxy + its
/// `BurnMintTokenPool`, the live BSC `LockReleaseTokenPool` still has its ETH lane wired to the
/// OLD ETH pool AND the OLD wON token. Script 05 cannot fix that:
///   - its `isSupportedChain == true` branch reverts on stale wiring (by design — it must not
///     silently skip), and re-running it just hits the same revert; and
///   - even bypassed, script 05 only ever calls `applyChainUpdates(empty, add)`, which the
///     protocol rejects with `ChainAlreadyExists` when the selector is already supported
///     (`TokenPool.applyChainUpdates`).
///
/// CCIP 1.6.1 has NO `setRemoteToken`: the remote *token* of an existing chain can only be
/// changed by removing and re-adding the chain. `addRemotePool`/`removeRemotePool` manage only
/// the remote *pool* set, not the token — so a redeploy (which changes BOTH the remote pool and
/// the remote token, because script 01 deploys a fresh wON proxy) cannot be reconciled with
/// them. The only correct primitive is the ATOMIC remove+add:
/// `applyChainUpdates([remoteSelector], [newConfig])`, which this script performs in one call.
///
/// SAFETY. Removing a chain wipes that chain's entire remote config: every remote-pool hash
/// (dropping inflight-message support from the old pool) and the rate-limiter token buckets.
/// This is correct for the redeploy case (RUNBOOK §4.4: the old ETH pool is dead — no holders,
/// no reserve, no inflight messages) but MUST NOT be run while messages from the old remote
/// pool are still in flight — they would be rejected after the remove. Confirm the old pool is
/// drained first.
///
/// IDEMPOTENT. If the local pool's lane already points at EXACTLY the desired remote pool (and
/// holds no other remote pool for the selector) and the desired remote token, this is a clean
/// no-op (no broadcast), so a partial-broadcast retry is safe.
///
/// USAGE (mirror of script 05 — chain-dispatched on `block.chainid`):
///   forge script script/09_ReconcileRemotePool.s.sol --rpc-url bsc --broadcast --account deployer
///   make reconcile-remote-pool RPC=bsc
contract ReconcileRemotePool is Script, Helper {
    // Same defaults as script 05; the atomic remove+add resets the rate-limiter buckets, so they
    // must be re-supplied here. Keep in lockstep with `05_ApplyChainUpdates`.
    uint128 internal constant DEFAULT_CAPACITY = 100_000 ether;
    uint128 internal constant DEFAULT_RATE = 10 ether;

    /// @notice What `run()` will do for a given lane. Exposed (via `planAction`) so the decision
    ///         logic is unit-testable without a broadcast.
    enum Action {
        ChainNotWired, // lane absent — this would be a first-time add: run script 05 instead
        AlreadyReconciled, // lane already points at the desired pool+token — no-op
        Reconcile // lane stale (pool and/or token differ, or extra pools present) — remove+add
    }

    /// @notice The lane is not wired yet — reconcile RE-POINTS an existing lane. Run script 05
    ///         to add the lane for the first time.
    error ChainNotWired(uint64 remoteSelector);

    function run() external {
        NetworkConfig memory remote = getConfig(_remoteChainId(block.chainid));
        uint64 remoteSelector = remote.chainSelector;

        // `tryReadAddress` so a missing `deployments/<chainId>.json` surfaces with the friendly
        // `_requireSet` diagnostic below instead of a low-level `vm.readFile` revert (mirrors 05).
        address localPool = Deployments.tryReadAddress(block.chainid, "pool");
        address remotePool = Deployments.tryReadAddress(_remoteChainId(block.chainid), "pool");
        address remoteToken = _remoteTokenAddress(block.chainid, remote);

        _requireSet(localPool, "localPool (run script 02 on this chain first)");
        _requireSet(remotePool, "remotePool (redeploy the remote chain first)");
        _requireSet(remoteToken, "remoteToken");

        TokenPool pool = TokenPool(localPool);

        Action action = planAction(pool, remoteSelector, remotePool, remoteToken);
        if (action == Action.ChainNotWired) {
            // Reconcile RE-POINTS an existing lane; a missing lane is a first-time add.
            revert ChainNotWired(remoteSelector);
        }
        if (action == Action.AlreadyReconciled) {
            // Idempotent: re-run safe, no broadcast.
            console.log(
                "Pool %s lane to selector %d already points at the desired remote pool/token - skipping",
                localPool,
                remoteSelector
            );
            return;
        }

        (uint64[] memory toRemove, TokenPool.ChainUpdate[] memory updates) =
            buildUpdate(remoteSelector, remotePool, remoteToken);

        vm.startBroadcast();
        // Atomic remove+add: drop the stale lane (old pool + old token) and re-add the new one.
        // `applyChainUpdates` processes removals before additions, so removing then re-adding the
        // same selector in one call succeeds (`ChainAlreadyExists` only fires if NOT removed).
        pool.applyChainUpdates(toRemove, updates);
        vm.stopBroadcast();

        // Post-assert the new wiring landed (mirror script 08's verify posture).
        require(
            planAction(pool, remoteSelector, remotePool, remoteToken) == Action.AlreadyReconciled,
            "reconcile: post-update wiring mismatch"
        );

        console.log("Reconciled pool %s lane (selector %d) -> remote pool %s", localPool, remoteSelector, remotePool);
        console.log("  remote token -> %s", remoteToken);
    }

    /// @notice Decide what `run()` would do for `pool`'s lane to `remoteSelector`, given the
    ///         desired `remotePool`/`remoteToken`. Pure view — the testable heart of the script.
    function planAction(TokenPool pool, uint64 remoteSelector, address remotePool, address remoteToken)
        public
        view
        returns (Action)
    {
        if (!pool.isSupportedChain(remoteSelector)) return Action.ChainNotWired;
        if (_laneMatches(pool, remoteSelector, remotePool, remoteToken)) return Action.AlreadyReconciled;
        return Action.Reconcile;
    }

    /// @notice Build the atomic remove+add payload script `run()` broadcasts: remove the lane
    ///         (wiping the stale pool + token), re-add it with the desired pool, token, and the
    ///         default rate limits. Exposed so tests can apply the EXACT payload `run()` uses.
    function buildUpdate(uint64 remoteSelector, address remotePool, address remoteToken)
        public
        pure
        returns (uint64[] memory toRemove, TokenPool.ChainUpdate[] memory updates)
    {
        toRemove = new uint64[](1);
        toRemove[0] = remoteSelector;

        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(remotePool);
        updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteSelector,
            remotePoolAddresses: remotePoolAddresses,
            remoteTokenAddress: abi.encode(remoteToken),
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: true, capacity: DEFAULT_CAPACITY, rate: DEFAULT_RATE
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: true, capacity: DEFAULT_CAPACITY, rate: DEFAULT_RATE
            })
        });
    }

    /// @dev True iff the lane points at EXACTLY `remotePool` (no other remote pool present) AND
    ///      the remote token equals `remoteToken`. Requiring a single pool ensures a redeploy
    ///      that left the old pool behind is still treated as needing reconcile.
    ///      `abi.encode(address)` and `getRemoteToken()` are both 32-byte left-padded encodings,
    ///      so compare as `bytes32` rather than hashing — same intent, cheaper (mirrors 05).
    function _laneMatches(TokenPool pool, uint64 remoteSelector, address remotePool, address remoteToken)
        internal
        view
        returns (bool)
    {
        bytes[] memory pools = pool.getRemotePools(remoteSelector);
        if (pools.length != 1) return false;
        if (!(pools[0].length == 32 && bytes32(pools[0]) == bytes32(uint256(uint160(remotePool))))) {
            return false;
        }
        bytes memory tokenBytes = pool.getRemoteToken(remoteSelector);
        return tokenBytes.length == 32 && bytes32(tokenBytes) == bytes32(uint256(uint160(remoteToken)));
    }

    /// @notice Same remote-token resolution as script 05: the token bridged on the OTHER chain.
    ///         ETH-side pool points at the canonical ON on BSC; BSC-side pool points at wON on ETH.
    function _remoteTokenAddress(uint256 chainId, NetworkConfig memory remote) internal view returns (address) {
        uint256 remoteChainId = _remoteChainId(chainId);
        if (remoteChainId == 1 || remoteChainId == 11_155_111) {
            return Deployments.tryReadAddress(remoteChainId, "wrappedON");
        }
        return remote.onToken;
    }
}
