// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { RateLimiter } from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";

/**
 * @title WrappedON (wON)
 * @notice Ethereum-side mintable representation of ON, with optional 1:1 swap to a
 *         pre-existing non-mintable ON contract held in this contract's reserve.
 *
 * @dev Inbound (BSC -> ETH) credit semantics:
 *      - Plain message + reserve >= amount: transfer real ON to the recipient. wON
 *        is NOT minted.
 *      - Plain message + reserve insufficient: mint wON (default OFT behaviour).
 *      - Composed message: ALWAYS mint wON, regardless of reserve. Compose handlers
 *        receive `amountReceivedLD` and assume it refers to the OFT (wON); auto-
 *        unwrapping would deliver real ON instead, leaving the compose handler
 *        manipulating a wON balance the recipient doesn't have.
 *
 *      The reserve is non-mintable. Sustained net BSC -> ETH flow drains it; refilling
 *      requires either bridging wON back to BSC or a treasury commitment via
 *      `seedReserve`. There is no autonomous refill mechanism.
 *
 *      Operator awareness:
 *      - `seedReserve` is a one-way subsidy. Donors do not receive wON, so they
 *        have no on-chain claim on the reserve they seeded.
 *      - A wON holder can front-run a pending inbound bridge via `unwrap` to drain
 *        the reserve, forcing the inbound recipient onto the wON fallback.
 *      - If the ON token is paused or blacklists the recipient, the auto-unwrap
 *        branch reverts inside `_credit`, making the LayerZero message
 *        undeliverable until the lock lifts.
 *
 *      Outbound rate limiting (LayerZero `RateLimiter` extension) is applied
 *      per destination EID in `_debit`. Inbound is intentionally NOT rate
 *      limited: an inbound message is the tail of an already-sent outbound, so
 *      throttling it cannot prevent the source-chain debit and only adds a way
 *      to brick LayerZero delivery. Operators dial limits via `setRateLimits`
 *      (owner-only). Unconfigured EIDs are unlimited — see `_outflowOrSkip`.
 */
