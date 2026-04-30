// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

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
 */
contract WrappedON is OFT {
    using SafeERC20 for IERC20;
    using OFTMsgCodec for bytes;
    using OFTMsgCodec for bytes32;

    /// @notice Pre-existing, non-mintable ON ERC20 used as the reserve asset.
    IERC20 public immutable ON;

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

    /// @dev Override of OFT's default `_credit` (which always mints). Auto-unwraps
    ///      when the reserve covers the full amount; falls back to minting wON
    ///      otherwise. Single payout per message — never split.
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /*_srcEid*/
    ) internal virtual override returns (uint256 amountReceivedLD) {
        if (_to == address(0x0)) _to = address(0xdead);

        if (ON.balanceOf(address(this)) >= _amountLD) {
            ON.safeTransfer(_to, _amountLD);
            emit AutoUnwrap(_to, _amountLD);
        } else {
            _mint(_to, _amountLD);
            emit UnwrapFallbackToMint(_to, _amountLD);
        }
        return _amountLD;
    }

    /// @dev Override of OFTCore._lzReceive. For composed messages, force the mint
    ///      path — the compose handler downstream will operate on `amountReceivedLD`
    ///      assuming it received wON, so we must actually deliver wON. Plain
    ///      messages route through `_credit` (super) where auto-unwrap can fire.
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal virtual override {
        if (!_message.isComposed()) {
            super._lzReceive(_origin, _guid, _message, _executor, _extraData);
            return;
        }

        address toAddress = _message.sendTo().bytes32ToAddress();
        uint256 amountLD = _toLD(_message.amountSD());
        if (toAddress == address(0x0)) toAddress = address(0xdead);

        _mint(toAddress, amountLD);
        emit UnwrapFallbackToMint(toAddress, amountLD);

        bytes memory composeMsg = OFTComposeMsgCodec.encode(
            _origin.nonce,
            _origin.srcEid,
            amountLD,
            _message.composeMsg()
        );
        endpoint.sendCompose(toAddress, _guid, 0, composeMsg);
        emit OFTReceived(_guid, _origin.srcEid, toAddress, amountLD);
    }
}
