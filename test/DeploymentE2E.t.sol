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
    IERC20 as CCIP_IERC20
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {
    RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenPool as ITokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";

import {WrappedON} from "../src/WrappedON.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockRMN} from "./mocks/MockRMN.sol";

contract MockON is ERC20 {
    constructor(string memory s, uint256 supply, address to) ERC20("Orochi Network", s) {
        _mint(to, supply);
    }
}

/// @notice End-to-end simulation of the production deployment sequence on a single Foundry test.
///         Reproduces the script logic from 01-05 + the post-deploy checks from 08 across
///         realistic mock CCIP infrastructure on both "Ethereum" and "BSC" sides, then runs
///         a full bridge roundtrip to confirm the wired system actually works.
///
///         If this test ever regresses, the live deployment will too.
contract DeploymentE2ETest is Test {
    uint64 internal constant ETH_SELECTOR = 5_009_297_550_715_157_269;
    uint64 internal constant BSC_SELECTOR = 11_344_663_589_394_136_015;
    uint128 internal constant CAPACITY = 100_000 ether;
    uint128 internal constant RATE = 10 ether;

    // ── ETH side ────────────────────────────────────────────────────────────
    WrappedON internal won;
    BurnMintTokenPool internal ethPool;
    MockRouter internal ethRouter;
    MockRMN internal ethRmn;
    TokenAdminRegistry internal ethRegistry;
    RegistryModuleOwnerCustom internal ethRegistryModule;
    MockON internal onEth;
    address internal ethOnRamp = makeAddr("ethOnRamp");
    address internal ethOffRamp = makeAddr("ethOffRamp");

    // ── BSC side ────────────────────────────────────────────────────────────
    MockON internal onBsc;
    LockReleaseTokenPool internal bscPool;
    MockRouter internal bscRouter;
    MockRMN internal bscRmn;
    TokenAdminRegistry internal bscRegistry;
    RegistryModuleOwnerCustom internal bscRegistryModule;
    address internal bscOnRamp = makeAddr("bscOnRamp");
    address internal bscOffRamp = makeAddr("bscOffRamp");

    // ── Actors ──────────────────────────────────────────────────────────────
    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");
    address internal bscTokenOwner = makeAddr("bscTokenOwner"); // owner of the canonical ON on BSC

    function setUp() public {
        // ─── Infrastructure (CCIP-side, deployed by Chainlink) ───────────────
        ethRouter = new MockRouter();
        bscRouter = new MockRouter();
        ethRmn = new MockRMN();
        bscRmn = new MockRMN();
        ethRegistry = new TokenAdminRegistry();
        bscRegistry = new TokenAdminRegistry();
        ethRegistryModule = new RegistryModuleOwnerCustom(address(ethRegistry));
        bscRegistryModule = new RegistryModuleOwnerCustom(address(bscRegistry));
        ethRegistry.addRegistryModule(address(ethRegistryModule));
        bscRegistry.addRegistryModule(address(bscRegistryModule));

        // ─── Canonical ON tokens (pre-existing on each chain) ────────────────
        onEth = new MockON("ON", 600_000_000 ether, alice);
        vm.prank(bscTokenOwner);
        onBsc = new MockON("ON", 100_000_000 ether, alice);

        // ─── Wire mock ramps so pools recognise them ─────────────────────────
        ethRouter.setOnRamp(BSC_SELECTOR, ethOnRamp);
        ethRouter.setOffRamp(BSC_SELECTOR, ethOffRamp, true);
        bscRouter.setOnRamp(ETH_SELECTOR, bscOnRamp);
        bscRouter.setOffRamp(ETH_SELECTOR, bscOffRamp, true);

        // ─── Run the full deployment sequence as the deployer ────────────────
        _run01_deployWrappedON();
        _run02_deployPools();
        _run03_grantRoles();
        _run04_registerAdminAndPool();
        _run05_applyChainUpdates();
    }

    // ─── Script reproductions ────────────────────────────────────────────────

    /// @dev Mirrors `script/01_DeployWrappedON.s.sol` — ETH side only.
    function _run01_deployWrappedON() internal {
        vm.prank(deployer);
        won = new WrappedON(IERC20(address(onEth)), deployer);
    }

    /// @dev Mirrors `script/02_DeployPools.s.sol` for both chains.
    function _run02_deployPools() internal {
        vm.prank(deployer);
        ethPool =
            new BurnMintTokenPool(IBurnMintERC20(address(won)), 18, new address[](0), address(ethRmn), address(ethRouter));

        vm.prank(bscTokenOwner);
        bscPool = new LockReleaseTokenPool(
            CCIP_IERC20(address(onBsc)),
            18, // localTokenDecimals (ON is 18)
            new address[](0),
            address(bscRmn),
            // CCIP 1.6.1 removed the acceptLiquidity flag; no rebalancer set => provideLiquidity disabled
            address(bscRouter)
        );
    }

    /// @dev Mirrors `script/03_GrantRoles.s.sol` — ETH side only.
    function _run03_grantRoles() internal {
        vm.startPrank(deployer);
        won.grantRole(won.MINTER_ROLE(), address(ethPool));
        won.grantRole(won.BURNER_ROLE(), address(ethPool));
        vm.stopPrank();
    }

    /// @dev Mirrors `script/04_RegisterAdminAndPool.s.sol` for both chains.
    function _run04_registerAdminAndPool() internal {
        // ETH side: wON exposes getCCIPAdmin, which returns deployer.
        vm.startPrank(deployer);
        ethRegistryModule.registerAdminViaGetCCIPAdmin(address(won));
        ethRegistry.acceptAdminRole(address(won));
        ethRegistry.setPool(address(won), address(ethPool));
        vm.stopPrank();

        // BSC side: our MockON is OZ ERC20 with no owner(); use direct proposeAdministrator.
        // In production this branch is the `proposeAdministrator` fallback documented in
        // script 04 (when the canonical ON exposes neither `getCCIPAdmin` nor `Ownable.owner`
        // matching the deployer).
        bscRegistry.proposeAdministrator(address(onBsc), bscTokenOwner);
        vm.startPrank(bscTokenOwner);
        bscRegistry.acceptAdminRole(address(onBsc));
        bscRegistry.setPool(address(onBsc), address(bscPool));
        vm.stopPrank();
    }

    /// @dev Mirrors `script/05_ApplyChainUpdates.s.sol` for both chains.
    function _run05_applyChainUpdates() internal {
        TokenPool.ChainUpdate[] memory ethToBsc = new TokenPool.ChainUpdate[](1);
        ethToBsc[0] = TokenPool.ChainUpdate({
            remoteChainSelector: BSC_SELECTOR,
            remotePoolAddresses: _remote(abi.encode(address(bscPool))),
            remoteTokenAddress: abi.encode(address(onBsc)),
            outboundRateLimiterConfig: _limit(),
            inboundRateLimiterConfig: _limit()
        });
        vm.prank(deployer);
        ethPool.applyChainUpdates(new uint64[](0), ethToBsc);

        TokenPool.ChainUpdate[] memory bscToEth = new TokenPool.ChainUpdate[](1);
        bscToEth[0] = TokenPool.ChainUpdate({
            remoteChainSelector: ETH_SELECTOR,
            remotePoolAddresses: _remote(abi.encode(address(ethPool))),
            remoteTokenAddress: abi.encode(address(won)),
            outboundRateLimiterConfig: _limit(),
            inboundRateLimiterConfig: _limit()
        });
        vm.prank(bscTokenOwner);
        bscPool.applyChainUpdates(new uint64[](0), bscToEth);
    }

    function _limit() internal pure returns (RateLimiter.Config memory) {
        return RateLimiter.Config({isEnabled: true, capacity: CAPACITY, rate: RATE});
    }

    /// @dev CCIP 1.6.1 `ChainUpdate.remotePoolAddresses` is `bytes[]`; wrap a single encoded pool.
    function _remote(bytes memory poolAddr) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = poolAddr;
    }

    // ─── Post-deploy verification (mirrors script/08) ────────────────────────

    function test_E2E_PostDeployState() public view {
        // Registry → pool mapping resolves on each chain
        assertEq(ethRegistry.getPool(address(won)), address(ethPool), "ETH registry pool");
        assertEq(bscRegistry.getPool(address(onBsc)), address(bscPool), "BSC registry pool");

        // Pool router + RMN
        assertEq(ethPool.getRouter(), address(ethRouter));
        assertEq(ethPool.getRmnProxy(), address(ethRmn));
        assertEq(bscPool.getRouter(), address(bscRouter));
        assertEq(bscPool.getRmnProxy(), address(bscRmn));

        // Remote chain links both directions
        assertTrue(ethPool.isSupportedChain(BSC_SELECTOR));
        assertTrue(bscPool.isSupportedChain(ETH_SELECTOR));

        assertEq(abi.decode(ethPool.getRemotePools(BSC_SELECTOR)[0], (address)), address(bscPool));
        assertEq(abi.decode(bscPool.getRemotePools(ETH_SELECTOR)[0], (address)), address(ethPool));

        assertEq(abi.decode(ethPool.getRemoteToken(BSC_SELECTOR), (address)), address(onBsc));
        assertEq(abi.decode(bscPool.getRemoteToken(ETH_SELECTOR), (address)), address(won));

        // Rate limits enabled both directions both chains
        assertTrue(ethPool.getCurrentOutboundRateLimiterState(BSC_SELECTOR).isEnabled);
        assertTrue(ethPool.getCurrentInboundRateLimiterState(BSC_SELECTOR).isEnabled);
        assertTrue(bscPool.getCurrentOutboundRateLimiterState(ETH_SELECTOR).isEnabled);
        assertTrue(bscPool.getCurrentInboundRateLimiterState(ETH_SELECTOR).isEnabled);

        // wON roles wired to the ETH pool
        assertTrue(won.hasRole(won.MINTER_ROLE(), address(ethPool)));
        assertTrue(won.hasRole(won.BURNER_ROLE(), address(ethPool)));
    }

    // ─── Bridge roundtrip on top of the deployed system ──────────────────────

    function test_E2E_BridgeRoundtrip() public {
        uint256 amount = 1000 ether;

        // BSC → ETH: lock ON on BSC, mint wON on ETH
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
        ethPool.releaseOrMint(inMint);

        assertEq(won.balanceOf(alice), amount);
        assertEq(onBsc.balanceOf(address(bscPool)), amount);

        // ETH → BSC: burn wON on ETH, release ON on BSC
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

        uint256 aliceBscBefore = onBsc.balanceOf(alice);
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

        assertEq(won.balanceOf(alice), 0);
        assertEq(won.totalSupply(), 0);
        assertEq(onBsc.balanceOf(alice), aliceBscBefore + amount);
        assertEq(onBsc.balanceOf(address(bscPool)), 0);
    }

    // ─── Ownership handoff (mirrors script/06 + 08 multisig check) ───────────

    function test_E2E_OwnershipHandoff() public {
        // Initial: deployer owns pool, holds wON admin role.
        assertEq(ethPool.owner(), deployer);
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();
        assertTrue(won.hasRole(adminRole, deployer));

        // Begin handoff: transferOwnership + grant admin + propose CCIP admin + transferAdminRole.
        vm.startPrank(deployer);
        ethPool.transferOwnership(multisig);
        won.grantRole(adminRole, multisig);
        won.setCCIPAdmin(multisig); // two-step: now pending
        ethRegistry.transferAdminRole(address(won), multisig);
        vm.stopPrank();

        // Multisig accepts each role (including the two-step CCIP admin).
        vm.startPrank(multisig);
        ethPool.acceptOwnership();
        ethRegistry.acceptAdminRole(address(won));
        won.acceptCCIPAdmin();
        vm.stopPrank();

        // Final step: deployer renounces wON admin role.
        vm.prank(deployer);
        won.renounceRole(adminRole, deployer);

        // Verification — multisig has full control, deployer is out.
        assertEq(ethPool.owner(), multisig);
        assertEq(won.getCCIPAdmin(), multisig);
        assertTrue(won.hasRole(adminRole, multisig));
        assertFalse(won.hasRole(adminRole, deployer));
    }

    // ─── Rate-limit update (mirrors script/07) ───────────────────────────────

    function test_E2E_UpdateRateLimits() public {
        uint128 newCap = 500_000 ether;
        uint128 newRate = 50 ether;

        RateLimiter.Config memory newOutbound = RateLimiter.Config({isEnabled: true, capacity: newCap, rate: newRate});
        RateLimiter.Config memory newInbound = RateLimiter.Config({isEnabled: true, capacity: newCap, rate: newRate});

        vm.prank(deployer);
        ethPool.setChainRateLimiterConfig(BSC_SELECTOR, newOutbound, newInbound);

        RateLimiter.TokenBucket memory outBucket = ethPool.getCurrentOutboundRateLimiterState(BSC_SELECTOR);
        assertEq(outBucket.capacity, newCap);
        assertEq(outBucket.rate, newRate);
        assertTrue(outBucket.isEnabled);
    }

    // ─── Ownership handoff mid-state ──────────────────────────────────────────

    function test_E2E_HandoffTransitionState() public {
        // Before any handoff: deployer owns the pool and holds wON admin.
        assertEq(ethPool.owner(), deployer);
        assertTrue(won.hasRole(won.DEFAULT_ADMIN_ROLE(), deployer));

        // Initiate transfer — deployer calls transferOwnership but multisig has NOT accepted yet.
        vm.prank(deployer);
        ethPool.transferOwnership(multisig);

        // Pool ownership has NOT moved: owner() is still deployer.
        assertEq(ethPool.owner(), deployer, "owner must remain deployer until multisig accepts");

        // Deployer can still exercise owner-only privileges during the transition window.
        vm.prank(deployer);
        ethPool.setChainRateLimiterConfig(
            BSC_SELECTOR,
            RateLimiter.Config({isEnabled: true, capacity: 200_000 ether, rate: 20 ether}),
            RateLimiter.Config({isEnabled: true, capacity: 200_000 ether, rate: 20 ether})
        );
        assertEq(ethPool.getCurrentOutboundRateLimiterState(BSC_SELECTOR).capacity, 200_000 ether);

        // Multisig cannot act as owner before calling acceptOwnership.
        // SECURITY: TEST-3 — `setChainRateLimiterConfig` gates on `owner() || rateLimitAdmin`
        // and reverts `Unauthorized(caller)` for anyone else. Match the selector via
        // expectPartialRevert so the caller-arg doesn't have to be threaded through.
        vm.prank(multisig);
        vm.expectPartialRevert(ITokenPool.Unauthorized.selector);
        ethPool.setChainRateLimiterConfig(
            BSC_SELECTOR,
            RateLimiter.Config({isEnabled: true, capacity: 1 ether, rate: 1 ether}),
            RateLimiter.Config({isEnabled: true, capacity: 1 ether, rate: 1 ether})
        );

        // Multisig accepts — ownership transfers.
        vm.prank(multisig);
        ethPool.acceptOwnership();
        assertEq(ethPool.owner(), multisig);
    }

    // ─── BSC-side ownership handoff ──────────────────────────────────────────

    /// @notice Sibling to `test_E2E_OwnershipHandoff` — exercises the BSC pool's
    ///         Ownable transfer + TokenAdminRegistry transferAdminRole on the BSC side.
    ///         wON does not exist on BSC, so no DEFAULT_ADMIN_ROLE handoff here — but the
    ///         two two-step transitions (pool Ownable, registry admin) must both go
    ///         through correctly, AND the BSC pool's `setRebalancer` / `withdrawLiquidity`
    ///         path (the Chainlink CCT trust model) must move from deployer-controlled
    ///         to multisig-controlled.
    function test_E2E_BSCOwnershipHandoff() public {
        // The BSC pool was deployed by `bscTokenOwner` in setUp (see _run02_deployPools).
        assertEq(bscPool.owner(), bscTokenOwner, "initial BSC pool owner == bscTokenOwner");

        // BSC registry admin was set to bscTokenOwner in _run04_registerAdminAndPool.
        assertEq(bscRegistry.getTokenConfig(address(onBsc)).administrator, bscTokenOwner);

        // Begin handoff on BSC side — bscTokenOwner transfers pool ownership + registry admin.
        vm.startPrank(bscTokenOwner);
        bscPool.transferOwnership(multisig);
        bscRegistry.transferAdminRole(address(onBsc), multisig);
        vm.stopPrank();

        // Mid-state: pool.owner still bscTokenOwner (two-step requires accept).
        assertEq(bscPool.owner(), bscTokenOwner, "owner unchanged until multisig accepts");

        // BSC token registry: transfer is also two-step in CCIP's TokenAdminRegistry.
        // Pending administrator is now multisig; current administrator still bscTokenOwner.
        assertEq(bscRegistry.getTokenConfig(address(onBsc)).pendingAdministrator, multisig);
        assertEq(bscRegistry.getTokenConfig(address(onBsc)).administrator, bscTokenOwner);

        // Multisig accepts both.
        vm.startPrank(multisig);
        bscPool.acceptOwnership();
        bscRegistry.acceptAdminRole(address(onBsc));
        vm.stopPrank();

        // Final state: multisig holds pool ownership + registry admin role.
        assertEq(bscPool.owner(), multisig, "BSC pool ownership == multisig");
        assertEq(bscRegistry.getTokenConfig(address(onBsc)).administrator, multisig);

        // Trust-model verification: after handoff the multisig CAN call
        // setRebalancer + withdrawLiquidity (designed Chainlink CCT pattern).
        // Sanity-check: bscTokenOwner cannot, multisig can.
        // SECURITY: TEST-3 — `setRebalancer` is `onlyOwner`; CCIP 1.6.1's Ownable2StepMsgSender
        // reverts with the custom error `OnlyCallableByOwner()` (1.5.x used the string
        // "Only callable by owner").
        vm.prank(bscTokenOwner);
        vm.expectRevert(abi.encodeWithSignature("OnlyCallableByOwner()"));
        bscPool.setRebalancer(bscTokenOwner);

        vm.prank(multisig);
        bscPool.setRebalancer(multisig);
        assertEq(bscPool.getRebalancer(), multisig, "rebalancer is settable by new owner");
    }

    /// @notice CCIP 1.6.1 dropped the `acceptLiquidity` flag; with NO rebalancer set at launch,
    ///         `provideLiquidity` and `withdrawLiquidity` must actually revert `Unauthorized` for
    ///         everyone — including the pool owner, since they are rebalancer-gated, not
    ///         owner-gated. Existing coverage only reads `getRebalancer() == address(0)` (a view);
    ///         this exercises the real revert path so a future submodule bump that changed the
    ///         guard would be caught.
    function test_E2E_BSCLiquidityOpsDisabledAtLaunch() public {
        assertEq(bscPool.getRebalancer(), address(0), "no rebalancer at launch");

        address randoLP = makeAddr("randoLP");
        vm.prank(randoLP);
        vm.expectPartialRevert(ITokenPool.Unauthorized.selector);
        bscPool.provideLiquidity(1 ether);

        vm.prank(randoLP);
        vm.expectPartialRevert(ITokenPool.Unauthorized.selector);
        bscPool.withdrawLiquidity(1 ether);

        // The owner is gated too — provide/withdraw check `s_rebalancer`, not `owner()`.
        vm.prank(bscPool.owner());
        vm.expectPartialRevert(ITokenPool.Unauthorized.selector);
        bscPool.provideLiquidity(1 ether);
    }

    // ─── Renounce-before-accept negative test ────────────────────────────────

    /// @notice Premature `renounceRole(DEFAULT_ADMIN_ROLE)` before the multisig has
    ///         actually accepted the role must NOT be possible to drive into a state
    ///         where the contract becomes orphaned. The contract itself does not block
    ///         a deployer-only renounce — but `RenounceDeployerAdmin.run()` in
    ///         `script/06_TransferOwnership.s.sol` precondition-checks that the multisig
    ///         already holds the role. This test reproduces the script's check off-script
    ///         and asserts it would revert.
    function test_E2E_RenounceBeforeMultisigAcceptIsBlocked() public {
        bytes32 adminRole = won.DEFAULT_ADMIN_ROLE();

        // Begin handoff but stop BEFORE the multisig has accepted the role grant.
        vm.startPrank(deployer);
        ethPool.transferOwnership(multisig);
        won.grantRole(adminRole, multisig);
        won.setCCIPAdmin(multisig); // proposed, not accepted
        ethRegistry.transferAdminRole(address(won), multisig);
        vm.stopPrank();

        // At this point: multisig holds the AccessControl role via direct grant (so
        // `hasRole(adminRole, multisig)` is true), BUT has NOT yet accepted the
        // two-step CCIP admin handoff. RenounceDeployerAdmin's third precondition
        // (`won.getCCIPAdmin() == multisig`) must fail.
        assertTrue(won.hasRole(adminRole, multisig), "multisig has AccessControl role");
        assertEq(won.getCCIPAdmin(), deployer, "CCIP admin not yet accepted");
        assertEq(won.pendingCCIPAdmin(), multisig);

        // Re-asserting the script's preconditions inline. If any of these would fail at
        // the require() inside RenounceDeployerAdmin.run(), the renounce is correctly
        // blocked. Specifically the CCIP-admin check must fail here.
        bool ccipAdminReady = (won.getCCIPAdmin() == multisig);
        assertFalse(ccipAdminReady, "renounce precondition would fail: ccipAdmin still deployer");

        // After multisig accepts the CCIP admin, the precondition is satisfied and
        // renounce becomes safe. This branch documents the green path immediately
        // after the negative assertion above.
        vm.prank(multisig);
        won.acceptCCIPAdmin();
        assertEq(won.getCCIPAdmin(), multisig);

        vm.prank(deployer);
        won.renounceRole(adminRole, deployer);
        assertFalse(won.hasRole(adminRole, deployer));
        assertTrue(won.hasRole(adminRole, multisig));
    }

    // ─── Rate-limit toggle ────────────────────────────────────────────────────

    function test_E2E_DisableRateLimitIndependently() public {
        // Disable outbound only; inbound stays enabled.
        RateLimiter.Config memory off = RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0});
        RateLimiter.Config memory on = RateLimiter.Config({isEnabled: true, capacity: CAPACITY, rate: RATE});

        vm.prank(deployer);
        ethPool.setChainRateLimiterConfig(BSC_SELECTOR, off, on);

        assertFalse(ethPool.getCurrentOutboundRateLimiterState(BSC_SELECTOR).isEnabled);
        assertTrue(ethPool.getCurrentInboundRateLimiterState(BSC_SELECTOR).isEnabled);

        // Re-enable outbound; disable inbound.
        vm.prank(deployer);
        ethPool.setChainRateLimiterConfig(BSC_SELECTOR, on, off);

        assertTrue(ethPool.getCurrentOutboundRateLimiterState(BSC_SELECTOR).isEnabled);
        assertFalse(ethPool.getCurrentInboundRateLimiterState(BSC_SELECTOR).isEnabled);
    }
}
