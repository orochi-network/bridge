// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import { RateLimiter } from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";

/**
 * @title ONOFTAdapter
 * @notice BSC-side adapter that locks/unlocks the canonical ON token for the
 *         LayerZero V2 OFT mesh.
 *
 * @dev    Diverges from upstream `OFTAdapter` in two places:
 *         1. `_debit` adds a balance-delta check to refuse fee-on-transfer /
 *            rebasing inner tokens (would otherwise under-collateralise the
 *            bridge — see `_debit` NatSpec).
 *         2. Mixes in the LayerZero `RateLimiter` extension, outbound-only.
 *            Inbound is intentionally not rate-limited — see `_outflowOrSkip`.
 *
 *         `_credit` is NOT overridden; inbound credit uses upstream
 *         `OFTAdapter._credit` verbatim (`innerToken.safeTransfer(_to, amt)`).
 *
 * @dev    WARNING: ONLY 1 OFTAdapter should exist for a given global mesh.
 */
contract ONOFTAdapter is OFTAdapter, RateLimiter {
    using SafeERC20 for IERC20;

    /// @notice Minimum permitted `window` (seconds) when configuring a non-zero
    ///         `limit`. Sub-block-time windows cause upstream `_amountCanBeSent`
    ///         to refill the bucket every block, silently bypassing
    ///         enforcement (see `setRateLimits` NatSpec).
    /// @dev    Single uniform value across both bridge sides, chosen against the
    ///         slower of the two chains. `ONOFTAdapter` is deployed on BSC
    ///         (~3s blocks → 20x margin); `WrappedON` is deployed on Ethereum
    ///         (~12s blocks → 5x margin). Per-side constants were considered
    ///         (see PR #13 discussion thread) and rejected because the 5x
    ///         floor on the slower side is still ample for the bridge's
    ///         expected production windows (typically >= 3600s), and a single
    ///         constant keeps the operator surface simpler — the floor is a
    ///         safety rail, not a recommended window.
    ///         `public` visibility exposes the getter to off-chain tooling
    ///         and to test boundary assertions that should never hard-code
    ///         the literal.
    uint64 public constant MIN_RATE_LIMIT_WINDOW = 60;

    error UnexpectedTransferAmount(uint256 expected, uint256 received);
    error InvalidRateLimitConfig(uint32 dstEid);

    constructor(
        address _token,
        address _lzEndpoint,
        address _delegate
    ) OFTAdapter(_token, _lzEndpoint, _delegate) Ownable(_delegate) {}

    /// @notice Owner-only: set per-destination outbound rate limits. See
    ///         `RateLimiter.RateLimitConfig` for the struct layout.
    /// @dev    Existing `amountInFlight` and `lastUpdated` are PRESERVED
    ///         across a reconfigure (upstream `_setRateLimits` checkpoints
    ///         decay at the old rate first), so tightening limits cannot be
    ///         used to retroactively wipe the running window.
    /// @dev    Rejects the silent-disable shape `(limit > 0, window = 0)`.
    ///         Upstream `_amountCanBeSent` substitutes `window = 1` to avoid
    ///         div-by-zero, which makes the decay rate `limit` units per
    ///         second — the bucket effectively refills every block while
    ///         `getAmountCanBeSent` reports a healthy "configured" view, so
    ///         a fat-finger in multisig calldata can silently disable
    ///         enforcement. The all-zero `(0, 0)` sentinel remains valid and
    ///         is the canonical "unconfigured / fail-open" marker (storage
    ///         zero-init and an explicit write-back-to-zero are
    ///         indistinguishable, by design — this is NOT a pause; see
    ///         `_outflowOrSkip` and the README "Pausing an EID" for the
    ///         deny-all idiom that halts flow on an EID).
    /// @dev    Also rejects `(limit > 0, 0 < window < MIN_RATE_LIMIT_WINDOW)`.
    ///         The upstream NatSpec on `RateLimiter` warns that any window
    ///         shorter than the destination chain's block time causes the
    ///         decay term to dominate `limit * blockTime` every block, so
    ///         enforcement effectively resets each block — the same failure
    ///         mode as the `window = 0` silent-disable shape, just reached by
    ///         a different fat-finger (e.g. `3600` typed as `1`, `0xE10` as
    ///         `0x10`). The deny-all pause idiom (`limit=1`,
    ///         `window=type(uint64).max`) is unaffected.
    function setRateLimits(RateLimitConfig[] calldata _rateLimitConfigs) external onlyOwner {
        for (uint256 i = 0; i < _rateLimitConfigs.length; i++) {
            RateLimitConfig calldata cfg = _rateLimitConfigs[i];
            if (cfg.limit != 0 && cfg.window < MIN_RATE_LIMIT_WINDOW) {
                revert InvalidRateLimitConfig(cfg.dstEid);
            }
        }
        _setRateLimits(_rateLimitConfigs);
    }

    /// @notice Owner-only: zero out `amountInFlight` for the given EIDs.
    ///         Use sparingly — typically only after a confirmed incident
    ///         response, since it discards the running window's accounting.
    function resetRateLimits(uint32[] calldata _eids) external onlyOwner {
        _resetRateLimits(_eids);
    }

    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        _outflowOrSkip(_dstEid, amountSentLD);

        uint256 balanceBefore = innerToken.balanceOf(address(this));
        innerToken.safeTransferFrom(_from, address(this), amountSentLD);
        uint256 received = innerToken.balanceOf(address(this)) - balanceBefore;
        if (received != amountSentLD) revert UnexpectedTransferAmount(amountSentLD, received);
    }

    /// @dev RateLimiter._outflow rejects every send for any EID where both
    ///      `limit` and `window` are zero (`amountCanBeSent == 0`), which is
    ///      the storage default for an unconfigured EID. Treat that combo as
    ///      "unconfigured / fail-open" so a freshly-deployed adapter remains
    ///      usable until the multisig dials in production limits via
    ///      `setRateLimits`. Setting either field non-zero opts that EID
    ///      into enforcement.
    ///
    ///      WARNING: this branch cannot distinguish "never configured" from
    ///      "operator wrote back to (0, 0)" — both have identical storage
    ///      and both fail-open. `setRateLimits([(eid, 0, 0)])` therefore
    ///      RETURNS the EID to the unenforced state; it does NOT pause it.
    ///      To halt outbound flow to an EID, write a deny-all config (e.g.
    ///      `limit=1, window=type(uint64).max`) — see README "Pausing an
    ///      EID". The validator in `setRateLimits` blocks the silent-disable
    ///      shape `(limit>0, window=0)` but explicitly allows `(0, 0)`,
    ///      which is the canonical "unconfigured / fail-open" sentinel.
    function _outflowOrSkip(uint32 _dstEid, uint256 _amount) internal {
        RateLimit storage rl = rateLimits[_dstEid];
        if (rl.limit == 0 && rl.window == 0) return;
        _outflow(_dstEid, _amount);
    }
}
