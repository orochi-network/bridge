// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ONSwap} from "../src/ONSwap.sol";

/// @notice Deploy ONSwap and seed it with synthetic ON in a single broadcast.
///
/// IMPORTANT: The broadcaster (msg.sender) must hold the synthetic ON tokens.
/// If you used HYP_KEY for warp deploy, the 100M synthetic ON is in that wallet.
/// You must run this script with the SAME key, or transfer tokens first.
///
/// Usage with private key (same as HYP_KEY):
///   forge script script/DeploySwap.s.sol --rpc-url $BSC_RPC_URL --broadcast --verify \
///     --private-key $HYP_KEY --etherscan-api-key $BSCSCAN_API_KEY
///
/// Usage with ledger (must transfer tokens to ledger address first):
///   forge script script/DeploySwap.s.sol --rpc-url $BSC_RPC_URL --broadcast --verify \
///     --ledger --etherscan-api-key $BSCSCAN_API_KEY
contract DeploySwap is Script {
    using SafeERC20 for IERC20;

    function run() external {
        // Chain ID guard — must deploy on BSC
        require(block.chainid == 56, "Must deploy on BSC (chain ID 56)");

        address oldToken = vm.envAddress("OLD_ON_TOKEN_BSC");
        address newToken = vm.envAddress("NEW_ON_TOKEN_BSC");
        address swapOwner = vm.envAddress("SWAP_OWNER");
        uint256 seedAmount = vm.envOr("SEED_AMOUNT", uint256(100_000_000 ether));

        // Address validation
        require(oldToken != address(0), "OLD_ON_TOKEN_BSC not set");
        require(newToken != address(0), "NEW_ON_TOKEN_BSC not set");
        require(swapOwner != address(0), "SWAP_OWNER not set");
        require(oldToken != newToken, "OLD and NEW token are the same");

        // Contract existence checks
        require(oldToken.code.length > 0, "OLD_ON_TOKEN_BSC is not a contract");
        require(newToken.code.length > 0, "NEW_ON_TOKEN_BSC is not a contract");

        // Seed amount sanity check (must be in wei, not token units)
        require(seedAmount >= 1 ether, "SEED_AMOUNT too small - value must be in wei");

        uint256 balance = IERC20(newToken).balanceOf(msg.sender);
        require(balance >= seedAmount, "Insufficient synthetic ON - did you use the same key as HYP_KEY?");

        console.log("=== Deploy + Seed ONSwap ===");
        console.log("  Old Token:", oldToken);
        console.log("  New Token:", newToken);
        console.log("  Owner:", swapOwner);
        console.log("  Seed:", seedAmount);
        console.log("  Sender:", msg.sender);
        console.log("  Sender balance:", balance);

        vm.startBroadcast();

        ONSwap swap = new ONSwap(oldToken, newToken, swapOwner);
        console.log("  ONSwap:", address(swap));

        IERC20(newToken).safeTransfer(address(swap), seedAmount);

        vm.stopBroadcast();

        uint256 swapBalance = IERC20(newToken).balanceOf(address(swap));
        require(swapBalance == seedAmount, "Seed verification failed");
        console.log("  Seeded:", swapBalance);
        console.log("=== Done ===");
    }
}
