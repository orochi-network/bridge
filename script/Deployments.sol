// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";

/// @notice Tiny helper for reading/writing per-chain deployment artifacts to
///         `deployments/<chainId>.json`. All scripts share these keys.
///
///         Keys written by this repo:
///           .wrappedON       (Ethereum / Sepolia only)
///           .pool            (every chain — BurnMintTokenPool or LockReleaseTokenPool)
///
///         Paths are resolved against `vm.projectRoot()` so they work regardless of the
///         caller's current working directory.
library Deployments {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function path(uint256 chainId) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/", vm.toString(chainId), ".json");
    }

    function readAddress(uint256 chainId, string memory key) internal view returns (address) {
        string memory file = path(chainId);
        string memory json = vm.readFile(file);
        return vm.parseJsonAddress(json, string.concat(".", key));
    }

    /// @notice Writes a single key into the deployment JSON without clobbering existing keys.
    ///
    /// The 2-arg `vm.writeJson(serialized, file)` overload rebuilds the entire object from the
    /// in-memory serializer state — so a second call within the same forge process would erase
    /// any key written by an earlier call (or by a prior run, if the file already had keys we
    /// didn't re-serialize). The 3-arg overload patches a single JSON path in-place. We
    /// initialize the file as `{}` on first write so the path-write target exists.
    function writeAddress(uint256 chainId, string memory key, address value) internal {
        string memory file = path(chainId);
        if (!vm.exists(file)) vm.writeFile(file, "{}");
        vm.writeJson(vm.toString(value), file, string.concat(".", key));
    }
}
