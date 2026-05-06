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
 *         2. `_credit` is overridden to redirect bad recipient addresses
 *            (`address(0)` and `address(this)`) to `address(0xdead)`, matching
 *            the same hardening present in WrappedON on the Ethereum side.
 *
 *         3. The LayerZero `RateLimiter` extension is mixed in and `_debit`
 *            consults it on every outbound send. See `_outflowOrSkip` for the
 *            "unconfigured == disabled" semantics that keep the contract
 *            usable before the multisig has dialled in production limits.
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
 * @dev    The base `OFTAdapter._credit` does not redirect `address(0)` or
 *         `address(this)`. Bridging ETH→BSC with `_to = address(0)` would
 *         revert inside `safeTransfer` (standard ERC20 rejects zero-address
 *         receivers), making the LayerZero message undeliverable. Bridging
 *         with `_to = address(this)` results in a self-transfer no-op, silently
 *         burning the recipient's funds while marking the message delivered.
 *         Both are redirected to `address(0xdead)` so the message always
 *         delivers and any locked ON remains visible as a burn rather than
 *         silently stuck.
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
    function setRateLimits(RateLimitConfig[] calldata _rateLimitConfigs) external onlyOwner {
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
    ///        standard ERC20s, making the inbound LayerZero message undeliverable.
    ///      - `address(this)`: `safeTransfer` to the adapter itself is a no-op
    ///        self-transfer on standard ERC20s; the message is marked delivered
    ///        but the recipient receives nothing (silent fund loss).
    ///
    ///      Both are redirected to `address(0xdead)` so the message always
    ///      delivers. The locked ON is effectively burned, which is visible
    ///      on-chain and preferable to a stuck or silently-lost message.
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) internal virtual override returns (uint256 amountReceivedLD) {
        if (_to == address(0) || _to == address(this)) {
            _to = address(0xdead);
        }
        return super._credit(_to, _amountLD, _srcEid);
    }

    /// @dev RateLimiter._outflow rejects every send for any EID where both
    ///      `limit` and `window` are zero (`amountCanBeSent == 0`), which is
    ///      the storage default for an unconfigured EID. Treat that combo as
    ///      "disabled" so a freshly-deployed adapter remains usable until the
    ///      multisig dials in production limits via `setRateLimits`. Setting
    ///      either field non-zero opts that EID into enforcement.
    function _outflowOrSkip(uint32 _dstEid, uint256 _amount) internal {
        RateLimit storage rl = rateLimits[_dstEid];
        if (rl.limit == 0 && rl.window == 0) return;
        _outflow(_dstEid, _amount);
    }
}
