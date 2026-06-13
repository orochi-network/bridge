// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {Helper} from "./Helper.sol";
import {Deployments} from "./Deployments.sol";

/// @dev Minimal `TokenPool` reader interface. We avoid pulling in the full vendored
/// `TokenPool` ABI here because this script only needs three view methods.
interface ITokenPoolReader {
    function getToken() external view returns (address);
    function getRouter() external view returns (address);
    function getRmnProxy() external view returns (address);
}

interface ITypeAndVersion {
    function typeAndVersion() external view returns (string memory);
}

/// @notice Grants MINTER_ROLE and BURNER_ROLE on wON to the BurnMintTokenPool. Ethereum side only.
contract GrantRoles is Script, Helper {
    error PoolTokenMismatch(address pool, address poolToken, address expectedWon);
    /// @dev DEP-18: typed error for the `getToken()` staticcall failure path so an operator
    ///      pointing at a non-pool contract gets a clear diagnostic instead of an empty revert.
    error PoolGetTokenCallFailed(address pool);
    /// @dev DEP-22: defence-in-depth against a forged `FakePool { getToken() returns wON; … }`.
    ///      Each individual check (typeAndVersion, getRouter, getRmnProxy) is forgeable; the
    ///      combined surface is meaningfully larger and matches the suite of identity probes a
    ///      real CCIP pool exposes.
    error PoolMisidentified(address pool, string field, address expected, address actual);
    error PoolTypeMismatch(address pool, string actual);

    function run() external {
        if (block.chainid != 1 && block.chainid != 11_155_111) {
            revert UnsupportedChain(block.chainid);
        }

        NetworkConfig memory cfg = getConfig(block.chainid);
        address wonAddr = Deployments.tryReadAddress(block.chainid, "wrappedON");
        _requireSet(wonAddr, "wrappedON (run script 01 first)");
        address pool = Deployments.tryReadAddress(block.chainid, "pool");
        _requireSet(pool, "pool (run script 02 first)");
        WrappedON won = WrappedON(wonAddr);

        // Cross-check that the `pool` address from deployments JSON is actually a CCIP pool
        // bound to OUR wON token before granting unbounded mint/burn authority over wON to
        // it. If `deployments/<chainId>.json` has been tampered with or hand-edited, the
        // staticcalls below fail fast.
        //
        // DEP-18: wrap `getToken()` in try/catch so a non-pool contract surfaces a typed
        // `PoolGetTokenCallFailed` instead of an empty revert.
        // DEP-22: extend the CCIP-4 single-staticcall identity check into a multi-surface
        // probe (`typeAndVersion`, `getRouter`, `getRmnProxy`). Each is individually
        // forgeable by a malicious mock, but the combined surface raises the cost of a
        // deployments JSON tamper meaningfully — a single `FakePool { getToken() returns wON; }`
        // no longer suffices.
        try ITokenPoolReader(pool).getToken() returns (address poolToken) {
            if (poolToken != wonAddr) {
                revert PoolTokenMismatch(pool, poolToken, wonAddr);
            }
        } catch {
            revert PoolGetTokenCallFailed(pool);
        }
        try ITokenPoolReader(pool).getRouter() returns (address poolRouter) {
            if (poolRouter != cfg.router) {
                revert PoolMisidentified(pool, "router", cfg.router, poolRouter);
            }
        } catch {
            revert PoolMisidentified(pool, "router", cfg.router, address(0));
        }
        try ITokenPoolReader(pool).getRmnProxy() returns (address poolRmn) {
            if (poolRmn != cfg.rmnProxy) {
                revert PoolMisidentified(pool, "rmnProxy", cfg.rmnProxy, poolRmn);
            }
        } catch {
            revert PoolMisidentified(pool, "rmnProxy", cfg.rmnProxy, address(0));
        }
        // typeAndVersion is "BurnMintTokenPool 1.6.1" on the chainlink-ccip
        // contracts-ccip-v1.6.1 BurnMintTokenPool. Compare by keccak so the literal can drift
        // without source-code text edits going stale in two places. Failure modes:
        //   - selector missing (non-pool contract): caught below as PoolTypeMismatch with "".
        //   - selector returns a different string: caught below with the actual value.
        try ITypeAndVersion(pool).typeAndVersion() returns (string memory typeStr) {
            if (keccak256(bytes(typeStr)) != keccak256(bytes("BurnMintTokenPool 1.6.1"))) {
                revert PoolTypeMismatch(pool, typeStr);
            }
        } catch {
            revert PoolTypeMismatch(pool, "");
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
