// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/pools/BurnMintTokenPool.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/pools/LockReleaseTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {Pool} from "@chainlink/contracts-ccip/libraries/Pool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";
import {
    IERC20 as ICCIP_IERC20
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

import {WrappedON} from "../../src/WrappedON.sol";

/// @dev Extends IRouter with getOffRamps(), not in the minimal IRouter interface.
interface IRouterFull {
    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function getOnRamp(uint64 destChainSelector) external view returns (address);
    function getOffRamps() external view returns (OffRamp[] memory);
}

/// @notice Dual-fork end-to-end bridge roundtrip against live mainnet.
///
/// Uses Foundry's multi-fork mode to deploy fresh pools on both Ethereum and BSC mainnet forks,
/// wire them with the real CCIP router and RMN addresses, then drive a complete BSC→ETH→BSC
/// token roundtrip by impersonating the live OnRamp/OffRamp addresses from each chain's router.
///
/// This is the highest-fidelity integration test possible short of submitting a real CCIP message.
///
/// Skipped automatically when ETH_RPC or BSC_RPC is not set.
contract Fork_Bridge is Test {
    // ── Ethereum mainnet CCIP ────────────────────────────────────────────────────
    address internal constant ETH_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address internal constant ETH_RMN = 0x411dE17f12D1A34ecC7F45f49844626267c75e81;
    address internal constant ON_ETH = 0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d;

    // ── BNB Smart Chain mainnet CCIP ─────────────────────────────────────────────
    address internal constant BSC_ROUTER = 0x34B03Cb9086d7D758AC55af71584F81A598759FE;
    address internal constant BSC_RMN = 0x9e09697842194f77d315E0907F1Bda77922e8f84;
    address internal constant ON_BSC = 0x0e4F6209eD984b21EDEA43acE6e09559eD051D48;

    uint64 internal constant ETH_SELECTOR = 5_009_297_550_715_157_269;
    uint64 internal constant BSC_SELECTOR = 11_344_663_589_394_136_015;

    uint256 internal ethFork;
    uint256 internal bscFork;

    // ── ETH-side contracts (live on ethFork) ─────────────────────────────────────
    WrappedON internal won;
    BurnMintTokenPool internal ethPool;

    // ── BSC-side contracts (live on bscFork) ─────────────────────────────────────
    LockReleaseTokenPool internal bscPool;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory ethRpc = vm.envOr("ETH_RPC", string(""));
        string memory bscRpc = vm.envOr("BSC_RPC", string(""));
        if (bytes(ethRpc).length == 0 || bytes(bscRpc).length == 0) {
            vm.skip(true);
            return;
        }

        // SECURITY: TEST-1 — pin both forks to specific blocks. Defaults match the
        // per-chain fork tests; override via ETH_FORK_BLOCK / BSC_FORK_BLOCK to refresh.
        uint256 ethBlock = vm.envOr("ETH_FORK_BLOCK", uint256(22_000_000));
        uint256 bscBlock = vm.envOr("BSC_FORK_BLOCK", uint256(50_000_000));
        ethFork = vm.createFork(ethRpc, ethBlock);
        bscFork = vm.createFork(bscRpc, bscBlock);

        // ── Deploy on ETH ────────────────────────────────────────────────────────
        vm.selectFork(ethFork);
        vm.startPrank(deployer);
        won = new WrappedON(IERC20(ON_ETH), deployer);
        ethPool = new BurnMintTokenPool(IBurnMintERC20(address(won)), 18, new address[](0), ETH_RMN, ETH_ROUTER);
        won.grantRole(won.MINTER_ROLE(), address(ethPool));
        won.grantRole(won.BURNER_ROLE(), address(ethPool));
        vm.stopPrank();

        // ── Deploy on BSC ────────────────────────────────────────────────────────
        vm.selectFork(bscFork);
        vm.prank(deployer);
        bscPool = new LockReleaseTokenPool(ICCIP_IERC20(ON_BSC), 18, new address[](0), BSC_RMN, BSC_ROUTER);

        // ── Wire ETH pool → BSC (now that bscPool address is known) ─────────────
        vm.selectFork(ethFork);
        {
            TokenPool.ChainUpdate[] memory up = new TokenPool.ChainUpdate[](1);
            up[0] = TokenPool.ChainUpdate({
                remoteChainSelector: BSC_SELECTOR,
                remotePoolAddresses: _remote(abi.encode(address(bscPool))),
                remoteTokenAddress: abi.encode(ON_BSC),
                outboundRateLimiterConfig: _limit(),
                inboundRateLimiterConfig: _limit()
            });
            vm.prank(deployer);
            ethPool.applyChainUpdates(new uint64[](0), up);
        }

        // ── Wire BSC pool → ETH (now that ethPool address is known) ─────────────
        vm.selectFork(bscFork);
        {
            TokenPool.ChainUpdate[] memory up = new TokenPool.ChainUpdate[](1);
            up[0] = TokenPool.ChainUpdate({
                remoteChainSelector: ETH_SELECTOR,
                remotePoolAddresses: _remote(abi.encode(address(ethPool))),
                remoteTokenAddress: abi.encode(address(won)),
                outboundRateLimiterConfig: _limit(),
                inboundRateLimiterConfig: _limit()
            });
            vm.prank(deployer);
            bscPool.applyChainUpdates(new uint64[](0), up);
        }
    }

    // ─── Full roundtrip: BSC → ETH → BSC ─────────────────────────────────────────

    function test_Fork_Bridge_FullRoundtrip() public {
        uint256 amount = 1000 ether;

        // ── Phase 1: BSC → ETH ───────────────────────────────────────────────────
        // Alice locks ON on BSC; message is delivered on ETH and mints wON.

        vm.selectFork(bscFork);

        address bscToEthOnRamp = IRouterFull(BSC_ROUTER).getOnRamp(ETH_SELECTOR);
        require(bscToEthOnRamp != address(0), "no ETH onRamp on BSC router");

        deal(ON_BSC, alice, amount);
        vm.prank(alice);
        IERC20(ON_BSC).transfer(address(bscPool), amount);

        assertEq(IERC20(ON_BSC).balanceOf(address(bscPool)), amount, "ON locked on BSC");

        vm.prank(bscToEthOnRamp);
        Pool.LockOrBurnOutV1 memory outLock = bscPool.lockOrBurn(
            Pool.LockOrBurnInV1({
                receiver: abi.encode(alice),
                remoteChainSelector: ETH_SELECTOR,
                originalSender: alice,
                amount: amount,
                localToken: ON_BSC
            })
        );

        // ── Phase 1 delivery: OffRamp on ETH mints wON ──────────────────────────
        vm.selectFork(ethFork);

        address bscToEthOffRamp = _findOffRamp(ETH_ROUTER, BSC_SELECTOR);

        vm.prank(bscToEthOffRamp);
        Pool.ReleaseOrMintOutV1 memory outMint = ethPool.releaseOrMint(
            Pool.ReleaseOrMintInV1({
                originalSender: abi.encode(alice),
                remoteChainSelector: BSC_SELECTOR,
                receiver: alice,
                sourceDenominatedAmount: amount,
                localToken: address(won),
                sourcePoolAddress: abi.encode(address(bscPool)),
                sourcePoolData: outLock.destPoolData,
                offchainTokenData: ""
            })
        );

        assertEq(outMint.destinationAmount, amount, "minted wON must equal locked ON");
        assertEq(won.balanceOf(alice), amount, "alice has wON on ETH");
        assertEq(won.totalSupply(), amount);

        // ── Phase 2: ETH → BSC ───────────────────────────────────────────────────
        // Alice burns wON on ETH; message delivered on BSC releases ON back to alice.

        address ethToBscOnRamp = IRouterFull(ETH_ROUTER).getOnRamp(BSC_SELECTOR);
        require(ethToBscOnRamp != address(0), "no BSC onRamp on ETH router");

        vm.prank(alice);
        won.transfer(address(ethPool), amount);

        vm.prank(ethToBscOnRamp);
        Pool.LockOrBurnOutV1 memory outBurn = ethPool.lockOrBurn(
            Pool.LockOrBurnInV1({
                receiver: abi.encode(alice),
                remoteChainSelector: BSC_SELECTOR,
                originalSender: alice,
                amount: amount,
                localToken: address(won)
            })
        );

        assertEq(won.totalSupply(), 0, "wON supply back to zero");

        // ── Phase 2 delivery: OffRamp on BSC releases ON ─────────────────────────
        vm.selectFork(bscFork);

        address ethToBscOffRamp = _findOffRamp(BSC_ROUTER, ETH_SELECTOR);

        uint256 aliceBefore = IERC20(ON_BSC).balanceOf(alice);

        vm.prank(ethToBscOffRamp);
        bscPool.releaseOrMint(
            Pool.ReleaseOrMintInV1({
                originalSender: abi.encode(alice),
                remoteChainSelector: ETH_SELECTOR,
                receiver: alice,
                sourceDenominatedAmount: amount,
                localToken: ON_BSC,
                sourcePoolAddress: abi.encode(address(ethPool)),
                sourcePoolData: outBurn.destPoolData,
                offchainTokenData: ""
            })
        );

        assertEq(IERC20(ON_BSC).balanceOf(alice), aliceBefore + amount, "alice gets ON back on BSC");
        assertEq(IERC20(ON_BSC).balanceOf(address(bscPool)), 0, "BSC pool fully drained");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    function _limit() internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: true, capacity: 100_000 ether, rate: 10 ether});
    }

    /// @dev CCIP 1.6.1 `ChainUpdate.remotePoolAddresses` is `bytes[]`; wrap a single encoded pool.
    function _remote(bytes memory poolAddr) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = poolAddr;
    }

    function _findOffRamp(address router, uint64 sourceChain) internal view returns (address offRamp) {
        IRouterFull.OffRamp[] memory all = IRouterFull(router).getOffRamps();
        for (uint256 i; i < all.length; ++i) {
            if (all[i].sourceChainSelector == sourceChain) {
                return all[i].offRamp;
            }
        }
        revert(string.concat("no offRamp found for selector ", vm.toString(sourceChain)));
    }
}
