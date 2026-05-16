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

    /// @notice Like `readAddress` but returns `address(0)` if the deployment file is missing
    ///         OR the key is absent. Used by scripts 01 / 02 to skip re-deploying an artifact
    ///         that already has an entry on this chain (round-3 review [6]).
    function tryReadAddress(uint256 chainId, string memory key) internal view returns (address) {
        string memory file = path(chainId);
        if (!vm.exists(file)) return address(0);
        string memory json = vm.readFile(file);
        string memory jsonPath = string.concat(".", key);
        if (!vm.keyExistsJson(json, jsonPath)) return address(0);
        return vm.parseJsonAddress(json, jsonPath);
    }

    /// @notice Writes a single key into the deployment JSON without clobbering existing keys.
    ///
    /// The 2-arg `vm.writeJson(serialized, file)` overload rebuilds the entire object from the
    /// in-memory serializer state — so a second call within the same forge process would erase
    /// any key written by an earlier call (or by a prior run, if the file already had keys we
    /// didn't re-serialize). The 3-arg overload patches a single JSON path in-place. We
    /// initialize the file as `{}` on first write so the path-write target exists.
    ///
    /// The `serialized` argument must be a fully-formed JSON token. `vm.toString(address)`
    /// returns a bare hex string (`0x…`) without surrounding quotes — passing that directly
    /// would write an invalid JSON token into the file. Wrap with quotes so the value is a
    /// proper JSON string that `vm.parseJsonAddress` can read back. (Per PR #19 review.)
    ///
    /// Known limitation (round-2 review [7]): if a prior `forge script` broadcast was killed
    /// mid-write, the JSON file may be left corrupt (truncated / partially written). This
    /// helper only seeds the file when it is missing — not when it is present-but-invalid.
    /// Recovery: delete `deployments/<chainId>.json` and re-run the deploy script. The
    /// scripts that read this file (`readAddress`) will surface a `vm.parseJsonAddress`
    /// error on a corrupt file, so the operator gets a clear signal at the next step.
    function writeAddress(uint256 chainId, string memory key, address value) internal {
        string memory file = path(chainId);
        if (!vm.exists(file)) vm.writeFile(file, "{}");
        string memory quoted = string.concat('"', vm.toString(value), '"');
        vm.writeJson(quoted, file, string.concat(".", key));
    }
}
