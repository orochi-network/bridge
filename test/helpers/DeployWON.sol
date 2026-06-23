// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WrappedON} from "../../src/WrappedON.sol";

/// @title DeployWON
/// @notice Test helper that deploys `WrappedON` behind an ERC-1967 (UUPS) proxy.
/// @dev Deploys the implementation, then an `ERC1967Proxy` whose constructor delegatecalls
///      `initialize(on, admin, timelock)`. Returns the proxy typed as `WrappedON`. Tests that
///      do not exercise upgrades can pass `admin` as the `timelock`/upgrader argument.
library DeployWON {
    /// @notice Deploy impl + proxy initialized with `(on, admin, timelock)`.
    function deploy(IERC20 on, address admin, address timelock) internal returns (WrappedON) {
        WrappedON impl = new WrappedON();
        bytes memory data = abi.encodeCall(WrappedON.initialize, (on, admin, timelock));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        return WrappedON(address(proxy));
    }
}
