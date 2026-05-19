// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBurnMintERC20} from "@chainlink/contracts-ccip/shared/token/ERC20/IBurnMintERC20.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/ccip/pools/BurnMintTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/ccip/pools/TokenPool.sol";
import {Pool} from "@chainlink/contracts-ccip/ccip/libraries/Pool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/ccip/libraries/RateLimiter.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {
    RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";

import {WrappedON} from "../../src/WrappedON.sol";

/// @dev Extends IRouter with getOffRamps(), which is not in the minimal IRouter interface.
interface IRouterFull {
    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function getOnRamp(uint64 destChainSelector) external view returns (address);
    function getOffRamps() external view returns (OffRamp[] memory);
}

/// @notice Fork test against Ethereum mainnet.
///
/// Deploys wON + BurnMintTokenPool against live CCIP infrastructure, registers in the real
/// TokenAdminRegistry, and simulates both bridge directions by impersonating the real OnRamp
/// and OffRamp addresses registered in the live router.
///
/// Skipped automatically when ETH_RPC is not set.
contract Fork_ETH is Test {
    // ── Mainnet CCIP infrastructure (from https://docs.chain.link/ccip/directory) ──
    address internal constant ETH_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address internal constant ETH_RMN = 0x411dE17f12D1A34ecC7F45f49844626267c75e81;
    address internal constant ETH_ADMIN_REGISTRY = 0xb22764f98dD05c789929716D677382Df22C05Cb6;
    address internal constant ETH_REGISTRY_MOD = 0x4855174e9479e211337832E109e7721d43F4cA64;
    address internal constant ON_ETH = 0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d;
    address internal constant ON_BSC = 0x0e4F6209eD984b21EDEA43acE6e09559eD051D48;

    uint64 internal constant ETH_SELECTOR = 5_009_297_550_715_157_269;
    uint64 internal constant BSC_SELECTOR = 11_344_663_589_394_136_015;

    WrappedON internal won;
    BurnMintTokenPool internal ethPool;
    address internal deployer = makeAddr("deployer");
    address internal fakeRemoteBscPool;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // SECURITY: TEST-1 — pin to a specific block by default so CCIP infra upgrades on
        // live mainnet can't silently change test behaviour. Operators can override via
        // ETH_FORK_BLOCK (e.g. to verify against a freshly observed registry). Update the
        // default deliberately when CCIP-side state changes warrant it.
        uint256 forkBlock = vm.envOr("ETH_FORK_BLOCK", uint256(22_000_000));
        vm.createSelectFork(rpc, forkBlock);

        fakeRemoteBscPool = makeAddr("bscPoolPlaceholder");

        vm.startPrank(deployer);
        won = new WrappedON(IERC20(ON_ETH), deployer);
        ethPool = new BurnMintTokenPool(IBurnMintERC20(address(won)), new address[](0), ETH_RMN, ETH_ROUTER);
        won.grantRole(won.MINTER_ROLE(), address(ethPool));
        won.grantRole(won.BURNER_ROLE(), address(ethPool));

        // Register wON in the real TokenAdminRegistry via getCCIPAdmin (deployer == ccipAdmin).
        RegistryModuleOwnerCustom(ETH_REGISTRY_MOD).registerAdminViaGetCCIPAdmin(address(won));
        TokenAdminRegistry(ETH_ADMIN_REGISTRY).acceptAdminRole(address(won));
        TokenAdminRegistry(ETH_ADMIN_REGISTRY).setPool(address(won), address(ethPool));

        // Wire ETH pool to BSC. Uses a placeholder remote pool address because the real BSC pool
        // is not deployed here; the address is filled in at actual deploy time via script 05.
        TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: BSC_SELECTOR,
            allowed: true,
            remotePoolAddress: abi.encode(fakeRemoteBscPool),
            remoteTokenAddress: abi.encode(ON_BSC),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 100_000 ether, rate: 10 ether}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 100_000 ether, rate: 10 ether})
        });
        ethPool.applyChainUpdates(updates);
        vm.stopPrank();
    }

    // ─── Post-deploy state ────────────────────────────────────────────────────────

    function test_Fork_ETH_RegistryMapping() public view {
        assertEq(
            TokenAdminRegistry(ETH_ADMIN_REGISTRY).getPool(address(won)),
            address(ethPool),
            "registry must map wON to ethPool"
        );
        assertTrue(won.hasRole(won.MINTER_ROLE(), address(ethPool)));
        assertTrue(won.hasRole(won.BURNER_ROLE(), address(ethPool)));
        assertEq(won.getCCIPAdmin(), deployer);
    }

    function test_Fork_ETH_PoolWiring() public view {
        assertEq(ethPool.getRouter(), ETH_ROUTER);
        assertEq(ethPool.getRmnProxy(), ETH_RMN);
        assertTrue(ethPool.isSupportedChain(BSC_SELECTOR));

        assertEq(abi.decode(ethPool.getRemotePool(BSC_SELECTOR), (address)), fakeRemoteBscPool);

        // `isEnabled = true` with `rate = 0` silently bricks the limiter — every transfer
        // would be blocked because the bucket never refills. Assert both rate and capacity
        // are strictly positive in addition to the enabled flag.
        RateLimiter.TokenBucket memory out = ethPool.getCurrentOutboundRateLimiterState(BSC_SELECTOR);
        RateLimiter.TokenBucket memory inb = ethPool.getCurrentInboundRateLimiterState(BSC_SELECTOR);
        assertTrue(out.isEnabled, "outbound limiter enabled");
        assertTrue(inb.isEnabled, "inbound limiter enabled");
        assertGt(out.capacity, 0, "outbound capacity > 0");
        assertGt(out.rate, 0, "outbound rate > 0");
        assertGt(inb.capacity, 0, "inbound capacity > 0");
        assertGt(inb.rate, 0, "inbound rate > 0");
    }

    // ─── Bridge direction 1: BSC → ETH (OffRamp mints wON) ───────────────────────

    function test_Fork_ETH_BscToEth_Mint() public {
        address bscToEthOffRamp = _findOffRamp(ETH_ROUTER, BSC_SELECTOR);
        address alice = makeAddr("alice");
        uint256 amount = 1000 ether;

        Pool.ReleaseOrMintInV1 memory in1 = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(alice),
            remoteChainSelector: BSC_SELECTOR,
            receiver: alice,
            amount: amount,
            localToken: address(won),
            sourcePoolAddress: abi.encode(fakeRemoteBscPool),
            sourcePoolData: "",
            offchainTokenData: ""
        });

        vm.prank(bscToEthOffRamp);
        Pool.ReleaseOrMintOutV1 memory out = ethPool.releaseOrMint(in1);

        assertEq(out.destinationAmount, amount, "minted amount must equal bridged amount");
        assertEq(won.balanceOf(alice), amount, "alice receives wON");
        assertEq(won.totalSupply(), amount);
    }

    // ─── Bridge direction 2: ETH → BSC (OnRamp burns wON) ───────────────────────

    function test_Fork_ETH_EthToBsc_Burn() public {
        address alice = makeAddr("alice");
        uint256 amount = 500 ether;

        // Seed alice with wON via a simulated BSC→ETH mint.
        address bscToEthOffRamp = _findOffRamp(ETH_ROUTER, BSC_SELECTOR);
        vm.prank(bscToEthOffRamp);
        ethPool.releaseOrMint(
            Pool.ReleaseOrMintInV1({
                originalSender: abi.encode(alice),
                remoteChainSelector: BSC_SELECTOR,
                receiver: alice,
                amount: amount,
                localToken: address(won),
                sourcePoolAddress: abi.encode(fakeRemoteBscPool),
                sourcePoolData: "",
                offchainTokenData: ""
            })
        );

        address ethToBscOnRamp = IRouterFull(ETH_ROUTER).getOnRamp(BSC_SELECTOR);
        require(ethToBscOnRamp != address(0), "no BSC onRamp on ETH router");

        vm.prank(alice);
        won.transfer(address(ethPool), amount);

        vm.prank(ethToBscOnRamp);
        Pool.LockOrBurnOutV1 memory out = ethPool.lockOrBurn(
            Pool.LockOrBurnInV1({
                receiver: abi.encode(alice),
                remoteChainSelector: BSC_SELECTOR,
                originalSender: alice,
                amount: amount,
                localToken: address(won)
            })
        );

        assertEq(won.balanceOf(address(ethPool)), 0, "pool burned all received wON");
        assertEq(won.totalSupply(), 0, "supply returns to zero after full roundtrip");
        assertEq(abi.decode(out.destTokenAddress, (address)), ON_BSC, "dest token must be BSC ON");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

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
