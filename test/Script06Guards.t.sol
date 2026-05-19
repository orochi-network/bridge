// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {TransferOwnership, RenounceDeployerAdmin} from "../script/06_TransferOwnership.s.sol";

/// @notice Locks the `MultisigEqualsDeployer` guard added to both `TransferOwnership.run()`
///         and `RenounceDeployerAdmin.run()` (PR #19 round-2 finding [3], R-16). Without
///         these guards, an operator who set `MULTISIG=$DEPLOYER` (env-var collision or
///         typo) would silently target the deployer EOA on every handoff call, and the
///         renounce step's "multisig has role" check would be satisfied vacuously —
///         orphaning the contract.
///
///         Round-3 review [3] flagged the absence of unit coverage for these guards: a
///         regression dropping the check would have silently landed. The tests below run
///         each script directly, set `MULTISIG` to the broadcaster address via cheatcode,
///         and assert the revert fires before any broadcast.
///
///         Both scripts share `MULTISIG` as the env-var name and both run in the same
///         forge process, so tests run sequentially (Foundry parallelizes across contracts,
///         not across tests in one contract — but the process-level env is still shared,
///         so tests within this contract must avoid disagreeing on the value of MULTISIG).
contract Script06GuardsTest is Test {
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        // RenounceDeployerAdmin gates on block.chainid; pick ETH mainnet so the
        // chainid check passes through to the MULTISIG checks.
        vm.chainId(1);
        // Pin MULTISIG to the deployer for every test in this contract — the
        // `MultisigEqualsDeployer` branch is what we are locking. Setting in setUp
        // (not per-test) makes the value stable against process-env race conditions.
        vm.setEnv("MULTISIG", vm.toString(deployer));
    }

    function test_TransferOwnership_RevertsWhenMultisigEqualsDeployer() public {
        TransferOwnership script = new TransferOwnership();
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(TransferOwnership.MultisigEqualsDeployer.selector, deployer));
        script.run();
    }

    function test_RenounceDeployerAdmin_RevertsWhenMultisigEqualsDeployer() public {
        RenounceDeployerAdmin script = new RenounceDeployerAdmin();
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(RenounceDeployerAdmin.MultisigEqualsDeployer.selector, deployer));
        script.run();
    }
}
