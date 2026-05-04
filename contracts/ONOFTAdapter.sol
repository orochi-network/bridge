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
 *         template in two places:
 *
 *         1. `_debit` is overridden with a balance-delta check so the adapter
 *            cannot silently misreport `amountSentLD` to LayerZero if the
 *            inner ON token ever ships fee-on-transfer or rebasing semantics.
 *
 *         2. `_credit` is overridden to redirect bad recipient addresses
 *            (`address(0)` and `address(this)`) to `address(0xdead)`, matching
 *            the same hardening present in WrappedON on the Ethereum side.
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
}
