// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Deployments} from "../script/Deployments.sol";

/// @notice Round-trips `Deployments.writeAddress` -> `readAddress` to lock the JSON encoding.
///
/// Regression for PR #19 review (bao-ninh #2): `vm.toString(address)` returns `0x…` without
/// quotes. Passing it directly to `vm.writeJson` produces invalid JSON that subsequent reads
/// can't parse. The fix wraps the value in quotes so the file remains valid JSON.
contract DeploymentsTest is Test {
    /// @dev Each test uses a DIFFERENT chainId so the underlying file writes don't collide
    /// when forge runs tests in parallel.
    uint256 internal constant CHAIN_A = 31_337_001;
    uint256 internal constant CHAIN_B = 31_337_002;
    uint256 internal constant CHAIN_C = 31_337_003;

    function setUp() public {
        _cleanup(CHAIN_A);
        _cleanup(CHAIN_B);
        _cleanup(CHAIN_C);
    }

    function _cleanup(uint256 chainId) internal {
        string memory file = string.concat(vm.projectRoot(), "/deployments/", vm.toString(chainId), ".json");
        if (vm.exists(file)) {
            vm.removeFile(file);
        }
    }

    function test_WriteThenReadRoundTrip() public {
        address expected = makeAddr("wrappedON-A");
        Deployments.writeAddress(CHAIN_A, "wrappedON", expected);

        address actual = Deployments.readAddress(CHAIN_A, "wrappedON");
        assertEq(actual, expected);
    }

    function test_MultipleWritesPreserveAllKeys() public {
        address wONAddr = makeAddr("wrappedON-B");
        address poolAddr = makeAddr("pool-B");

        Deployments.writeAddress(CHAIN_B, "wrappedON", wONAddr);
        Deployments.writeAddress(CHAIN_B, "pool", poolAddr);

        // Both keys must round-trip — the second write must NOT clobber the first
        // (regression for the C-2 fix), AND both reads must return the correct addresses
        // (regression for the JSON-encoding fix).
        assertEq(Deployments.readAddress(CHAIN_B, "wrappedON"), wONAddr);
        assertEq(Deployments.readAddress(CHAIN_B, "pool"), poolAddr);
    }

    function test_WrittenFileIsValidJSON() public {
        Deployments.writeAddress(CHAIN_C, "wrappedON", makeAddr("wrappedON-C"));

        string memory file = string.concat(vm.projectRoot(), "/deployments/", vm.toString(CHAIN_C), ".json");
        string memory contents = vm.readFile(file);

        // `parseJsonAddress` succeeds only on a valid JSON document with the requested string
        // path resolving to a quoted hex address. If the writer ever regressed back to writing
        // `0x…` unquoted, this would fail.
        vm.parseJsonAddress(contents, ".wrappedON");
    }
}
