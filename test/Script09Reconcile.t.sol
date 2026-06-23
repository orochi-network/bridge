// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/pools/LockReleaseTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";
import {
    IERC20 as CCIP_IERC20
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

import {ReconcileRemotePool} from "../script/09_ReconcileRemotePool.s.sol";
import {MockRMN} from "./mocks/MockRMN.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract _MockON is ERC20 {
    constructor() ERC20("Orochi Network", "ON") {
        _mint(msg.sender, 100_000_000 ether);
    }
}

/// @notice Coverage for `script/09_ReconcileRemotePool.s.sol` and the redeploy re-wire it fixes
///         (#55). The scenario is the live BSC `LockReleaseTokenPool` whose ETH lane points at
///         a now-dead ETH pool + old wON after an ETH redeploy; reconcile must re-point it at
///         the new pool AND new token in one atomic call.
///
///         Two things the suite previously could NOT express (issue #55):
///           1. script 05's `applyChainUpdates(empty, add)` reverts `ChainAlreadyExists` on an
///              already-wired lane — the dead-end the issue reports (`test_Script05Pattern_*`).
///           2. a stale-wiring case driven THROUGH to a successful re-wire, including the remote
///              *token* change that `addRemotePool`/`removeRemotePool` cannot express
///              (`test_Reconcile_RepointsPoolAndToken`).
contract Script09ReconcileTest is Test {
    // ETH mainnet selector — the lane we reconcile on the BSC pool.
    uint64 internal constant ETH_SELECTOR = 5_009_297_550_715_157_269;
    // Asymmetric defaults mirroring ReconcileRemotePool / script 05 (#61): outbound < inbound.
    uint128 internal constant INBOUND_CAPACITY = 100_000 ether;
    uint128 internal constant INBOUND_RATE = 10 ether;
    uint128 internal constant OUTBOUND_CAPACITY = 80_000 ether;
    uint128 internal constant OUTBOUND_RATE = 8 ether;

    address internal owner = makeAddr("poolOwner");

    // The redeploy changes BOTH the remote pool AND the remote token (new wON proxy).
    address internal oldEthPool = makeAddr("oldEthPool");
    address internal oldWon = makeAddr("oldWon");
    address internal newEthPool = makeAddr("newEthPool");
    address internal newWon = makeAddr("newWon");

    LockReleaseTokenPool internal bscPool; // local pool we operate on
    ReconcileRemotePool internal reconcile;

    function setUp() public {
        _MockON onBsc = new _MockON();
        MockRMN rmn = new MockRMN();
        MockRouter router = new MockRouter();

        vm.prank(owner);
        bscPool =
            new LockReleaseTokenPool(CCIP_IERC20(address(onBsc)), 18, new address[](0), address(rmn), address(router));

        // Wire the ETH lane to the OLD pool + OLD token (the pre-redeploy state).
        vm.prank(owner);
        bscPool.applyChainUpdates(new uint64[](0), _update(oldEthPool, oldWon));

        reconcile = new ReconcileRemotePool();
    }

    // ─── planAction: the script's decision logic ──────────────────────────────

    function test_PlanAction_NotWired() public view {
        // A different (unwired) selector resolves to ChainNotWired.
        uint64 unwired = 999;
        assertEq(
            uint256(reconcile.planAction(bscPool, unwired, newEthPool, newWon)),
            uint256(ReconcileRemotePool.Action.ChainNotWired)
        );
    }

    function test_PlanAction_AlreadyReconciled() public view {
        // Lane already points at the CURRENT (old) pool+token => no-op for that target.
        assertEq(
            uint256(reconcile.planAction(bscPool, ETH_SELECTOR, oldEthPool, oldWon)),
            uint256(ReconcileRemotePool.Action.AlreadyReconciled)
        );
    }

    function test_PlanAction_Reconcile_PoolChanged() public view {
        assertEq(
            uint256(reconcile.planAction(bscPool, ETH_SELECTOR, newEthPool, oldWon)),
            uint256(ReconcileRemotePool.Action.Reconcile)
        );
    }

    function test_PlanAction_Reconcile_TokenChanged() public view {
        // Pool unchanged, only the remote token changed => still needs reconcile (the bit
        // addRemotePool/removeRemotePool cannot express — there is no setRemoteToken).
        assertEq(
            uint256(reconcile.planAction(bscPool, ETH_SELECTOR, oldEthPool, newWon)),
            uint256(ReconcileRemotePool.Action.Reconcile)
        );
    }

    function test_PlanAction_Reconcile_ExtraRemotePoolPresent() public {
        // Operator added the new pool alongside the old via addRemotePool (CCIP allows multiple
        // remote pools). The lane now holds 2 pools => not a clean single-pool match => Reconcile.
        vm.prank(owner);
        bscPool.addRemotePool(ETH_SELECTOR, abi.encode(newEthPool));
        assertEq(bscPool.getRemotePools(ETH_SELECTOR).length, 2);
        assertEq(
            uint256(reconcile.planAction(bscPool, ETH_SELECTOR, newEthPool, oldWon)),
            uint256(ReconcileRemotePool.Action.Reconcile)
        );
    }

    // ─── The bug the issue reports: script 05's add-only pattern dead-ends ─────

    function test_Script05Pattern_RevertsChainAlreadyExists() public {
        // This is exactly what `applyChainUpdates(empty, add)` (script 05) does on a lane that
        // already exists — the redeploy re-wire dead-end (#55). It reverts, proving 05 cannot
        // re-point an existing lane.
        TokenPool.ChainUpdate[] memory add = _update(newEthPool, newWon);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TokenPool.ChainAlreadyExists.selector, ETH_SELECTOR));
        bscPool.applyChainUpdates(new uint64[](0), add);
    }

    // ─── The fix: reconcile re-points pool AND token, stale -> success ────────

    function test_Reconcile_RepointsPoolAndToken() public {
        // Sanity: pre-state points at the old pool + old token.
        assertTrue(bscPool.isRemotePool(ETH_SELECTOR, abi.encode(oldEthPool)), "pre: old pool wired");
        assertEq(abi.decode(bscPool.getRemoteToken(ETH_SELECTOR), (address)), oldWon, "pre: old token");

        // Apply the EXACT payload script 09 broadcasts.
        (uint64[] memory toRemove, TokenPool.ChainUpdate[] memory updates) =
            reconcile.buildUpdate(ETH_SELECTOR, newEthPool, newWon);
        vm.prank(owner);
        bscPool.applyChainUpdates(toRemove, updates);

        // Lane now points at EXACTLY the new pool (old one gone) and the new token.
        assertTrue(bscPool.isSupportedChain(ETH_SELECTOR), "post: still supported");
        bytes[] memory pools = bscPool.getRemotePools(ETH_SELECTOR);
        assertEq(pools.length, 1, "post: exactly one remote pool");
        assertEq(abi.decode(pools[0], (address)), newEthPool, "post: new pool");
        assertFalse(bscPool.isRemotePool(ETH_SELECTOR, abi.encode(oldEthPool)), "post: old pool gone");
        assertEq(abi.decode(bscPool.getRemoteToken(ETH_SELECTOR), (address)), newWon, "post: new token");

        // The script would now report the lane as reconciled (its post-assert basis).
        assertEq(
            uint256(reconcile.planAction(bscPool, ETH_SELECTOR, newEthPool, newWon)),
            uint256(ReconcileRemotePool.Action.AlreadyReconciled),
            "post: planAction == AlreadyReconciled"
        );
    }

    function test_Reconcile_RestoresRateLimits() public {
        (uint64[] memory toRemove, TokenPool.ChainUpdate[] memory updates) =
            reconcile.buildUpdate(ETH_SELECTOR, newEthPool, newWon);
        vm.prank(owner);
        bscPool.applyChainUpdates(toRemove, updates);

        RateLimiter.TokenBucket memory outb = bscPool.getCurrentOutboundRateLimiterState(ETH_SELECTOR);
        RateLimiter.TokenBucket memory inb = bscPool.getCurrentInboundRateLimiterState(ETH_SELECTOR);
        assertTrue(outb.isEnabled && inb.isEnabled, "rate limits re-enabled");
        assertEq(outb.capacity, OUTBOUND_CAPACITY, "outbound capacity restored");
        assertEq(outb.rate, OUTBOUND_RATE, "outbound rate restored");
        assertEq(inb.capacity, INBOUND_CAPACITY, "inbound capacity restored");
        assertEq(inb.rate, INBOUND_RATE, "inbound rate restored");
    }

    function test_Reconcile_OnlyOwner() public {
        // The broadcast call is onlyOwner — a non-owner cannot reconcile.
        (uint64[] memory toRemove, TokenPool.ChainUpdate[] memory updates) =
            reconcile.buildUpdate(ETH_SELECTOR, newEthPool, newWon);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        bscPool.applyChainUpdates(toRemove, updates);
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _update(address remotePool, address remoteToken)
        internal
        pure
        returns (TokenPool.ChainUpdate[] memory updates)
    {
        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(remotePool);
        updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: ETH_SELECTOR,
            remotePoolAddresses: remotePoolAddresses,
            remoteTokenAddress: abi.encode(remoteToken),
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: true, capacity: OUTBOUND_CAPACITY, rate: OUTBOUND_RATE
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: true, capacity: INBOUND_CAPACITY, rate: INBOUND_RATE
            })
        });
    }
}
