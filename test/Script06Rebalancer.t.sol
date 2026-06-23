// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {TransferOwnership} from "../script/06_TransferOwnership.s.sol";

/// @dev Minimal `LockReleaseTokenPool` surface — only the rebalancer getter, settable.
contract MockRebalancerPool {
    address public rebalancer;

    function setRebalancer(address r) external {
        rebalancer = r;
    }

    function getRebalancer() external view returns (address) {
        return rebalancer;
    }
}

/// @dev Exposes `TransferOwnership`'s internal pre-handoff rebalancer guard.
contract TransferOwnershipHarness is TransferOwnership {
    function exposeAssertPoolHasNoRebalancer(address pool) external view {
        _assertPoolHasNoRebalancer(pool);
    }
}

/// @notice DEP-26: locks the BSC pre-handoff guard that refuses to transfer custody-grade
///         `LockReleaseTokenPool` ownership while a rebalancer is set — the locked-ON reserve
///         would be drainable via `withdrawLiquidity` the moment the multisig (or a compromised
///         setter) acted. Mirrors script 08's `_checkBscRebalancer`, but enforced at the
///         handoff broadcast itself rather than relying solely on a post-handoff `verify-bsc`.
contract Script06RebalancerTest is Test {
    TransferOwnershipHarness internal h;

    function setUp() public {
        h = new TransferOwnershipHarness();
    }

    function test_PassesWhenRebalancerZero() public {
        MockRebalancerPool pool = new MockRebalancerPool(); // rebalancer defaults to address(0)
        h.exposeAssertPoolHasNoRebalancer(address(pool));
    }

    function test_RevertsWhenRebalancerSet() public {
        MockRebalancerPool pool = new MockRebalancerPool();
        address attacker = makeAddr("attacker");
        pool.setRebalancer(attacker);

        vm.expectRevert(
            abi.encodeWithSelector(TransferOwnership.UnexpectedRebalancer.selector, address(pool), attacker)
        );
        h.exposeAssertPoolHasNoRebalancer(address(pool));
    }

    function test_RevertsOnReadFailure() public {
        // An EOA (no code): the staticcall returns ok=true with data.length=0, so the typed
        // read-failure path fires rather than a low-level decode panic. DEP-19 parity.
        address noCode = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(TransferOwnership.RebalancerReadFailed.selector, noCode));
        h.exposeAssertPoolHasNoRebalancer(noCode);
    }
}
