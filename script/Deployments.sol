// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";

/// @notice Tiny helper for reading/writing per-chain deployment artifacts to
///         `deployments/<chainId>.json`. All scripts share these keys.
///
///         Keys written by this repo:
///           .wrappedON       (Ethereum / Sepolia only)
///           .pool            (every chain — BurnMintTokenPool or LockReleaseTokenPool)
library Deployments {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function path(uint256 chainId) internal pure returns (string memory) {
        return string.concat("./deployments/", vm.toString(chainId), ".json");
    }

    function readAddress(uint256 chainId, string memory key) internal view returns (address) {
        string memory file = path(chainId);
        string memory json = vm.readFile(file);
        return vm.parseJsonAddress(json, string.concat(".", key));
    }

    function writeAddress(uint256 chainId, string memory key, address value) internal {
        string memory file = path(chainId);
        string memory updated = vm.serializeAddress("deployments", key, value);
        vm.writeJson(updated, file);
    }
}
