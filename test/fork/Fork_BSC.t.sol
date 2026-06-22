// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/pools/LockReleaseTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {Pool} from "@chainlink/contracts-ccip/libraries/Pool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";
import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/interfaces/IGetCCIPAdmin.sol";
import {IOwner} from "@chainlink/contracts-ccip/interfaces/IOwner.sol";
import {
    IERC20 as ICCIP_IERC20
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RegistryModuleOwnerCustom} from "@chainlink/contracts-ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";

/// @dev Extends IRouter with getOffRamps(), not in the minimal IRouter interface.
interface IRouterFull {
    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function getOnRamp(uint64 destChainSelector) external view returns (address);
    function getOffRamps() external view returns (OffRamp[] memory);
}

/// @notice Fork test against BNB Smart Chain mainnet.
///
/// Key goals:
///   1. Resolve the "known open item" in CLAUDE.md: definitively determine which admin
///      interface the canonical BSC ON token exposes (getCCIPAdmin / owner / neither).
///   2. Verify LockReleaseTokenPool deploys and wires correctly against live BSC infra.
///   3. Simulate both bridge directions using real CCIP OnRamp/OffRamp addresses.
///
/// Skipped automatically when BSC_RPC is not set.
contract Fork_BSC is Test {
    // ── Mainnet CCIP infrastructure (from https://docs.chain.link/ccip/directory) ──
    address internal constant BSC_ROUTER = 0x34B03Cb9086d7D758AC55af71584F81A598759FE;
    address internal constant BSC_RMN = 0x9e09697842194f77d315E0907F1Bda77922e8f84;
    address internal constant BSC_ADMIN_REGISTRY = 0x736Fd8660c443547a85e4Eaf70A49C1b7Bb008fc;
    address internal constant BSC_REGISTRY_MOD = 0x47Db76c9c97F4bcFd54D8872FDb848Cab696092d;
    address internal constant ON_BSC = 0x0e4F6209eD984b21EDEA43acE6e09559eD051D48;
    // Placeholder for the wON-on-ETH token. wON is not deployed in this single-chain BSC fork, so
    // the remote token registered for the ETH lane is a non-zero stand-in; lockOrBurn must echo it
    // back as destTokenAddress (asserted in test_Fork_BSC_BscToEth_Lock), mirroring how the ETH-side
    // fork asserts destTokenAddress == ON_BSC.
    address internal constant ON_ETH_WON = 0x000000000000000000000000000000000000c0DE; // placeholder (not deployed here)

    uint64 internal constant ETH_SELECTOR = 5_009_297_550_715_157_269;
    uint64 internal constant BSC_SELECTOR = 11_344_663_589_394_136_015;

    LockReleaseTokenPool internal bscPool;
    address internal deployer = makeAddr("deployer");
    address internal fakeRemoteEthPool;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // SECURITY: TEST-1 — pin to a specific block by default; override via BSC_FORK_BLOCK.
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(66_000_000));
        vm.createSelectFork(rpc, forkBlock);

        fakeRemoteEthPool = makeAddr("ethPoolPlaceholder");

        // Deploy BSC pool. CCIP 1.6.1 dropped the acceptLiquidity flag; leaving the rebalancer
        // unset keeps provideLiquidity/withdrawLiquidity disabled (both revert unless
        // msg.sender == s_rebalancer).
        vm.prank(deployer);
        bscPool = new LockReleaseTokenPool(ICCIP_IERC20(ON_BSC), 18, new address[](0), BSC_RMN, BSC_ROUTER);

        // Wire to ETH (placeholder remote pool address; filled by script 05 at deploy time).
        TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: ETH_SELECTOR,
            remotePoolAddresses: _remote(abi.encode(fakeRemoteEthPool)),
            remoteTokenAddress: abi.encode(ON_ETH_WON),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 100_000 ether, rate: 10 ether}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 100_000 ether, rate: 10 ether})
        });
        vm.prank(deployer);
        bscPool.applyChainUpdates(new uint64[](0), updates);
    }

    // ─── ON token ownership model (resolves the "known open item" in CLAUDE.md) ──

    /// @notice Probes which admin interface the canonical BSC ON token exposes.
    ///         The result determines which registration path script/04 will use.
    function test_Fork_BSC_TokenOwnershipModel() public {
        bool hasCCIPAdmin;
        bool hasOwnable;
        address ccipAdmin;
        address ownable;

        try IGetCCIPAdmin(ON_BSC).getCCIPAdmin() returns (address a) {
            hasCCIPAdmin = true;
            ccipAdmin = a;
        } catch {}

        try IOwner(ON_BSC).owner() returns (address a) {
            hasOwnable = true;
            ownable = a;
        } catch {}

        console.log("ON_BSC getCCIPAdmin:", hasCCIPAdmin ? "YES" : "NO", ccipAdmin);
        console.log("ON_BSC owner():", hasOwnable ? "YES" : "NO", ownable);

        assertTrue(
            hasCCIPAdmin || hasOwnable,
            "ON_BSC exposes neither getCCIPAdmin nor owner() - script/04 proposeAdministrator path required"
        );
    }

    // ─── Post-deploy state ────────────────────────────────────────────────────────

    function test_Fork_BSC_PoolWiring() public view {
        assertEq(bscPool.getRouter(), BSC_ROUTER);
        assertEq(bscPool.getRmnProxy(), BSC_RMN);
        assertTrue(bscPool.isSupportedChain(ETH_SELECTOR));

        assertEq(abi.decode(bscPool.getRemotePools(ETH_SELECTOR)[0], (address)), fakeRemoteEthPool);

        // CCIP 1.6.1: no `acceptLiquidity`/`canAcceptLiquidity`. With no rebalancer set,
        // provideLiquidity/withdrawLiquidity revert (gated on msg.sender == s_rebalancer).
        assertEq(bscPool.getRebalancer(), address(0), "no rebalancer => provide/withdrawLiquidity disabled");

        // `isEnabled = true` with `rate = 0` silently bricks the limiter — every transfer
        // would be blocked because the bucket never refills. Assert both rate and capacity
        // are strictly positive in addition to the enabled flag.
        RateLimiter.TokenBucket memory out = bscPool.getCurrentOutboundRateLimiterState(ETH_SELECTOR);
        RateLimiter.TokenBucket memory inb = bscPool.getCurrentInboundRateLimiterState(ETH_SELECTOR);
        assertTrue(out.isEnabled, "outbound limiter enabled");
        assertTrue(inb.isEnabled, "inbound limiter enabled");
        assertGt(out.capacity, 0, "outbound capacity > 0");
        assertGt(out.rate, 0, "outbound rate > 0");
        assertGt(inb.capacity, 0, "inbound capacity > 0");
        assertGt(inb.rate, 0, "inbound rate > 0");
    }

    // ─── Bridge direction 1: BSC → ETH (OnRamp locks ON) ────────────────────────

    function test_Fork_BSC_BscToEth_Lock() public {
        address alice = makeAddr("alice");
        uint256 amount = 1000 ether;

        address bscToEthOnRamp = IRouterFull(BSC_ROUTER).getOnRamp(ETH_SELECTOR);
        require(bscToEthOnRamp != address(0), "no ETH onRamp on BSC router");

        deal(ON_BSC, alice, amount);

        vm.prank(alice);
        IERC20(ON_BSC).transfer(address(bscPool), amount);

        assertEq(IERC20(ON_BSC).balanceOf(address(bscPool)), amount, "ON locked in BSC pool");

        vm.prank(bscToEthOnRamp);
        Pool.LockOrBurnOutV1 memory out = bscPool.lockOrBurn(
            Pool.LockOrBurnInV1({
                receiver: abi.encode(alice),
                remoteChainSelector: ETH_SELECTOR,
                originalSender: alice,
                amount: amount,
                localToken: ON_BSC
            })
        );

        // destTokenAddress is the remote token registered for the ETH lane (the wON address on
        // ETH). wON is not deployed in this single-chain fork, so it was wired as the ON_ETH_WON
        // placeholder in setUp; lockOrBurn must echo that exact value back.
        assertEq(
            abi.decode(out.destTokenAddress, (address)), ON_ETH_WON, "dest token must be the wired remote ETH token"
        );
    }

    // ─── Bridge direction 2: ETH → BSC (OffRamp releases ON) ────────────────────

    function test_Fork_BSC_EthToBsc_Release() public {
        address alice = makeAddr("alice");
        uint256 amount = 1000 ether;

        // Pre-fund BSC pool with ON so it has liquidity to release.
        deal(ON_BSC, address(bscPool), amount);

        address ethToBscOffRamp = _findOffRamp(BSC_ROUTER, ETH_SELECTOR);

        Pool.ReleaseOrMintInV1 memory in1 = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(alice),
            remoteChainSelector: ETH_SELECTOR,
            receiver: alice,
            sourceDenominatedAmount: amount,
            localToken: ON_BSC,
            sourcePoolAddress: abi.encode(fakeRemoteEthPool),
            sourcePoolData: "",
            offchainTokenData: ""
        });

        vm.prank(ethToBscOffRamp);
        Pool.ReleaseOrMintOutV1 memory out = bscPool.releaseOrMint(in1);

        assertEq(out.destinationAmount, amount, "released amount must equal bridged amount");
        assertEq(IERC20(ON_BSC).balanceOf(alice), amount, "alice receives ON");
        assertEq(IERC20(ON_BSC).balanceOf(address(bscPool)), 0, "pool drained");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

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
