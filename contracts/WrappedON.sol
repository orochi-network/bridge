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
 * @dev Inbound (BSC -> ETH) credit semantics, evaluated in order:
 *      - Recipient is `address(0)` or `address(this)`: redirect to `0xdead` and
 *        force the mint path. Sending the real reserve to either is a permanent
 *        burn or a free `seedReserve` paid by the BSC sender; minting wON
 *        instead keeps the stranded amount visible in `totalSupply`.
 *      - Composed message: ALWAYS mint wON, regardless of reserve. Compose handlers
 *        receive `amountReceivedLD` and assume it refers to the OFT (wON); auto-
 *        unwrapping would deliver real ON instead, leaving the compose handler
 *        manipulating a wON balance the recipient doesn't have.
 *      - Plain message + reserve >= amount: transfer real ON to the recipient. wON
 *        is NOT minted.
 *      - Plain message + reserve insufficient: mint wON (default OFT behaviour).
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
 *      (owner-only). Unconfigured EIDs (`limit==0 && window==0`) are
 *      fail-open — see the WARNING on `_outflowOrSkip`. To pause an EID use
 *      a deny-all config, NOT `(0, 0)`.
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
    /// @dev    Defends against fee-on-transfer or rebasing reserve tokens by
    ///         comparing the actual balance delta to `_amount` and reverting
    ///         with `UnexpectedTransferAmount` on mismatch. On success the
    ///         minted amount equals `_amount` exactly; the 1:1 wrap invariant
    ///         is preserved or the transaction reverts.
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
    ///         Carries the same fee-on-transfer balance-delta guard as `wrap`
    ///         and reverts with `UnexpectedTransferAmount` on mismatch, so it
    ///         is stricter than a raw ERC20 transfer (which would silently
    ///         accept a smaller amount). No wON is minted; the side effects
    ///         are the reserve top-up and the `ReserveSeeded` event.
    function seedReserve(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        uint256 balanceBefore = ON.balanceOf(address(this));
        ON.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 received = ON.balanceOf(address(this)) - balanceBefore;
        if (received != _amount) revert UnexpectedTransferAmount(_amount, received);
        emit ReserveSeeded(msg.sender, received);
    }

    /// @dev Override of OFT's default `_debit`. Only addition vs. base is the
    ///      pre-burn rate-limit check via `_outflowOrSkip`. We call
    ///      `_debitView` and `_burn` inline rather than `super._debit`,
    ///      because `super._debit` would re-invoke `_debitView` and we
    ///      already used its result for the rate-limit check.
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

    /// @dev Override of OFT's default `_credit` (which always mints). Branches,
    ///      evaluated in order:
    ///      - Recipient is `address(0)` or `address(this)`: redirect to `0xdead`
    ///        and force the mint path. Sending real reserve to either is either
    ///        a permanent burn (`0xdead`) or a free `seedReserve` paid by the
    ///        BSC sender (`address(this)`); minting wON instead keeps the
    ///        stranded amount visible in `totalSupply` and avoids leaking
    ///        reserve. Emits `UnwrapFallbackToMint` when not composed; in
    ///        the rare combined `0/this`+composed case the mint is silent
    ///        (no event) — the composed branch's contract holds the wON.
    ///      - Composed message (`_composedFlag` set): always mint wON. The compose
    ///        handler downstream operates on `amountReceivedLD` assuming it was
    ///        credited as wON; auto-unwrapping would deliver real ON instead.
    ///      - Plain message + reserve covers the request: transfer real ON, no
    ///        wON minted. Pre/post balance-delta-checks on both sides defend
    ///        against fee-on-transfer or rebasing on the reserve token; on
    ///        mismatch the call reverts with `UnexpectedTransferAmount`. The
    ///        LayerZero message stays retryable, but a retry will hit the same
    ///        revert until the upstream cause (FoT activation, ON-token pause,
    ///        recipient blacklist) clears or the reserve is drawn down below
    ///        `_amountLD` so the fallback-mint branch fires. Emits `AutoUnwrap`.
    ///      - Plain message + reserve insufficient: mint wON (recipient can later
    ///        `unwrap` once the reserve is refilled). Emits `UnwrapFallbackToMint`.
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
    ///      "unconfigured / fail-open" so a freshly-deployed contract remains
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
