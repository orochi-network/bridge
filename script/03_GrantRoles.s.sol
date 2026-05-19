// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

/// @dev Minimal `TokenPool.getToken()` reader. We avoid pulling in the full vendored
/// `TokenPool` ABI here because this script only needs the token-binding readback.
interface ITokenPoolGetToken {
    function getToken() external view returns (address);
}

/// @notice Grants MINTER_ROLE and BURNER_ROLE on wON to the BurnMintTokenPool. Ethereum side only.
contract GrantRoles is Script, Helper {
    error PoolTokenMismatch(address pool, address poolToken, address expectedWon);

    function run() external {
        if (block.chainid != 1 && block.chainid != 11_155_111) {
            revert UnsupportedChain(block.chainid);
        }

        address wonAddr = Deployments.tryReadAddress(block.chainid, "wrappedON");
        _requireSet(wonAddr, "wrappedON (run script 01 first)");
        address pool = Deployments.tryReadAddress(block.chainid, "pool");
        _requireSet(pool, "pool (run script 02 first)");
        WrappedON won = WrappedON(wonAddr);

        // Cross-check that the `pool` address from deployments JSON is actually a CCIP pool
        // bound to OUR wON token before granting unbounded mint/burn authority over wON to
        // it. If `deployments/<chainId>.json` has been tampered with or hand-edited, this
        // staticcall fails fast — it isn't forgeable without deploying a matching contract
        // with the right `getToken()` selector returning wON. SECURITY: CCIP-4.
        address poolToken = ITokenPoolGetToken(pool).getToken();
        if (poolToken != wonAddr) {
            revert PoolTokenMismatch(pool, poolToken, wonAddr);
        }

        // OZ AccessControl.grantRole is a no-op when the role is already held, so the
        // duplicate broadcasts on re-run are harmless. Probe anyway for cleaner logs and
        // to avoid spending gas on no-op transactions. SECURITY: DEP-6.
        bool minterAlready = won.hasRole(won.MINTER_ROLE(), pool);
        bool burnerAlready = won.hasRole(won.BURNER_ROLE(), pool);

        if (minterAlready && burnerAlready) {
            console.log("MINTER+BURNER already granted to %s - nothing to do", pool);
            return;
        }

        vm.startBroadcast();
        if (!minterAlready) {
            won.grantRole(won.MINTER_ROLE(), pool);
        }
        if (!burnerAlready) {
            won.grantRole(won.BURNER_ROLE(), pool);
        }
        vm.stopBroadcast();

        console.log("Granted MINTER+BURNER on wON %s to pool %s", address(won), pool);
    }
}
