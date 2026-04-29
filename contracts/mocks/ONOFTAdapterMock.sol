// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { ONOFTAdapter } from "../ONOFTAdapter.sol";

// @dev WARNING: This is for testing purposes only
contract ONOFTAdapterMock is ONOFTAdapter {
    constructor(address _token, address _lzEndpoint, address _delegate) ONOFTAdapter(_token, _lzEndpoint, _delegate) {}
}
