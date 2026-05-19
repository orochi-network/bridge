// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

/// @notice Grants MINTER_ROLE and BURNER_ROLE on wON to the BurnMintTokenPool. Ethereum side only.
contract GrantRoles is Script, Helper {
    function run() external {
        if (block.chainid != 1 && block.chainid != 11_155_111) {
            revert UnsupportedChain(block.chainid);
        }

        address wonAddr = Deployments.tryReadAddress(block.chainid, "wrappedON");
        _requireSet(wonAddr, "wrappedON (run script 01 first)");
        address pool = Deployments.tryReadAddress(block.chainid, "pool");
        _requireSet(pool, "pool (run script 02 first)");
        WrappedON won = WrappedON(wonAddr);

        vm.startBroadcast();
        won.grantRole(won.MINTER_ROLE(), pool);
        won.grantRole(won.BURNER_ROLE(), pool);
        vm.stopBroadcast();

        console.log("Granted MINTER+BURNER on wON %s to pool %s", address(won), pool);
    }
}