contract WrappedON is OFT, RateLimiter {
    using SafeERC20 for IERC20;
    using OFTMsgCodec for bytes;

    /// @notice Pre-existing, non-mintable ON ERC20 used as the reserve asset.
    IERC20 public immutable ON;

    /// @dev Set in `_lzReceive` so that `_credit` (called by `super._lzReceive`)
    ///      can route composed messages to the mint path without re-implementing
    ///      the upstream lzReceive logic. EIP-1153 transient storage: the slot
    ///      is auto-cleared at end-of-transaction, so no manual reset is needed
    ///      and the value cannot leak across messages. Not exposed externally.
    bool private transient _composedFlag;

    event AutoUnwrap(address indexed to, uint256 amount);
    event UnwrapFallbackToMint(address indexed to, uint256 amount);
    event Wrap(address indexed from, uint256 amount);
    event Unwrap(address indexed from, uint256 amount);
    event ReserveSeeded(address indexed from, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();
    error SelfReserve();
    error DecimalsMismatch(uint8 actual);
    error ReserveInsufficient(uint256 requested, uint256 available);
    error UnexpectedTransferAmount(uint256 expected, uint256 received);
    error InvalidRateLimitConfig(uint32 dstEid);

    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate,
        address _onToken
    ) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) {
        if (_onToken == address(0)) revert ZeroAddress();
        if (_onToken == address(this)) revert SelfReserve();
        // wON is 18 decimals (OFT default). 1:1 swap requires the reserve token to match.
        uint8 onDecimals = IERC20Metadata(_onToken).decimals();
        if (onDecimals != 18) revert DecimalsMismatch(onDecimals);
        ON = IERC20(_onToken);
    }

    /// @notice Real ON held by this contract — the fungible reserve drained by
    ///         auto-unwrap and unwrap, topped up by wrap, seedReserve, or any
    ///         direct ERC20 transfer of ON to this address.
    function reserve() external view returns (uint256) {
        return ON.balanceOf(address(this));
    }

    /// @notice Owner-only: set per-destination outbound rate limits. See
    ///         `RateLimiter.RateLimitConfig` for the struct layout.
    /// @dev    Existing `amountInFlight` and `lastUpdated` are PRESERVED
    ///         across a reconfigure (upstream `_setRateLimits` checkpoints
    ///         decay at the old rate first).
    /// @dev    Rejects the silent-disable shape `(limit > 0, window = 0)`.
    ///         Upstream `_amountCanBeSent` substitutes `window = 1` to avoid
    ///         div-by-zero, which makes the decay rate `limit` units per
    ///         second — the bucket effectively refills every block while
    ///         `getAmountCanBeSent` reports a healthy "configured" view, so
    ///         a fat-finger in multisig calldata can silently disable
    ///         enforcement. The all-zero `(0, 0)` sentinel remains valid and
    ///         is the explicit "disabled / unconfigured" marker.
    function setRateLimits(RateLimitConfig[] calldata _rateLimitConfigs) external onlyOwner {
        for (uint256 i = 0; i < _rateLimitConfigs.length; i++) {
            RateLimitConfig calldata cfg = _rateLimitConfigs[i];
            if (cfg.window == 0 && cfg.limit != 0) revert InvalidRateLimitConfig(cfg.dstEid);
        }
        _setRateLimits(_rateLimitConfigs);
    }

    /// @notice Owner-only: zero out `amountInFlight` for the given EIDs.
    ///         Use sparingly; discards the running window's accounting.
    function resetRateLimits(uint32[] calldata _eids) external onlyOwner {
        _resetRateLimits(_eids);
    }

    /// @notice Burn `_amount` wON, receive `_amount` real ON 1:1. Reverts if the
    ///         reserve cannot cover the request.
    function unwrap(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        uint256 available = ON.balanceOf(address(this));
        if (available < _amount) revert ReserveInsufficient(_amount, available);
        _burn(msg.sender, _amount);
        ON.safeTransfer(msg.sender, _amount);
        emit Unwrap(msg.sender, _amount);
    }

    /// @notice Deposit `_amount` real ON, receive an equal amount of wON. Caller
    ///         must approve(this, _amount) on the ON token first.
    /// @dev    The amount minted is the actual delta in this contract's ON balance
    ///         across the transfer, not the requested amount, to defend against
    ///         fee-on-transfer behaviour in the reserve token.
    function wrap(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        uint256 balanceBefore = ON.balanceOf(address(this));
        ON.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 received = ON.balanceOf(address(this)) - balanceBefore;
        if (received != _amount) revert UnexpectedTransferAmount(_amount, received);
        _mint(msg.sender, received);
        emit Wrap(msg.sender, received);
    }

    /// @notice Donate real ON to the reserve without minting wON.
    /// @dev    One-way subsidy. The donor receives no wON in return and has no
    ///         on-chain claim on the seeded liquidity — once seeded, the funds
    ///         can be paid out via auto-unwrap or `unwrap` to any wON holder.
    ///         Functionally equivalent to a direct ERC20 transfer to this
    ///         contract; this wrapper just emits an event for off-chain
    ///         accounting.
    function seedReserve(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        uint256 balanceBefore = ON.balanceOf(address(this));
        ON.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 received = ON.balanceOf(address(this)) - balanceBefore;
        if (received != _amount) revert UnexpectedTransferAmount(_amount, received);
        emit ReserveSeeded(msg.sender, received);
    }

    /// @dev Override of OFT's default `_debit`. Only addition vs. base is the
    ///      pre-burn rate-limit check via `_outflowOrSkip`; the burn itself is
    ///      issued inline via `_burn` (the base `_debit` is not called — the
    ///      OZ ERC20 `_burn` and the upstream `OFT._debit` body are the same
    ///      operation, so reproducing it inline keeps the override readable
    ///      without a redundant `super._debit` round trip).
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);
        _outflowOrSkip(_dstEid, amountSentLD);
        _burn(_from, amountSentLD);
    }

    /// @dev Override of OFTCore._lzReceive. Sets a per-message transient flag
    ///      the `_credit` override consults to force the mint path on composed
    ///      messages, then delegates to super so the upstream compose dispatch
    ///      and `OFTReceived` emission remain a single source of truth.
    ///      Transient storage auto-clears at end-of-transaction, so no manual
    ///      reset is needed.
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal virtual override {
        _composedFlag = _message.isComposed();
        super._lzReceive(_origin, _guid, _message, _executor, _extraData);
    }

    /// @dev Override of OFT's default `_credit` (which always mints). Branches:
    ///      - Recipient is `address(0)` or `address(this)`: redirect to `0xdead`
    ///        and force the mint path. Sending real reserve to either is either
    ///        a permanent burn (`0xdead`) or a free `seedReserve` paid by the
    ///        BSC sender (`address(this)`); minting wON instead keeps the
    ///        stranded amount visible in `totalSupply` and avoids leaking
    ///        reserve.
    ///      - Composed message (`_composedFlag` set): always mint wON. The compose
    ///        handler downstream operates on `amountReceivedLD` assuming it was
    ///        credited as wON; auto-unwrapping would deliver real ON instead.
    ///      - Plain message + reserve covers the request: transfer real ON, no
    ///        wON minted. Pre/post balance-delta-checks on both sides defend
    ///        against fee-on-transfer or rebasing on the reserve token; on
    ///        mismatch the call reverts and the LZ message becomes retryable.
    ///      - Plain message + reserve insufficient: mint wON (recipient can later
    ///        `unwrap` once the reserve is refilled).
    ///      Single payout per message — never split.
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /*_srcEid*/
    ) internal virtual override returns (uint256 amountReceivedLD) {
        bool rerouted = false;
        if (_to == address(0x0) || _to == address(this)) {
            _to = address(0xdead);
            rerouted = true;
        }

        if (_composedFlag || rerouted) {
            _mint(_to, _amountLD);
            if (rerouted && !_composedFlag) emit UnwrapFallbackToMint(_to, _amountLD);
            return _amountLD;
        }

        uint256 reserveBefore = ON.balanceOf(address(this));
        if (reserveBefore >= _amountLD) {
            uint256 toBefore = ON.balanceOf(_to);
            ON.safeTransfer(_to, _amountLD);
            uint256 received = ON.balanceOf(_to) - toBefore;
            uint256 spent = reserveBefore - ON.balanceOf(address(this));
            if (received != _amountLD || spent != _amountLD) {
                revert UnexpectedTransferAmount(_amountLD, received);
            }
            emit AutoUnwrap(_to, _amountLD);
        } else {
            _mint(_to, _amountLD);
            emit UnwrapFallbackToMint(_to, _amountLD);
        }
        return _amountLD;
    }

    /// @dev RateLimiter._outflow rejects every send for any EID where both
    ///      `limit` and `window` are zero (`amountCanBeSent == 0`), which is
    ///      the storage default for an unconfigured EID. Treat that combo as
    ///      "disabled" so a freshly-deployed contract remains usable until
    ///      the multisig dials in production limits via `setRateLimits`.
    ///      Setting either field non-zero opts that EID into enforcement.
    function _outflowOrSkip(uint32 _dstEid, uint256 _amount) internal {
        RateLimit storage rl = rateLimits[_dstEid];
        if (rl.limit == 0 && rl.window == 0) return;
        _outflow(_dstEid, _amount);
    }
}
