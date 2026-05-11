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
 *         LayerZero V2 OFT mesh. Diverges from the upstream `OFTAdapter`
 *         template in three places:
 *
 *         1. `_debit` is overridden with a balance-delta check so the adapter
 *            cannot silently misreport `amountSentLD` to LayerZero if the
 *            inner ON token ever ships fee-on-transfer or rebasing semantics.
 *
 *         2. `_credit` is overridden to reject bad recipient addresses
 *            (`address(0)` and `address(this)`) with `BadRecipient`, matching
 *            the same hardening present in WrappedON on the Ethereum side.
 *
 *         3. The LayerZero `RateLimiter` extension is mixed in and `_debit`
 *            consults it on every outbound send. See `_outflowOrSkip` for the
 *            "unconfigured == fail-open" semantics that keep the contract
 *            usable before the multisig has dialled in production limits,
 *            and the WARNING there explaining why `(0, 0)` is fail-open
 *            rather than pause.
 *
 * @dev    The default `OFTAdapter` implementation assumes lossless transfers
 *         on the inner token. ON on BSC is lossless today (verified by the
 *         forked-mainnet dry-run), but a future migration or upgrade of the
 *         ON contract could change that. Without the delta check, a single
 *         FoT activation would credit the full pre-fee amount on Ethereum
 *         while the adapter held less, breaking the bridge's conservation
 *         invariant. The override reverts the send instead of letting it
 *         under-collateralise the bridge.
 *
 * @dev    The base `OFTAdapter._credit` does not guard against bad
 *         recipients. Bridging ETH→BSC with `_to = address(0)` would revert
 *         inside `safeTransfer` (standard ERC20 rejects zero-address
 *         receivers), making the LayerZero message undeliverable. Bridging
 *         with `_to = address(this)` results in a self-transfer no-op,
 *         silently burning the recipient's funds while marking the message
 *         delivered. The override rejects both with an explicit
 *         `BadRecipient` revert so the failure is loud and visible (the
 *         self-recipient silent-loss case in particular would otherwise be
 *         indistinguishable from a successful delivery); the message stays
 *         in retryable-pending state with no ON unlocked.
 *
 * @dev    Rate limiting is applied to OUTBOUND sends only, per destination
 *         EID. Inbound (`_credit`) is intentionally NOT rate-limited: an
 *         inbound message is the tail of an already-sent outbound, so
 *         throttling it cannot prevent the source-chain debit and only adds
 *         a way to brick LayerZero delivery (the message becomes permanently
 *         stuck when the cap is hit). Outflow-only matches the LayerZero
 *         OFT quickstart pattern and is sufficient to bound drain risk per
 *         direction.
 *
 * @dev    WARNING: ONLY 1 OFTAdapter should exist for a given global mesh.
 */
contract ONOFTAdapter is OFTAdapter, RateLimiter {
    using SafeERC20 for IERC20;

    error UnexpectedTransferAmount(uint256 expected, uint256 received);
    error InvalidRateLimitConfig(uint32 dstEid);
    /// @notice Inbound message addressed to `address(0)` or `address(this)`.
    ///         The bridge no longer attempts to recover such messages by
    ///         redirecting to `0xdead`: a silent redirect would either
    ///         deliver real ON to `0xdead` (permanent burn) or strand a
    ///         composed message at a recipient that cannot execute it
    ///         while OFTCore dispatches `sendCompose` to the original bad
    ///         address. Reverting keeps the LayerZero message in retryable-
    ///         pending state with no ON unlocked from the adapter;
    ///         conservation accounting is not made worse.
    error BadRecipient(address recipient);

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
    function setRateLimits(RateLimitConfig[] calldata _rateLimitConfigs) external onlyOwner {
        for (uint256 i = 0; i < _rateLimitConfigs.length; i++) {
            RateLimitConfig calldata cfg = _rateLimitConfigs[i];
            if (cfg.window == 0 && cfg.limit != 0) revert InvalidRateLimitConfig(cfg.dstEid);
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

    /// @dev Override of OFTAdapter's default `_credit`. The base implementation
    ///      does not guard against bad recipient addresses:
    ///      - `address(0)`: `safeTransfer` to the zero address reverts on
    ///        standard ERC20s, making the inbound LayerZero message
    ///        undeliverable.
    ///      - `address(this)`: `safeTransfer` sends the unlocked ON back into
    ///        the adapter's own balance; the inbound LayerZero message is
    ///        marked delivered but the intended recipient receives nothing
    ///        (silent fund loss).
    ///
    ///      We reject both with an explicit `BadRecipient` revert rather than
    ///      silently rerouting to `0xdead`. The redirect approach had two
    ///      hazards: (1) for composed messages, OFTCore's `_lzReceive`
    ///      captures `toAddress` before invoking `_credit` and dispatches
    ///      `sendCompose` to the ORIGINAL value, so a `_credit`-level
    ///      redirect would unlock real ON to `0xdead` while the compose call
    ///      ended up stuck pending forever; (2) the redirect divergence from
    ///      upstream added behaviour that operators had to understand and
    ///      monitor. Reverting makes the LayerZero message stay in
    ///      retryable-pending state with no ON unlocked. The bad recipient
    ///      is in the immutable LZ payload, so a retry will hit the same
    ///      revert — operators must detect the stuck message off-chain.
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) internal virtual override returns (uint256 amountReceivedLD) {
        if (_to == address(0) || _to == address(this)) revert BadRecipient(_to);
        return super._credit(_to, _amountLD, _srcEid);
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
