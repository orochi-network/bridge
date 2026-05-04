// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";

/**
 * @title ONOFTAdapter
 * @notice BSC-side adapter that locks/unlocks the canonical ON token for the
 *         LayerZero V2 OFT mesh. Diverges from the upstream `OFTAdapter`
 *         template in exactly one place: `_debit` is overridden with a
 *         balance-delta check so the adapter cannot silently misreport
 *         `amountSentLD` to LayerZero if the inner ON token ever ships
 *         fee-on-transfer or rebasing semantics.
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
 * @dev    WARNING: ONLY 1 OFTAdapter should exist for a given global mesh.
 */
contract ONOFTAdapter is OFTAdapter {
    using SafeERC20 for IERC20;

    error UnexpectedTransferAmount(uint256 expected, uint256 received);

    constructor(
        address _token,
        address _lzEndpoint,
        address _delegate
    ) OFTAdapter(_token, _lzEndpoint, _delegate) Ownable(_delegate) {}

    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        uint256 balanceBefore = innerToken.balanceOf(address(this));
        innerToken.safeTransferFrom(_from, address(this), amountSentLD);
        uint256 received = innerToken.balanceOf(address(this)) - balanceBefore;
        if (received != amountSentLD) revert UnexpectedTransferAmount(amountSentLD, received);
    }
}
