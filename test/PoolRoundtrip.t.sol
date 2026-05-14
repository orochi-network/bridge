// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BurnMintTokenPool} from "@chainlink/contracts-ccip/ccip/pools/BurnMintTokenPool.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/ccip/pools/LockReleaseTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/ccip/pools/TokenPool.sol";
import {Pool} from "@chainlink/contracts-ccip/ccip/libraries/Pool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/ccip/libraries/RateLimiter.sol";
import {IBurnMintERC20} from "@chainlink/contracts-ccip/shared/token/ERC20/IBurnMintERC20.sol";
import {
    IERC20 as ICCIP_IERC20
} from "@chainlink/contracts-ccip/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockRMN} from "./mocks/MockRMN.sol";

/// @dev Canonical ON on each chain — non-mintable.
contract MockON is ERC20 {
    constructor(string memory s, uint256 supply, address to) ERC20("Orochi Network", s) {
        _mint(to, supply);
    }
}

/// @notice Simulates the full ETH ⇄ BSC CCIP roundtrip without spinning up real chains:
///         constructs both pools in this test's address space with mock router/RMN, wires them,
///         and impersonates the OnRamp/OffRamp to drive `lockOrBurn` / `releaseOrMint` directly.
///
///         This validates the integration we actually control:
///           - wON exposes the burn/mint selectors BurnMintTokenPool calls
///           - role gating (MINTER_ROLE / BURNER_ROLE) lets the pool succeed
///           - LockReleaseTokenPool locks and releases the canonical ON correctly
///           - applyChainUpdates wires both directions with rate limits
///
///         CCIP off-chain message routing, fees, and RMN itself are out of scope (Chainlink-owned).
contract PoolRoundtripTest is Test {
    uint64 internal constant ETH_SELECTOR = 5_009_297_550_715_157_269;
    uint64 internal constant BSC_SELECTOR = 11_344_663_589_394_136_015;

    // ── ETH side ────────────────────────────────────────────────────────────
    WrappedON internal won;
    BurnMintTokenPool internal ethPool;
    MockRouter internal ethRouter;
    MockRMN internal ethRmn;
    address internal ethOnRamp = makeAddr("ethOnRamp");
    address internal ethOffRamp = makeAddr("ethOffRamp");

    // ── BSC side ────────────────────────────────────────────────────────────
    MockON internal onBsc;
    LockReleaseTokenPool internal bscPool;
    MockRouter internal bscRouter;
    MockRMN internal bscRmn;
    address internal bscOnRamp = makeAddr("bscOnRamp");
    address internal bscOffRamp = makeAddr("bscOffRamp");

    // ── Actors ──────────────────────────────────────────────────────────────
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");

    function setUp() public {
        // BSC: canonical ON token (pre-existing, non-mintable) with all 100M minted to alice.
        onBsc = new MockON("ON", 100_000_000 ether, alice);

        // Routers + RMNs.
        ethRouter = new MockRouter();
        bscRouter = new MockRouter();
        ethRmn = new MockRMN();
        bscRmn = new MockRMN();

        // ── ETH side deploy ─────────────────────────────────────────────────
        // Need an ERC20 to back wON; for this isolated test it's never deposited so a
        // placeholder ERC20 with no supply is fine.
        MockON onEth = new MockON("ON", 0, address(0xdead));
        vm.prank(admin);
        won = new WrappedON(IERC20(address(onEth)), admin);
        ethPool =
            new BurnMintTokenPool(IBurnMintERC20(address(won)), new address[](0), address(ethRmn), address(ethRouter));

        // Pool gets MINTER+BURNER on wON.
        vm.startPrank(admin);
        won.grantRole(won.MINTER_ROLE(), address(ethPool));
        won.grantRole(won.BURNER_ROLE(), address(ethPool));
        vm.stopPrank();

        // ── BSC side deploy ─────────────────────────────────────────────────
        bscPool = new LockReleaseTokenPool(
            ICCIP_IERC20(address(onBsc)), new address[](0), address(bscRmn), false, address(bscRouter)
        );

        // ── Wire routers (the only ramps we recognise are our test fixtures) ─
        ethRouter.setOnRamp(BSC_SELECTOR, ethOnRamp);
        ethRouter.setOffRamp(BSC_SELECTOR, ethOffRamp, true);
        bscRouter.setOnRamp(ETH_SELECTOR, bscOnRamp);
        bscRouter.setOffRamp(ETH_SELECTOR, bscOffRamp, true);

        // ── Wire pools to each other with rate limits ───────────────────────
        TokenPool.ChainUpdate[] memory ethToBsc = new TokenPool.ChainUpdate[](1);
        ethToBsc[0] = TokenPool.ChainUpdate({
            remoteChainSelector: BSC_SELECTOR,
            allowed: true,
            remotePoolAddress: abi.encode(address(bscPool)),
            remoteTokenAddress: abi.encode(address(onBsc)),
            outboundRateLimiterConfig: _limit(100_000 ether, 10 ether),
            inboundRateLimiterConfig: _limit(100_000 ether, 10 ether)
        });
        ethPool.applyChainUpdates(ethToBsc);

        TokenPool.ChainUpdate[] memory bscToEth = new TokenPool.ChainUpdate[](1);
        bscToEth[0] = TokenPool.ChainUpdate({
            remoteChainSelector: ETH_SELECTOR,
            allowed: true,
            remotePoolAddress: abi.encode(address(ethPool)),
            remoteTokenAddress: abi.encode(address(won)),
            outboundRateLimiterConfig: _limit(100_000 ether, 10 ether),
            inboundRateLimiterConfig: _limit(100_000 ether, 10 ether)
        });
        bscPool.applyChainUpdates(bscToEth);
    }

    function _limit(uint128 capacity, uint128 rate) internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: true, capacity: capacity, rate: rate});
    }

    // ─── Direction 1: BSC → ETH (lock ON on BSC, mint wON on ETH) ─────────────

    function test_BscToEth_LockAndMint() public {
        uint256 amount = 1000 ether;

        // Alice locks 1000 ON on BSC via the OnRamp.
        vm.prank(alice);
        onBsc.transfer(address(bscPool), amount);

        Pool.LockOrBurnInV1 memory inLock = Pool.LockOrBurnInV1({
            receiver: abi.encode(alice),
            remoteChainSelector: ETH_SELECTOR,
            originalSender: alice,
            amount: amount,
            localToken: address(onBsc)
        });
        vm.prank(bscOnRamp);
        Pool.LockOrBurnOutV1 memory outLock = bscPool.lockOrBurn(inLock);

        assertEq(onBsc.balanceOf(address(bscPool)), amount, "ON locked in BSC pool");
        assertEq(abi.decode(outLock.destTokenAddress, (address)), address(won), "destToken == wON");

        // OffRamp on ETH delivers the message — mints wON to alice.
        Pool.ReleaseOrMintInV1 memory inMint = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(alice),
            remoteChainSelector: BSC_SELECTOR,
            receiver: alice,
            amount: amount,
            localToken: address(won),
            sourcePoolAddress: abi.encode(address(bscPool)),
            sourcePoolData: outLock.destPoolData,
            offchainTokenData: ""
        });
        vm.prank(ethOffRamp);
        Pool.ReleaseOrMintOutV1 memory outMint = ethPool.releaseOrMint(inMint);

        assertEq(outMint.destinationAmount, amount);
        assertEq(won.balanceOf(alice), amount, "alice minted wON 1:1");
        assertEq(won.totalSupply(), amount);
    }

    // ─── Direction 2: ETH → BSC (burn wON on ETH, release ON on BSC) ──────────

    function test_EthToBsc_BurnAndRelease() public {
        // Seed: do the BSC→ETH roundtrip first so alice has wON to burn.
        test_BscToEth_LockAndMint();
        uint256 amount = 600 ether;

        // Alice burns wON on ETH via the OnRamp: transfer to pool, then OnRamp calls lockOrBurn.
        vm.prank(alice);
        won.transfer(address(ethPool), amount);

        Pool.LockOrBurnInV1 memory inBurn = Pool.LockOrBurnInV1({
            receiver: abi.encode(alice),
            remoteChainSelector: BSC_SELECTOR,
            originalSender: alice,
            amount: amount,
            localToken: address(won)
        });
        vm.prank(ethOnRamp);
        Pool.LockOrBurnOutV1 memory outBurn = ethPool.lockOrBurn(inBurn);

        assertEq(won.balanceOf(address(ethPool)), 0, "pool burned its received wON");
        assertEq(won.totalSupply(), 1000 ether - amount, "totalSupply decreased by burn amount");
        assertEq(abi.decode(outBurn.destTokenAddress, (address)), address(onBsc));

        // OffRamp on BSC delivers — releases native ON to alice from the pool's locked balance.
        uint256 aliceBefore = onBsc.balanceOf(alice);

        Pool.ReleaseOrMintInV1 memory inRel = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(alice),
            remoteChainSelector: ETH_SELECTOR,
            receiver: alice,
            amount: amount,
            localToken: address(onBsc),
            sourcePoolAddress: abi.encode(address(ethPool)),
            sourcePoolData: outBurn.destPoolData,
            offchainTokenData: ""
        });
        vm.prank(bscOffRamp);
        bscPool.releaseOrMint(inRel);

        assertEq(onBsc.balanceOf(alice), aliceBefore + amount, "alice received native ON on BSC");
        assertEq(onBsc.balanceOf(address(bscPool)), 1000 ether - amount, "remaining locked");
    }

    // ─── Negative tests ────────────────────────────────────────────────────────

    function test_LockOrBurnRevertsWhenRMNCursed() public {
        ethRmn.setSubjectCurse(bytes16(uint128(BSC_SELECTOR)), true);

        // Curse check runs in `_validateLockOrBurn` before any token operation, so we don't need
        // to seed balance — the call must revert with `CursedByRMN` regardless.
        Pool.LockOrBurnInV1 memory inBurn = Pool.LockOrBurnInV1({
            receiver: abi.encode(alice),
            remoteChainSelector: BSC_SELECTOR,
            originalSender: alice,
            amount: 1 ether,
            localToken: address(won)
        });
        vm.prank(ethOnRamp);
        vm.expectRevert(TokenPool.CursedByRMN.selector);
        ethPool.lockOrBurn(inBurn);
    }

    function test_OnlyOnRampCanLock() public {
        // Random caller is not the registered OnRamp — pool must reject.
        vm.prank(alice);
        onBsc.transfer(address(bscPool), 1 ether);

        Pool.LockOrBurnInV1 memory inLock = Pool.LockOrBurnInV1({
            receiver: abi.encode(alice),
            remoteChainSelector: ETH_SELECTOR,
            originalSender: alice,
            amount: 1 ether,
            localToken: address(onBsc)
        });
        vm.prank(alice);
        vm.expectRevert();
        bscPool.lockOrBurn(inLock);
    }
}

