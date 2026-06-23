// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BurnMintTokenPool} from "@chainlink/contracts-ccip/pools/BurnMintTokenPool.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/pools/LockReleaseTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {Pool} from "@chainlink/contracts-ccip/libraries/Pool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";
import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {
    IERC20 as ICCIP_IERC20
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {DeployWON} from "./helpers/DeployWON.sol";
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
    MockON internal onEth; // canonical ON on the ETH side (state variable for deal/approve access)

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
        // placeholder ERC20 with no supply is fine (except in the auto-unwrap test).
        onEth = new MockON("ON", 0, address(0xdead));
        won = DeployWON.deploy(IERC20(address(onEth)), admin, admin);
        ethPool = new BurnMintTokenPool(
            IBurnMintERC20(address(won)), 18, new address[](0), address(ethRmn), address(ethRouter)
        );

        // Pool gets MINTER+BURNER on wON.
        vm.startPrank(admin);
        won.grantRole(won.MINTER_ROLE(), address(ethPool));
        won.grantRole(won.BURNER_ROLE(), address(ethPool));
        vm.stopPrank();

        // ── BSC side deploy ─────────────────────────────────────────────────
        bscPool = new LockReleaseTokenPool(
            ICCIP_IERC20(address(onBsc)), 18, new address[](0), address(bscRmn), address(bscRouter)
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
            remotePoolAddresses: _remote(abi.encode(address(bscPool))),
            remoteTokenAddress: abi.encode(address(onBsc)),
            outboundRateLimiterConfig: _limit(100_000 ether, 10 ether),
            inboundRateLimiterConfig: _limit(100_000 ether, 10 ether)
        });
        ethPool.applyChainUpdates(new uint64[](0), ethToBsc);

        TokenPool.ChainUpdate[] memory bscToEth = new TokenPool.ChainUpdate[](1);
        bscToEth[0] = TokenPool.ChainUpdate({
            remoteChainSelector: ETH_SELECTOR,
            remotePoolAddresses: _remote(abi.encode(address(ethPool))),
            remoteTokenAddress: abi.encode(address(won)),
            outboundRateLimiterConfig: _limit(100_000 ether, 10 ether),
            inboundRateLimiterConfig: _limit(100_000 ether, 10 ether)
        });
        bscPool.applyChainUpdates(new uint64[](0), bscToEth);
    }

    function _remote(bytes memory poolAddr) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = poolAddr;
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
            sourceDenominatedAmount: amount,
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

    /// @notice Issue #1 (pool-level): when the wON wrap reserve fully covers a BSC→ETH arrival,
    ///         `mint` auto-unwraps — delivering native ON to the receiver and minting 0 wON.
    ///         `totalSupply` is unchanged and `ccipMintHeadroomUsed` stays at zero.
    ///
    ///         Differences from `test_BscToEth_LockAndMint`: alice seeds the reserve via
    ///         `deposit` before the OffRamp call, a fresh `carol` receives the bridged amount,
    ///         and the assertions check native ON rather than wON.
    function test_BscToEth_AutoUnwrapWhenReserveCovers() public {
        uint256 amount = 1000 ether;
        address carol = makeAddr("carol");

        // Give alice enough onEth to seed the reserve, then deposit into wON.
        deal(address(onEth), alice, amount);
        vm.startPrank(alice);
        onEth.approve(address(won), amount);
        won.deposit(amount);
        vm.stopPrank();

        // Capture state AFTER alice's deposit: totalSupply == amount (alice holds wON),
        // reserve == amount. The auto-unwrap test will leave totalSupply unchanged.
        uint256 supplyBefore = won.totalSupply();
        uint256 carolOnBefore = onEth.balanceOf(carol);

        // OffRamp delivers 1000 ON worth from BSC to carol on ETH.
        // sourcePoolData is empty — BurnMintTokenPool accepts it for mint paths.
        Pool.ReleaseOrMintInV1 memory inMint = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(carol),
            remoteChainSelector: BSC_SELECTOR,
            receiver: carol,
            sourceDenominatedAmount: amount,
            localToken: address(won),
            sourcePoolAddress: abi.encode(address(bscPool)),
            sourcePoolData: "",
            offchainTokenData: ""
        });
        vm.prank(ethOffRamp);
        Pool.ReleaseOrMintOutV1 memory outMint = ethPool.releaseOrMint(inMint);

        assertEq(outMint.destinationAmount, amount, "destinationAmount");
        assertEq(onEth.balanceOf(carol), carolOnBefore + amount, "carol got native ON");
        assertEq(won.balanceOf(carol), 0, "no wON minted to carol");
        assertEq(won.totalSupply(), supplyBefore, "totalSupply unchanged (auto-unwrap)");
        assertEq(won.ccipMintHeadroomUsed(), 0, "cap counter untouched");
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
            sourceDenominatedAmount: amount,
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

    /// @notice TEST-17: BSC pool's outbound `lockOrBurn` must also halt under an RMN curse.
    ///         TEST-15 covered ETH-side outbound + inbound; this pins the BSC-side outbound
    ///         leg directly — a regression that patched only the ETH pool's curse wiring
    ///         would still pass TEST-15 but allow BSC users to lock through a curse.
    function test_BscLockOrBurnRevertsWhenRMNCursed() public {
        bscRmn.setSubjectCurse(bytes16(uint128(ETH_SELECTOR)), true);

        Pool.LockOrBurnInV1 memory inLock = Pool.LockOrBurnInV1({
            receiver: abi.encode(alice),
            remoteChainSelector: ETH_SELECTOR,
            originalSender: alice,
            amount: 1 ether,
            localToken: address(onBsc)
        });
        vm.prank(bscOnRamp);
        vm.expectRevert(TokenPool.CursedByRMN.selector);
        bscPool.lockOrBurn(inLock);
    }

    /// @notice TEST-15: an RMN curse must also block the inbound path. The outbound test
    ///         above hits `_validateLockOrBurn`; the inbound path enters via
    ///         `_validateReleaseOrMint`, which runs an independent curse check against the
    ///         source-chain selector. A regression that only patched one direction would
    ///         pass `test_LockOrBurnRevertsWhenRMNCursed` while silently letting funds
    ///         arrive under a curse.
    function test_ReleaseOrMintRevertsWhenRMNCursed() public {
        // Curse the source-chain selector on the destination's RMN.
        ethRmn.setSubjectCurse(bytes16(uint128(BSC_SELECTOR)), true);

        Pool.ReleaseOrMintInV1 memory inMint = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(alice),
            remoteChainSelector: BSC_SELECTOR,
            receiver: alice,
            sourceDenominatedAmount: 1 ether,
            localToken: address(won),
            sourcePoolAddress: abi.encode(address(bscPool)),
            sourcePoolData: "",
            offchainTokenData: ""
        });
        vm.prank(ethOffRamp);
        vm.expectRevert(TokenPool.CursedByRMN.selector);
        ethPool.releaseOrMint(inMint);
    }

    function test_OnlyOnRampCanLock() public {
        // Random caller is not the registered OnRamp — pool must reject.
        // SECURITY: TEST-3 — assert the typed CCIP error so a regression in the
        // `_validateLockOrBurn` access-control path is caught.
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
        vm.expectRevert(abi.encodeWithSelector(TokenPool.CallerIsNotARampOnRouter.selector, alice));
        bscPool.lockOrBurn(inLock);
    }

    // ─── Rate-limit exhaustion ─────────────────────────────────────────────────

    /// @notice An over-capacity `lockOrBurn` reverts with `TokenMaxCapacityExceeded`. With
    ///         the test rig's 100k-ether capacity and 10-ether-per-second refill, a single
    ///         100,001 ether transfer must hit the cap.
    function test_RateLimitBucketExhaustionReverts() public {
        uint256 over = 100_001 ether;
        vm.prank(alice);
        onBsc.transfer(address(bscPool), over);

        Pool.LockOrBurnInV1 memory inLock = Pool.LockOrBurnInV1({
            receiver: abi.encode(alice),
            remoteChainSelector: ETH_SELECTOR,
            originalSender: alice,
            amount: over,
            localToken: address(onBsc)
        });
        vm.prank(bscOnRamp);
        vm.expectRevert(
            abi.encodeWithSelector(RateLimiter.TokenMaxCapacityExceeded.selector, 100_000 ether, over, address(onBsc))
        );
        bscPool.lockOrBurn(inLock);
    }

    /// @notice Draining the bucket to zero then immediately retrying reverts with
    ///         `TokenRateLimitReached`. After a sufficient time advance the bucket refills
    ///         (rate-per-second), unblocking subsequent transfers — proves the bucket isn't
    ///         a one-shot kill switch.
    function test_RateLimitBucketRefillsOverTime() public {
        // Drain: lock exactly capacity (100k) — bucket goes to ~0.
        uint256 cap = 100_000 ether;
        vm.prank(alice);
        onBsc.transfer(address(bscPool), cap);

        Pool.LockOrBurnInV1 memory inLock = Pool.LockOrBurnInV1({
            receiver: abi.encode(alice),
            remoteChainSelector: ETH_SELECTOR,
            originalSender: alice,
            amount: cap,
            localToken: address(onBsc)
        });
        vm.prank(bscOnRamp);
        bscPool.lockOrBurn(inLock);

        // Try to lock 1 more ether immediately — bucket is empty, must revert.
        vm.prank(alice);
        onBsc.transfer(address(bscPool), 1 ether);
        Pool.LockOrBurnInV1 memory inLock2 = Pool.LockOrBurnInV1({
            receiver: abi.encode(alice),
            remoteChainSelector: ETH_SELECTOR,
            originalSender: alice,
            amount: 1 ether,
            localToken: address(onBsc)
        });
        vm.prank(bscOnRamp);
        // SECURITY: TEST-3 — `expectPartialRevert(selector)` matches by 4-byte prefix so
        // the time-dependent `minWait` arg doesn't have to be predicted.
        vm.expectPartialRevert(RateLimiter.TokenRateLimitReached.selector);
        bscPool.lockOrBurn(inLock2);

        // Advance enough time to refill 1 ether at the 10-ether-per-second rate.
        vm.warp(block.timestamp + 1);
        vm.prank(bscOnRamp);
        bscPool.lockOrBurn(inLock2); // must succeed after refill
    }

    /// @notice SECURITY: TEST-4 — fuzz the bucket refill math across drain amounts and
    ///         elapsed times. The token-bucket arithmetic is `tokens += elapsed * rate`
    ///         capped at `capacity`. Drain by a fuzzed amount, advance a fuzzed time,
    ///         then assert the available headroom matches `min(drainAmt, elapsed * rate)`.
    ///         Reaches off-by-one / rounding regimes the spot-check at
    ///         `test_RateLimitBucketRefillsOverTime` can't.
    function testFuzz_RateLimitRefillMath(uint128 drainAmt, uint40 elapsedSeconds) public {
        uint128 capacity = 100_000 ether;
        uint128 rate = 10 ether;
        drainAmt = uint128(bound(uint256(drainAmt), 1, capacity));
        elapsedSeconds = uint40(bound(uint256(elapsedSeconds), 0, 100_000));

        // Drain the outbound bucket by `drainAmt`.
        vm.prank(alice);
        onBsc.transfer(address(bscPool), drainAmt);
        Pool.LockOrBurnInV1 memory inLock = Pool.LockOrBurnInV1({
            receiver: abi.encode(alice),
            remoteChainSelector: ETH_SELECTOR,
            originalSender: alice,
            amount: drainAmt,
            localToken: address(onBsc)
        });
        vm.prank(bscOnRamp);
        bscPool.lockOrBurn(inLock);

        // After the drain, the bucket's `tokens` equals `capacity - drainAmt`. Warp.
        vm.warp(block.timestamp + elapsedSeconds);

        RateLimiter.TokenBucket memory bucket = bscPool.getCurrentOutboundRateLimiterState(ETH_SELECTOR);
        uint256 expected = uint256(capacity) - uint256(drainAmt) + uint256(elapsedSeconds) * uint256(rate);
        if (expected > capacity) {
            expected = capacity;
        }
        assertEq(uint256(bucket.tokens), expected, "bucket refill math drifted");
    }

    /// @notice Outbound-rate-limit disabled means transfers above capacity flow through —
    ///         the operator can disable a single direction independently.
    function test_RateLimitDisabledAllowsLargeTransfer() public {
        // Owner disables outbound only.
        RateLimiter.Config memory off = RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0});
        RateLimiter.Config memory on = _limit(100_000 ether, 10 ether);
        bscPool.setChainRateLimiterConfig(ETH_SELECTOR, off, on);

        uint256 huge = 5_000_000 ether;
        vm.prank(alice);
        onBsc.transfer(address(bscPool), huge);

        Pool.LockOrBurnInV1 memory inLock = Pool.LockOrBurnInV1({
            receiver: abi.encode(alice),
            remoteChainSelector: ETH_SELECTOR,
            originalSender: alice,
            amount: huge,
            localToken: address(onBsc)
        });
        vm.prank(bscOnRamp);
        bscPool.lockOrBurn(inLock);
        assertEq(onBsc.balanceOf(address(bscPool)), huge);
    }
}

