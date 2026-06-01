// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Helper} from "./Helper.sol";

interface ITypeAndVersion {
    function typeAndVersion() external view returns (string memory);
}

interface IRouterLike {
    function isChainSupported(uint64 chainSelector) external view returns (bool);
}

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Live (RPC-backed) validation of the CCIP infrastructure addresses in `Helper.sol`
///         for the chain selected by `block.chainid` (issue #21).
///
///         `PrecheckHelper` only asserts the addresses are non-zero (pure, no RPC). This script
///         goes further: it staticcalls each configured address to confirm it is actually the
///         expected CCIP contract on the target chain (via `typeAndVersion()`), checks that the
///         router supports the remote lane (so the configured chain selector is real), and
///         sanity-checks the LINK fee token and canonical ON decimals.
///
///         Run it against the TARGET chain's RPC AFTER filling `Helper.sol` and BEFORE any
///         broadcast:
///             make validate-config RPC=<target-chain rpc>
///         or  forge script script/ValidateConfig.s.sol --rpc-url <rpc>
///
///         View-only; never broadcasts. Reports every check, then reverts if any failed so it
///         can gate a deploy. Expected production versions (see README): Router 1.2.0,
///         ARMProxy 1.0.0, TokenAdminRegistry 1.5.0, RegistryModuleOwnerCustom 1.6.0.
contract ValidateConfig is Script, Helper {
    function run() external view {
        uint256 cid = block.chainid;
        NetworkConfig memory cfg = getConfig(cid);
        uint64 remote = _remoteSelector(cid);

        console.log(string.concat("Validating CCIP config for chainId ", vm.toString(cid)));
        console.log(string.concat("  configured chainSelector: ", vm.toString(uint256(cfg.chainSelector))));
        console.log(string.concat("  remote lane selector:     ", vm.toString(uint256(remote))));

        uint256 fails;

        // 0. Non-zero (same gate as PrecheckHelper, repeated so this script stands alone).
        fails += _nonZero(cfg.router, "router");
        fails += _nonZero(cfg.rmnProxy, "rmnProxy");
        fails += _nonZero(cfg.tokenAdminRegistry, "tokenAdminRegistry");
        fails += _nonZero(cfg.registryModuleOwnerCustom, "registryModuleOwnerCustom");
        fails += _nonZero(cfg.linkToken, "linkToken");

        // 1. typeAndVersion identity checks against the documented production versions.
        fails += _assertTypeAndVersion(cfg.router, "Router", "router");
        fails += _assertTypeAndVersion(cfg.tokenAdminRegistry, "TokenAdminRegistry", "tokenAdminRegistry");
        fails += _assertTypeAndVersion(
            cfg.registryModuleOwnerCustom, "RegistryModuleOwnerCustom", "registryModuleOwnerCustom"
        );
        // The RMN proxy reports as "ARMProxy x.y.z" (legacy name) or "RMNProxy x.y.z".
        fails += _assertRmn(cfg.rmnProxy);

        // 2. The configured chain selector must correspond to a lane the router actually supports.
        fails += _assertLane(cfg.router, remote);

        // 3. LINK fee token sanity.
        fails += _assertSymbol(cfg.linkToken, "LINK", "linkToken");

        // 4. Canonical ON decimals must be 18 on the mainnets that hardcode it (CCIP-9 parity).
        if (cid == 1 || cid == 56) {
            fails += _assertDecimals(cfg.onToken, 18, "onToken");
        }

        if (fails != 0) {
            revert(string.concat("ValidateConfig: ", vm.toString(fails), " check(s) FAILED - see logs above"));
        }
        console.log(string.concat("ValidateConfig OK for chainId ", vm.toString(cid)));
    }

    // -- helpers (each returns 1 on failure, 0 on success) --

    function _nonZero(address a, string memory field) internal view returns (uint256) {
        if (a == address(0)) {
            console.log(string.concat("  FAIL ", field, ": address(0) placeholder - fill in from the CCIP directory"));
            return 1;
        }
        return 0;
    }

    function _assertTypeAndVersion(address a, string memory expectedPrefix, string memory field)
        internal
        view
        returns (uint256)
    {
        if (a == address(0)) return 1; // already reported by _nonZero
        try ITypeAndVersion(a).typeAndVersion() returns (string memory v) {
            if (_startsWith(v, expectedPrefix)) {
                console.log(string.concat("  ok   ", field, " = ", vm.toString(a), " (", v, ")"));
                return 0;
            }
            console.log(
                string.concat(
                    "  FAIL ", field, " @ ", vm.toString(a), ": typeAndVersion '", v, "' is not a ", expectedPrefix
                )
            );
            return 1;
        } catch {
            console.log(
                string.concat(
                    "  FAIL ", field, " @ ", vm.toString(a), ": typeAndVersion() reverted - not a CCIP contract?"
                )
            );
            return 1;
        }
    }

    function _assertRmn(address a) internal view returns (uint256) {
        if (a == address(0)) return 1;
        try ITypeAndVersion(a).typeAndVersion() returns (string memory v) {
            if (_startsWith(v, "ARMProxy") || _startsWith(v, "RMNProxy")) {
                console.log(string.concat("  ok   rmnProxy = ", vm.toString(a), " (", v, ")"));
                return 0;
            }
            console.log(
                string.concat(
                    "  FAIL rmnProxy @ ", vm.toString(a), ": typeAndVersion '", v, "' is not ARMProxy/RMNProxy"
                )
            );
            return 1;
        } catch {
            console.log(string.concat("  FAIL rmnProxy @ ", vm.toString(a), ": typeAndVersion() reverted"));
            return 1;
        }
    }

    function _assertLane(address router, uint64 remote) internal view returns (uint256) {
        if (router == address(0)) return 1;
        try IRouterLike(router).isChainSupported(remote) returns (bool ok) {
            if (ok) {
                console.log(string.concat("  ok   router supports remote lane selector ", vm.toString(uint256(remote))));
                return 0;
            }
            console.log(
                string.concat(
                    "  FAIL router does NOT support remote lane selector ",
                    vm.toString(uint256(remote)),
                    " - wrong router or selector for this network?"
                )
            );
            return 1;
        } catch {
            console.log("  FAIL router.isChainSupported() reverted - not a CCIP Router?");
            return 1;
        }
    }

    function _assertSymbol(address token, string memory expected, string memory field) internal view returns (uint256) {
        if (token == address(0)) return 1;
        try IERC20Meta(token).symbol() returns (string memory sym) {
            if (_eq(sym, expected)) {
                console.log(string.concat("  ok   ", field, " symbol = ", sym));
                return 0;
            }
            console.log(string.concat("  FAIL ", field, " symbol '", sym, "' != '", expected, "'"));
            return 1;
        } catch {
            console.log(string.concat("  FAIL ", field, ".symbol() reverted at ", vm.toString(token)));
            return 1;
        }
    }

    function _assertDecimals(address token, uint8 expected, string memory field) internal view returns (uint256) {
        if (token == address(0)) return 1;
        try IERC20Meta(token).decimals() returns (uint8 d) {
            if (d == expected) {
                console.log(string.concat("  ok   ", field, " decimals = ", vm.toString(uint256(d))));
                return 0;
            }
            console.log(
                string.concat(
                    "  FAIL ", field, " decimals = ", vm.toString(uint256(d)), " != ", vm.toString(uint256(expected))
                )
            );
            return 1;
        } catch {
            console.log(string.concat("  FAIL ", field, ".decimals() reverted at ", vm.toString(token)));
            return 1;
        }
    }

    function _remoteSelector(uint256 chainId) internal pure returns (uint64) {
        if (chainId == 1) return BSC_MAINNET_SELECTOR;
        if (chainId == 56) return ETH_MAINNET_SELECTOR;
        if (chainId == 11_155_111) return BSC_TESTNET_SELECTOR;
        if (chainId == 97) return SEPOLIA_SELECTOR;
        revert UnsupportedChain(chainId);
    }

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(p);
        if (sb.length < pb.length) return false;
        for (uint256 i = 0; i < pb.length; i++) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
