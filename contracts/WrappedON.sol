// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WrappedON (wON)
 * @notice Ethereum-side mintable representation of ON, with optional 1:1 swap to a
 *         pre-existing non-mintable ON contract held in this contract's reserve.
 *
 * @dev Inbound (BSC -> ETH) credit semantics:
 *      - If reserve >= amount: transfer real ON to the recipient. wON is NOT minted.
 *      - Otherwise: mint wON to the recipient (default OFT behaviour). The recipient
 *        can later call unwrap(amount) to redeem against the reserve once it is
 *        refilled.
 *
 *      The reserve is non-mintable. Sustained net BSC -> ETH flow drains it; refilling
 *      requires either bridging wON back to BSC (unlocking real ON there and then
 *      acquiring real ON on ETH off-chain) or a treasury commitment via seedReserve.
 *      There is no autonomous refill mechanism.
 */
contract WrappedON is OFT {
    using SafeERC20 for IERC20;

    /// @notice Pre-existing, non-mintable ON ERC20 used as the reserve asset.
    IERC20 public immutable ON;

    event AutoUnwrap(address indexed to, uint256 amount);
    event UnwrapFallbackToMint(address indexed to, uint256 amount);
    event Wrap(address indexed from, uint256 amount);
    event Unwrap(address indexed from, uint256 amount);
    event ReserveSeeded(address indexed from, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();
    error DecimalsMismatch(uint8 actual);
    error ReserveInsufficient(uint256 requested, uint256 available);

    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate,
        address _onToken
    ) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) {
        if (_onToken == address(0)) revert ZeroAddress();
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

    /// @notice Deposit `_amount` real ON, receive `_amount` wON 1:1. Caller must
    ///         approve(this, _amount) on the ON token first.
    function wrap(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        ON.safeTransferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, _amount);
        emit Wrap(msg.sender, _amount);
    }

    /// @notice Donate real ON to the reserve without minting wON. Functionally
    ///         equivalent to a direct ERC20 transfer to this contract; this
    ///         wrapper just emits an event for off-chain accounting.
    function seedReserve(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();
        ON.safeTransferFrom(msg.sender, address(this), _amount);
        emit ReserveSeeded(msg.sender, _amount);
    }

    /// @dev Override of OFT default _credit (which always mints). Auto-unwraps when
    ///      the reserve covers the full amount; falls back to minting wON otherwise.
    ///      Single transfer or single mint per message — never split.
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
}
