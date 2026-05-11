// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import { WrappedON } from "../WrappedON.sol";

// @dev WARNING: This is for testing purposes only
contract WrappedONMock is WrappedON {
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate,
        address _onToken
    ) WrappedON(_name, _symbol, _lzEndpoint, _delegate, _onToken) {}

    function mint(address _to, uint256 _amount) public {
        _mint(_to, _amount);
    }

    function credit(address _to, uint256 _amountLD, uint32 _srcEid) public returns (uint256) {
        return _credit(_to, _amountLD, _srcEid);
    }

    /// @dev Sets the transient composed flag, then routes to `_credit`. Mirrors
    ///      what `_lzReceive` does for a composed packet without needing to
    ///      stand up the LayerZero packet plumbing.
    function creditComposed(address _to, uint256 _amountLD, uint32 _srcEid) public returns (uint256) {
        _composedFlag = true;
        return _credit(_to, _amountLD, _srcEid);
    }
}
