// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WrappedON} from "../src/WrappedON.sol";

/// @dev Minimal 18-decimal ON mock with a public mint for the handler's "BSC pool" simulation.
contract InvariantMockON is ERC20 {
    constructor() ERC20("Orochi Network", "ON") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stateful handler that drives random sequences of `deposit`, `withdraw`, CCIP `mint`,
///         and CCIP `burn` against a single `WrappedON` instance. The "BSC pool" is simulated
///         as a balance counter (`bscLocked`) so the invariant test can read it directly —
///         in production the BSC pool lives on a different chain and we cannot atomically
///         observe it, but for accounting purposes the locked-ON balance is what
///         `ccipMintedSupply` is tracking.
///
///         The invariant under test is the bridge safety invariant:
///
///             lockedON_BSC + reserveON_ETH >= totalSupply(wON)
///
///         `ccipMintedSupply` is a BSC-pool-balance approximation rather than a
///         "circulating CCIP-minted" counter. This fuzz test continuously checks the
///         actual safety property the cap was supposed to protect.
contract WrappedONHandler is Test {
    WrappedON internal immutable WON;
    InvariantMockON internal immutable ON;
    address internal immutable POOL;

    /// @notice Simulated BSC pool locked-ON balance. Incremented on each `mint` (= BSC lock),
    ///         decremented on each `burn` (= BSC release). Bounded by `MAX_CCIP_MINTED`.
    uint256 public bscLocked;

    /// @notice Pool of fixed actors so the fuzzer doesn't generate `address(0)` etc.
    address[] internal actors;

    /// @notice Cumulative ON inflow into the wON reserve via `deposit` — used by the
    ///         invariant test to sanity-check the deposit accounting independently.
    uint256 public totalDeposited;

    constructor(WrappedON won_, InvariantMockON on_, address pool_) {
        WON = won_;
        ON = on_;
        POOL = pool_;
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Bound the amount so we don't routinely overflow or trivially blow the cap.
    function _boundAmt(uint256 raw, uint256 max) internal pure returns (uint256) {
        if (max == 0) {
            return 0;
        }
        return bound(raw, 1, max);
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address user = _actor(actorSeed);
        // Bound deposit to a reasonable per-call magnitude. ON supply is uncapped in the mock.
        amount = _boundAmt(amount, 10_000_000 ether);
        ON.mint(user, amount);
        vm.startPrank(user);
        ON.approve(address(WON), amount);
        WON.deposit(amount);
        vm.stopPrank();
        totalDeposited += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address user = _actor(actorSeed);
        uint256 userBal = WON.balanceOf(user);
        uint256 reserve = ON.balanceOf(address(WON));
        uint256 cap = userBal < reserve ? userBal : reserve;
        if (cap == 0) {
            return;
        }
        amount = _boundAmt(amount, cap);
        vm.prank(user);
        WON.withdraw(amount);
    }

    /// @dev Simulates a CCIP `releaseOrMint` arriving on ETH: BSC pool locks `amount`,
    ///      ETH pool mints `amount` wON. Capped by `MAX_CCIP_MINTED` to mirror production.
    function ccipMint(uint256 actorSeed, uint256 amount) external {
        address user = _actor(actorSeed);
        uint256 cap = WON.MAX_CCIP_MINTED();
        uint256 headroom = cap - WON.ccipMintedSupply();
        if (headroom == 0) {
            return;
        }
        amount = _boundAmt(amount, headroom);
        // Simulated BSC lock — caps at BSC supply (MAX_CCIP_MINTED).
        bscLocked += amount;
        vm.prank(POOL);
        WON.mint(user, amount);
    }

    /// @dev Simulates ETH→BSC CCIP `lockOrBurn` for the single-arg `burn(amount)` path:
    ///      pool transfers `amount` wON from user to itself, then calls `burn(amount)`.
    function ccipBurn(uint256 actorSeed, uint256 amount) external {
        address user = _actor(actorSeed);
        uint256 userBal = WON.balanceOf(user);
        if (userBal == 0) {
            return;
        }
        if (bscLocked == 0) {
            return; // BSC pool can't release more than it has
        }
        uint256 capAmt = userBal < bscLocked ? userBal : bscLocked;
        amount = _boundAmt(amount, capAmt);
        vm.prank(user);
        WON.transfer(POOL, amount);
        // Simulated BSC release.
        bscLocked -= amount;
        vm.prank(POOL);
        WON.burn(amount);
    }

    /// @dev Adversarial path (round-3 review [2]): pool burns wON without a matching BSC
    ///      release — simulates either a buggy/compromised pool that calls `burn` on the
    ///      wON contract without the BSC side actually releasing, OR a user bridging out
    ///      deposit-backed wON through CCIP when bscLocked has already been drained (the
    ///      "deposit→pool-burn cap-bypass" scenario flagged in round-2 review [1]).
    ///
    ///      Importantly: `bscLocked` is NOT decremented here, so `ccipMintedSupply`
    ///      drifts BELOW `bscLocked` and the saturating-decrement branch in
    ///      `_decrementCcipMinted` becomes fuzzer-reachable. The `invariant_BackingCoversSupply`
    ///      property must hold under this path because `totalSupply` shrinks while
    ///      `bscLocked + reserve` does not.
    ///
    ///      We deliberately do NOT include an "adversarial-mint" sibling: a pool minting
    ///      wON without a matching BSC lock CAN break the safety invariant on its own —
    ///      that's exactly the case the `MAX_CCIP_MINTED` cap exists to bound, and
    ///      modelling it would test the cap's role rather than the safety invariant's
    ///      preservation by mechanics. The cap is locked separately via
    ///      `invariant_CcipMintedSupplyWithinCap`.
    function adversarialPoolBurn(uint256 actorSeed, uint256 amount) external {
        address user = _actor(actorSeed);
        uint256 userBal = WON.balanceOf(user);
        if (userBal == 0) {
            return;
        }
        amount = _boundAmt(amount, userBal);
        vm.prank(user);
        WON.transfer(POOL, amount);
        // Note: `bscLocked` deliberately NOT decremented — pool's `_decrementCcipMinted`
        // saturates at 0 when `amount > ccipMintedSupply`, which is the property under
        // test here.
        vm.prank(POOL);
        WON.burn(amount);
    }
}

contract WrappedONInvariantTest is StdInvariant, Test {
    WrappedON internal won;
    InvariantMockON internal onToken;
    WrappedONHandler internal handler;
    address internal admin = makeAddr("admin");
    address internal pool = makeAddr("pool");

    function setUp() public {
        onToken = new InvariantMockON();
        won = new WrappedON(IERC20(address(onToken)), admin);

        vm.startPrank(admin);
        won.grantRole(won.MINTER_ROLE(), pool);
        won.grantRole(won.BURNER_ROLE(), pool);
        vm.stopPrank();

        handler = new WrappedONHandler(won, onToken, pool);

        targetContract(address(handler));
        // Restrict fuzzer to the handler's five operations (four honest paths + one
        // adversarial pool-burn path that walks the cap-bypass scenario).
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = WrappedONHandler.deposit.selector;
        selectors[1] = WrappedONHandler.withdraw.selector;
        selectors[2] = WrappedONHandler.ccipMint.selector;
        selectors[3] = WrappedONHandler.ccipBurn.selector;
        selectors[4] = WrappedONHandler.adversarialPoolBurn.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice The bridge safety property: every outstanding wON token
    ///         must be redeemable, either against the BSC pool's locked ON (via a CCIP
    ///         outbound burn → BSC release) or against the deposit reserve (via withdraw).
    ///
    ///             lockedON_BSC + reserveON_ETH >= totalSupply(wON)
    ///
    ///         If this ever fails, some wON is structurally unbacked — the system has
    ///         minted more claims than collateral exists.
    function invariant_BackingCoversSupply() public view {
        uint256 backing = handler.bscLocked() + onToken.balanceOf(address(won));
        assertGe(backing, won.totalSupply(), "invariant: BSC lock + ETH reserve < totalSupply");
    }

    /// @notice `ccipMintedSupply` is BOUNDED ABOVE by `bscLocked`. The previous
    ///         strict-equality form (round-2 review R-14) held only because the honest
    ///         handler kept both counters in lockstep — making the assertion tautological
    ///         and unable to walk the saturating-decrement branch (round-3 review [2]).
    ///         Under the new `adversarialPoolBurn` path the contract's saturating
    ///         `_decrementCcipMinted` can push `ccipMintedSupply` strictly below
    ///         `bscLocked`; the bound `ccipMintedSupply <= bscLocked` still holds because
    ///         every mint increments both counters together and saturating-subtract can
    ///         only ever shrink the gap further. If a future change ever lets the counter
    ///         exceed `bscLocked` (i.e. a phantom mint without a matching BSC lock), this
    ///         invariant flags it.
    function invariant_CounterBoundedByBscLocked() public view {
        assertLe(
            won.ccipMintedSupply(),
            handler.bscLocked(),
            "invariant: ccipMintedSupply exceeds simulated BSC pool balance"
        );
    }

    /// @notice The CCIP cap must hold regardless of mint/burn ordering.
    function invariant_CcipMintedSupplyWithinCap() public view {
        assertLe(won.ccipMintedSupply(), won.MAX_CCIP_MINTED(), "invariant: ccipMintedSupply exceeds MAX_CCIP_MINTED");
    }

    /// @notice The reserve accounting is a 1:1 invariant: ON balance of the wON contract
    ///         equals the cumulative net deposit flow (deposits minus withdraws), because
    ///         CCIP mint/burn never touches the reserve.
    function invariant_ReserveMatchesNetDeposits() public view {
        uint256 reserve = onToken.balanceOf(address(won));
        // Net withdrawn = total deposited - current reserve. Must be non-negative
        // (deposits can't go below zero), AND withdrawn must equal what users hold below
        // the deposit-derived portion. We can't isolate that cleanly without provenance
        // tagging, so this invariant is the weaker "reserve <= totalDeposited".
        assertLe(reserve, handler.totalDeposited(), "invariant: reserve exceeds cumulative deposits");
    }
}
