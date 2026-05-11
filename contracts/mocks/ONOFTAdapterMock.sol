// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import { ONOFTAdapter } from "../ONOFTAdapter.sol";

// @dev WARNING: This is for testing purposes only
contract ONOFTAdapterMock is ONOFTAdapter {
    constructor(address _token, address _lzEndpoint, address _delegate) ONOFTAdapter(_token, _lzEndpoint, _delegate) {}

    // @dev expose internal _credit for testing purposes
    function credit(address _to, uint256 _amountLD, uint32 _srcEid) public returns (uint256) {
        return _credit(_to, _amountLD, _srcEid);
    }
}
