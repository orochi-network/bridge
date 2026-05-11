// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { Vm } from "forge-std/Vm.sol";

import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { OFTAdapterMock } from "../mocks/OFTAdapterMock.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { OFTComposerMock } from "../mocks/OFTComposerMock.sol";
import { WrappedONMock } from "../../contracts/mocks/WrappedONMock.sol";
import { WrappedON } from "../../contracts/WrappedON.sol";

/// @notice End-to-end auto-unwrap behaviour on the ETH side.
/// @dev BSC-side adapter (locks real ON) bridges to ETH-side WrappedON. WrappedON
///      either (a) auto-unwraps from its real-ON reserve when sufficient, or
///      (b) falls back to minting wON when the reserve cannot cover the amount.
///      Stranded wON-holders can later call unwrap() to redeem against the
///      reserve once it has been refilled.
contract WrappedONTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 private constant BSC_EID = 1;
    uint32 private constant ETH_EID = 2;

    ERC20Mock private bscON; // BSC-side ON (locked by adapter)
    ERC20Mock private ethON; // ETH-side legacy ON (reserve asset for wON)
    OFTAdapterMock private adapter;
    WrappedONMock private wON;

    address private alice = address(0xA11CE); // bridge sender on BSC
    address private bob = address(0xB0B); // bridge recipient on ETH
    address private treasury = address(0xDEADBEEF); // seeds the reserve

    uint256 private constant INITIAL_BSC_ON = 1_000 ether;
    uint256 private constant TREASURY_ETH_ON = 500 ether;

    function setUp() public virtual override {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(treasury, 100 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        bscON = ERC20Mock(_deployOApp(type(ERC20Mock).creationCode, abi.encode("BSC ON", "ON")));
        ethON = ERC20Mock(_deployOApp(type(ERC20Mock).creationCode, abi.encode("ETH ON", "ON")));

        adapter = OFTAdapterMock(
            _deployOApp(
                type(OFTAdapterMock).creationCode,
                abi.encode(address(bscON), address(endpoints[BSC_EID]), address(this))
            )
        );

        wON = WrappedONMock(
            _deployOApp(
                type(WrappedONMock).creationCode,
                abi.encode("Wrapped ON", "wON", address(endpoints[ETH_EID]), address(this), address(ethON))
            )
        );

        address[] memory ofts = new address[](2);
        ofts[0] = address(adapter);
        ofts[1] = address(wON);
        wireOApps(ofts);

        bscON.mint(alice, INITIAL_BSC_ON);
        ethON.mint(treasury, TREASURY_ETH_ON);
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _bridgeToEth(address _from, address _to, uint256 _amount) internal {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory p = SendParam(
            ETH_EID,
            addressToBytes32(_to),
            _amount,
            _amount,
            options,
            "",
            ""
        );
        MessagingFee memory fee = adapter.quoteSend(p, false);

        vm.startPrank(_from);
        bscON.approve(address(adapter), _amount);
        adapter.send{ value: fee.nativeFee }(p, fee, payable(_from));
        vm.stopPrank();

        verifyPackets(ETH_EID, addressToBytes32(address(wON)));
    }

    function _seed(uint256 _amount) internal {
        vm.startPrank(treasury);
        ethON.approve(address(wON), _amount);
        wON.seedReserve(_amount);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // construction
    // -------------------------------------------------------------------------

    function test_constructor_setsReserveToken() public {
        assertEq(address(wON.ON()), address(ethON));
        assertEq(wON.reserve(), 0);
    }

    function test_constructor_revertsOnZeroReserveAddress() public {
        vm.expectRevert(WrappedON.ZeroAddress.selector);
        new WrappedONMock("Wrapped ON", "wON", address(endpoints[ETH_EID]), address(this), address(0));
    }

    function test_constructor_revertsOnDecimalsMismatch() public {
        SixDecimalERC20 wrong = new SixDecimalERC20();
        vm.expectRevert(abi.encodeWithSelector(WrappedON.DecimalsMismatch.selector, uint8(6)));
        new WrappedONMock("Wrapped ON", "wON", address(endpoints[ETH_EID]), address(this), address(wrong));
    }

    function test_constructor_revertsOnSelfReserve() public {
        // Predict the address that the next CREATE from this test contract will land
        // at, then pass that same address as the reserve token. The constructor
        // executes with `address(this) == predicted == _onToken`, hitting SelfReserve.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(WrappedON.SelfReserve.selector);
        new WrappedONMock("Wrapped ON", "wON", address(endpoints[ETH_EID]), address(this), predicted);
    }

    // -------------------------------------------------------------------------
    // inbound bridge: auto-unwrap vs fallback
    // -------------------------------------------------------------------------

    function test_inbound_emptyReserve_mintsWON() public {
        _bridgeToEth(alice, bob, 100 ether);

        assertEq(wON.balanceOf(bob), 100 ether, "bob should hold wON");
        assertEq(ethON.balanceOf(bob), 0, "bob should not receive real ON");
        assertEq(wON.reserve(), 0);
        assertEq(bscON.balanceOf(address(adapter)), 100 ether, "BSC side locked the deposit");
    }

    function test_inbound_sufficientReserve_autoUnwraps() public {
        _seed(200 ether);

        _bridgeToEth(alice, bob, 100 ether);

        assertEq(ethON.balanceOf(bob), 100 ether, "bob should receive real ON");
        assertEq(wON.balanceOf(bob), 0, "no wON minted");
        assertEq(wON.reserve(), 100 ether);
        assertEq(bscON.balanceOf(address(adapter)), 100 ether, "BSC side still holds locked ON");
    }

    function test_inbound_partialReserve_fallsBackToMint() public {
        // Reserve has 50 but user requests 100 -> must NOT split; fall back to wON mint.
        _seed(50 ether);

        _bridgeToEth(alice, bob, 100 ether);

        assertEq(wON.balanceOf(bob), 100 ether, "fallback: bob gets wON");
        assertEq(ethON.balanceOf(bob), 0, "no real ON paid");
        assertEq(wON.reserve(), 50 ether, "reserve untouched");
    }

    function test_inbound_exactReserve_autoUnwraps() public {
        _seed(100 ether);

        _bridgeToEth(alice, bob, 100 ether);

        assertEq(ethON.balanceOf(bob), 100 ether);
        assertEq(wON.balanceOf(bob), 0);
        assertEq(wON.reserve(), 0);
    }

    // -------------------------------------------------------------------------
    // manual unwrap
    // -------------------------------------------------------------------------

    function test_unwrap_succeeds_whenReserveCovers() public {
        _bridgeToEth(alice, bob, 100 ether); // bob has 100 wON, reserve 0
        _seed(100 ether); // reserve now 100

        vm.prank(bob);
        wON.unwrap(100 ether);

        assertEq(wON.balanceOf(bob), 0, "wON burned");
        assertEq(ethON.balanceOf(bob), 100 ether, "ON paid out");
        assertEq(wON.reserve(), 0, "reserve drained");
    }

    function test_unwrap_revertsOnInsufficientReserve() public {
        _bridgeToEth(alice, bob, 100 ether);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(WrappedON.ReserveInsufficient.selector, uint256(100 ether), uint256(0))
        );
        wON.unwrap(100 ether);
    }

    function test_unwrap_revertsOnZeroAmount() public {
        vm.prank(bob);
        vm.expectRevert(WrappedON.ZeroAmount.selector);
        wON.unwrap(0);
    }

    // -------------------------------------------------------------------------
    // manual wrap
    // -------------------------------------------------------------------------

    function test_wrap_mintsWON_andAddsToReserve() public {
        ethON.mint(alice, 50 ether);

        vm.startPrank(alice);
        ethON.approve(address(wON), 50 ether);
        wON.wrap(50 ether);
        vm.stopPrank();

        assertEq(wON.balanceOf(alice), 50 ether);
        assertEq(wON.reserve(), 50 ether);
        assertEq(ethON.balanceOf(alice), 0);
    }

    function test_wrap_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(WrappedON.ZeroAmount.selector);
        wON.wrap(0);
    }

    // -------------------------------------------------------------------------
    // seed
    // -------------------------------------------------------------------------

    function test_seedReserve_addsBalanceWithoutMinting() public {
        uint256 totalBefore = wON.totalSupply();

        _seed(150 ether);

        assertEq(wON.reserve(), 150 ether);
        assertEq(wON.totalSupply(), totalBefore, "no wON minted");
    }

    function test_seedReserve_revertsOnZeroAmount() public {
        vm.prank(treasury);
        vm.expectRevert(WrappedON.ZeroAmount.selector);
        wON.seedReserve(0);
    }

    // -------------------------------------------------------------------------
    // composed-message handling
    // -------------------------------------------------------------------------

    /// @dev When a SEND_AND_CALL message arrives, the compose handler downstream
    ///      receives `amountReceivedLD` and assumes it is OFT (wON). We must NOT
    ///      auto-unwrap to real ON in this case — the compose handler would then
    ///      manipulate a wON balance the recipient doesn't have. Force mint.
    function test_inbound_composedMessage_forcesMintEvenWithFullReserve() public {
        _seed(500 ether); // reserve full enough to auto-unwrap

        OFTComposerMock composer = new OFTComposerMock();

        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(250_000, 0)
            .addExecutorLzComposeOption(0, 500_000, 0);
        bytes memory composeMsg = hex"1234";
        SendParam memory p = SendParam(
            ETH_EID,
            addressToBytes32(address(composer)),
            100 ether,
            100 ether,
            options,
            composeMsg,
            ""
        );
        MessagingFee memory fee = adapter.quoteSend(p, false);

        vm.startPrank(alice);
        bscON.approve(address(adapter), 100 ether);
        adapter.send{ value: fee.nativeFee }(p, fee, payable(alice));
        vm.stopPrank();

        verifyPackets(ETH_EID, addressToBytes32(address(wON)));

        // Composer must hold wON, NOT real ON. Reserve must be untouched.
        assertEq(wON.balanceOf(address(composer)), 100 ether, "composer holds wON");
        assertEq(ethON.balanceOf(address(composer)), 0, "composer has no real ON");
        assertEq(wON.reserve(), 500 ether, "reserve untouched (compose forced mint)");
    }

    // -------------------------------------------------------------------------
    // wrap defends against fee-on-transfer reserve token
    // -------------------------------------------------------------------------

    function test_wrap_revertsOnFeeOnTransferToken() public {
        // Spin up a separate WrappedON instance whose reserve token charges a
        // 1% transfer fee. wrap() must detect the mismatch and revert.
        FeeOnTransferERC20 feeOn = new FeeOnTransferERC20();
        WrappedONMock wON_fot = WrappedONMock(
            _deployOApp(
                type(WrappedONMock).creationCode,
                abi.encode("Wrapped ON FOT", "wON-FOT", address(endpoints[ETH_EID]), address(this), address(feeOn))
            )
        );

        feeOn.mint(alice, 100 ether);
        vm.startPrank(alice);
        feeOn.approve(address(wON_fot), 100 ether);
        // wrap requests 100 but only 99 arrives -> revert
        vm.expectRevert(
            abi.encodeWithSelector(WrappedON.UnexpectedTransferAmount.selector, uint256(100 ether), uint256(99 ether))
        );
        wON_fot.wrap(100 ether);
        vm.stopPrank();
    }

    function test_seedReserve_revertsOnFeeOnTransferToken() public {
        FeeOnTransferERC20 feeOn = new FeeOnTransferERC20();
        WrappedONMock wON_fot = WrappedONMock(
            _deployOApp(
                type(WrappedONMock).creationCode,
                abi.encode("Wrapped ON FOT", "wON-FOT", address(endpoints[ETH_EID]), address(this), address(feeOn))
            )
        );

        feeOn.mint(treasury, 100 ether);
        vm.startPrank(treasury);
        feeOn.approve(address(wON_fot), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(WrappedON.UnexpectedTransferAmount.selector, uint256(100 ether), uint256(99 ether))
        );
        wON_fot.seedReserve(100 ether);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // recipient handling: matches upstream OFT exactly (address(0) → 0xdead;
    // no guard on address(this))
    // -------------------------------------------------------------------------

    /// @dev `_credit` performs the upstream `OFT._credit:83` redirect
    ///      verbatim — `address(0)` is rewritten to `address(0xdead)` and
    ///      the call then proceeds through the normal branches. Auto-unwrap
    ///      reaches the `safeTransfer(0xdead, amt)` happy path, draining
    ///      real reserve to `0xdead`. This is the upstream-matching
    ///      behaviour; operators must monitor for inbound sends addressed
    ///      to the zero address (see SECURITY.md M4).
    function test_inbound_zeroRecipient_autoUnwrap_drainsReserveToDead() public {
        _seed(500 ether);

        wON.credit(address(0), 100 ether, BSC_EID);

        assertEq(wON.reserve(), 400 ether, "reserve drained to 0xdead");
        assertEq(ethON.balanceOf(address(0xdead)), 100 ether, "real ON sent to 0xdead");
        assertEq(wON.balanceOf(address(0xdead)), 0, "no wON minted (auto-unwrap path)");
    }

    /// @dev With an empty reserve the fallback-mint branch fires and the
    ///      redirected `_to = 0xdead` is the `_mint` recipient. Matches
    ///      upstream OFT base behaviour exactly.
    function test_inbound_zeroRecipient_emptyReserve_mintsToDead() public {
        // reserve is empty by default; no _seed call

        wON.credit(address(0), 100 ether, BSC_EID);

        assertEq(wON.balanceOf(address(0xdead)), 100 ether, "wON minted to 0xdead");
        assertEq(wON.reserve(), 0, "reserve untouched (was empty)");
    }

    /// @dev Composed branch always mints, and the `address(0) → 0xdead`
    ///      redirect applies before the mint — wON ends up at `0xdead`.
    function test_inbound_zeroRecipient_composed_mintsToDead() public {
        _seed(500 ether);

        wON.creditComposed(address(0), 100 ether, BSC_EID);

        assertEq(wON.balanceOf(address(0xdead)), 100 ether, "wON minted to 0xdead under composed branch");
        assertEq(wON.reserve(), 500 ether, "reserve untouched (compose forces mint)");
    }

    /// @dev `_credit` does NOT guard against `_to = address(this)` —
    ///      matches upstream OFT behaviour. On the auto-unwrap branch
    ///      `safeTransfer(this, amt)` is a self-transfer no-op, which the
    ///      balance-delta guard catches and reverts with
    ///      `UnexpectedTransferAmount`. The LZ message stays retryable-
    ///      pending until the reserve drops below the amount and the
    ///      fallback-mint branch fires.
    function test_inbound_selfRecipient_autoUnwrap_revertsOnSelfTransferNoOp() public {
        _seed(500 ether);

        vm.expectRevert(
            abi.encodeWithSelector(WrappedON.UnexpectedTransferAmount.selector, uint256(100 ether), uint256(0))
        );
        wON.credit(address(wON), 100 ether, BSC_EID);

        assertEq(wON.reserve(), 500 ether, "reserve untouched on revert");
        assertEq(wON.balanceOf(address(wON)), 0, "no wON minted on revert");
    }

    /// @dev With an empty reserve the fallback-mint branch fires and
    ///      `_mint(address(this), amt)` succeeds — wON inflates its own
    ///      balance. Silent contract bloat; matches upstream OFT base
    ///      behaviour exactly. Operators must monitor for inbound sends
    ///      addressed to the wON contract (see SECURITY.md M4).
    function test_inbound_selfRecipient_emptyReserve_mintsToSelf() public {
        // reserve is empty by default

        wON.credit(address(wON), 100 ether, BSC_EID);

        assertEq(wON.balanceOf(address(wON)), 100 ether, "wON minted into its own balance");
        assertEq(wON.totalSupply(), 100 ether, "totalSupply reflects the orphaned mint");
        assertEq(wON.reserve(), 0, "reserve untouched");
    }

    /// @dev Composed branch + self-recipient: mint happens at `address(this)`.
    ///      Same silent contract bloat as the empty-reserve case.
    function test_inbound_selfRecipient_composed_mintsToSelf() public {
        _seed(500 ether);

        wON.creditComposed(address(wON), 100 ether, BSC_EID);

        assertEq(wON.balanceOf(address(wON)), 100 ether, "wON minted into its own balance");
        assertEq(wON.reserve(), 500 ether, "reserve untouched (compose forces mint)");
    }

    /// @dev Sanity check: composed + good recipient mints to the recipient.
    function test_inbound_composed_goodRecipient_mints() public {
        _seed(500 ether);
        wON.creditComposed(bob, 100 ether, BSC_EID);

        assertEq(wON.balanceOf(bob), 100 ether, "composed credit mints to good recipient");
        assertEq(wON.reserve(), 500 ether, "reserve untouched (compose forces mint)");
    }

    // -------------------------------------------------------------------------
    // ETH-side auto-unwrap fee-on-transfer detection
    // -------------------------------------------------------------------------

    /// @dev If the reserve token ever ships fee-on-transfer behaviour, the
    ///      auto-unwrap branch must refuse to silently underpay the recipient.
    ///      Driving `_credit` directly via the mock isolates the guard from
    ///      LayerZero plumbing — the upstream test helper would otherwise
    ///      catch the revert at the endpoint and store it as a failed-message
    ///      alert, masking the assertion.
    function test_credit_autoUnwrap_revertsOnFeeOnTransferReserveToken() public {
        FeeOnTransferERC20 feeOn = new FeeOnTransferERC20();
        WrappedONMock wON_fot = WrappedONMock(
            _deployOApp(
                type(WrappedONMock).creationCode,
                abi.encode("Wrapped ON FOT", "wON-FOT", address(endpoints[ETH_EID]), address(this), address(feeOn))
            )
        );
        // Mint bypasses the FoT guard on wrap/seed; simulates FoT activating
        // on a token that already has reserve liquidity.
        feeOn.mint(address(wON_fot), 200 ether);

        vm.expectRevert(
            abi.encodeWithSelector(WrappedON.UnexpectedTransferAmount.selector, uint256(100 ether), uint256(99 ether))
        );
        wON_fot.credit(bob, 100 ether, BSC_EID);
    }

    /// @dev Liveness preservation: when the reserve cannot cover the request,
    ///      the fallback-mint path runs unaffected by FoT. Bridge stays usable
    ///      even after a hostile inner-token migration, just without auto-unwrap.
    function test_credit_fallbackMint_unaffectedByFeeOnTransferReserveToken() public {
        FeeOnTransferERC20 feeOn = new FeeOnTransferERC20();
        WrappedONMock wON_fot = WrappedONMock(
            _deployOApp(
                type(WrappedONMock).creationCode,
                abi.encode("Wrapped ON FOT", "wON-FOT", address(endpoints[ETH_EID]), address(this), address(feeOn))
            )
        );
        // Reserve below the request → fallback to mint, FoT never touched.
        feeOn.mint(address(wON_fot), 50 ether);

        wON_fot.credit(bob, 100 ether, BSC_EID);
        assertEq(wON_fot.balanceOf(bob), 100 ether);
        assertEq(feeOn.balanceOf(address(wON_fot)), 50 ether, "reserve untouched");
    }

    // -------------------------------------------------------------------------
    // composed-message: no UnwrapFallbackToMint emission
    // -------------------------------------------------------------------------

    /// @dev `UnwrapFallbackToMint` previously fired on every composed message,
    ///      producing false positives for any reserve-low monitor. After the
    ///      _lzReceive refactor the event signal is clean: only depleted
    ///      reserves on plain messages emit it.
    function test_inbound_composedMessage_doesNotEmitFallbackEvent() public {
        _seed(500 ether);

        OFTComposerMock composer = new OFTComposerMock();
        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(300_000, 0)
            .addExecutorLzComposeOption(0, 500_000, 0);
        SendParam memory p = SendParam(
            ETH_EID,
            addressToBytes32(address(composer)),
            100 ether,
            100 ether,
            options,
            hex"1234",
            ""
        );
        MessagingFee memory fee = adapter.quoteSend(p, false);

        vm.startPrank(alice);
        bscON.approve(address(adapter), 100 ether);
        adapter.send{ value: fee.nativeFee }(p, fee, payable(alice));
        vm.stopPrank();

        // Record logs across the inbound delivery and assert no
        // UnwrapFallbackToMint event was emitted by `wON`.
        vm.recordLogs();
        verifyPackets(ETH_EID, addressToBytes32(address(wON)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 fallbackSig = keccak256("UnwrapFallbackToMint(address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(wON) && logs[i].topics[0] == fallbackSig) {
                revert("composed message must not emit UnwrapFallbackToMint");
            }
        }
        assertEq(wON.balanceOf(address(composer)), 100 ether, "composer holds wON");
    }

    // -------------------------------------------------------------------------
    // access control
    // -------------------------------------------------------------------------

    function test_setPeer_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount(alice)
        wON.setPeer(BSC_EID, addressToBytes32(address(0xBEEF)));
    }

    function test_setDelegate_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        wON.setDelegate(alice);
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        wON.transferOwnership(alice);
    }
}

/// @dev Helper: a minimal-but-real ERC20 with 6 decimals. The WrappedON constructor
///      currently only calls `decimals()`, but we extend ERC20 anyway so future
///      additions to the constructor (balance check, name read, etc.) won't make
///      this test silently revert for the wrong reason.
contract SixDecimalERC20 is ERC20 {
    constructor() ERC20("Six Decimal", "SIX") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

/// @dev Helper: 18-decimal ERC20 that burns 1% on every user-to-user transfer,
///      simulating a fee-on-transfer token. Used to verify wrap/seedReserve
///      detect the balance mismatch.
contract FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("Fee On Transfer", "FOT") {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100; // 1% fee
            super._update(from, address(0xdead), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
