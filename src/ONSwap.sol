// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ONSwap
/// @notice 1:1 swap from old BSC ON to new Hyperlane synthetic ON.
/// Old tokens are sent to the dead address (burned) on every swap.
/// @dev Owner can pause by recovering NEW_TOKEN. No complex pause logic needed.
contract ONSwap is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable OLD_TOKEN;
    IERC20 public immutable NEW_TOKEN;
    uint256 public totalSwapped;

    event Swapped(address indexed user, uint256 amount);
    event Recovered(address indexed token, address indexed to, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();
    error SameToken();

    constructor(
        address _oldToken,
        address _newToken,
        address _owner
    ) Ownable(_owner) {
        if (_oldToken == address(0) || _newToken == address(0))
            revert ZeroAddress();
        if (_oldToken == _newToken) revert SameToken();
        OLD_TOKEN = IERC20(_oldToken);
        NEW_TOKEN = IERC20(_newToken);
    }

    /// @notice Swap old ON for new ON at 1:1. Old tokens are burned (sent to dead address).
    /// @dev Caller must approve OLD_TOKEN for this contract before calling.
    /// @param _amount Amount of old ON to swap (in smallest token units).
    function swap(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        totalSwapped += _amount;
        OLD_TOKEN.safeTransferFrom(msg.sender, DEAD, _amount);
        NEW_TOKEN.safeTransfer(msg.sender, _amount);
        emit Swapped(msg.sender, _amount);
    }

    /// @notice Owner can recover any token from this contract.
    /// @dev Use to: (1) emergency pause swaps by draining NEW_TOKEN,
    ///      (2) recover tokens accidentally sent to this contract.
    /// @param _token Token address to recover.
    /// @param _to Recipient address.
    /// @param _amount Amount to recover (in smallest token units).
    function recover(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        IERC20(_token).safeTransfer(_to, _amount);
        emit Recovered(_token, _to, _amount);
    }

    /// @dev Prevent accidental ownership renouncement which would
    /// permanently lock recover() and make the contract unmanageable.
    function renounceOwnership() public pure override {
        revert("disabled");
    }
}
