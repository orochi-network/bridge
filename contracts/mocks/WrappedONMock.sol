// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

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
}
