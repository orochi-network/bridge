// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// Mock imports
import { OFTMock } from "../mocks/OFTMock.sol";
import { OFTAdapterMock } from "../mocks/OFTAdapterMock.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { OFTComposerMock } from "../mocks/OFTComposerMock.sol";
import { ONOFTAdapterMock } from "../../contracts/mocks/ONOFTAdapterMock.sol";
import { ONOFTAdapter } from "../../contracts/ONOFTAdapter.sol";

// OZ imports
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// OApp imports
import { IOAppOptionsType3, EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

// OFT imports
import { IOFT, SendParam, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

// OZ imports
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Forge imports
import "forge-std/console.sol";

// DevTools imports
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

contract ONOFTAdapterTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 private aEid = 1;
    uint32 private bEid = 2;

    ERC20Mock private aToken;
    OFTAdapterMock private aOFTAdapter;
    OFTMock private bOFT;

    address private userA = address(0x1);
    address private userB = address(0x2);
    uint256 private initialBalance = 100 ether;

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        aToken = ERC20Mock(_deployOApp(type(ERC20Mock).creationCode, abi.encode("Token", "TOKEN")));

        aOFTAdapter = OFTAdapterMock(
            _deployOApp(
                type(OFTAdapterMock).creationCode,
                abi.encode(address(aToken), address(endpoints[aEid]), address(this))
            )
        );

        bOFT = OFTMock(
            _deployOApp(
                type(OFTMock).creationCode,
                abi.encode("Token", "TOKEN", address(endpoints[bEid]), address(this))
            )
        );

        // config and wire the ofts
        address[] memory ofts = new address[](2);
        ofts[0] = address(aOFTAdapter);
        ofts[1] = address(bOFT);
        this.wireOApps(ofts);

        // mint tokens
        aToken.mint(userA, initialBalance);
    }

    function test_constructor() public {
        assertEq(aOFTAdapter.owner(), address(this));
        assertEq(bOFT.owner(), address(this));

        assertEq(aToken.balanceOf(userA), initialBalance);
        assertEq(aToken.balanceOf(address(aOFTAdapter)), 0);
        assertEq(bOFT.balanceOf(userB), 0);

        assertEq(aOFTAdapter.token(), address(aToken));
        assertEq(bOFT.token(), address(bOFT));
    }

    function test_send_oft_adapter() public {
        uint256 tokensToSend = 1 ether;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        SendParam memory sendParam = SendParam(
            bEid,
            addressToBytes32(userB),
            tokensToSend,
            tokensToSend,
            options,
            "",
            ""
        );
        MessagingFee memory fee = aOFTAdapter.quoteSend(sendParam, false);

        assertEq(aToken.balanceOf(userA), initialBalance);
        assertEq(aToken.balanceOf(address(aOFTAdapter)), 0);
        assertEq(bOFT.balanceOf(userB), 0);

        vm.prank(userA);
        aToken.approve(address(aOFTAdapter), tokensToSend);

        vm.prank(userA);
        aOFTAdapter.send{ value: fee.nativeFee }(sendParam, fee, payable(address(this)));
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        assertEq(aToken.balanceOf(userA), initialBalance - tokensToSend);
        assertEq(aToken.balanceOf(address(aOFTAdapter)), tokensToSend);
        assertEq(bOFT.balanceOf(userB), tokensToSend);
    }

    function test_send_oft_adapter_compose_msg() public {
        uint256 tokensToSend = 1 ether;

        OFTComposerMock composer = new OFTComposerMock();

        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200000, 0)
            .addExecutorLzComposeOption(0, 500000, 0);
        bytes memory composeMsg = hex"1234";
        SendParam memory sendParam = SendParam(
            bEid,
            addressToBytes32(address(composer)),
            tokensToSend,
            tokensToSend,
            options,
            composeMsg,
            ""
        );
        MessagingFee memory fee = aOFTAdapter.quoteSend(sendParam, false);

        assertEq(aToken.balanceOf(userA), initialBalance);
        assertEq(aToken.balanceOf(address(aOFTAdapter)), 0);
        assertEq(bOFT.balanceOf(userB), 0);

        vm.prank(userA);
        aToken.approve(address(aOFTAdapter), tokensToSend);

        vm.prank(userA);
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) = aOFTAdapter.send{ value: fee.nativeFee }(
            sendParam,
            fee,
            payable(address(this))
        );
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        // lzCompose params
        uint32 dstEid_ = bEid;
        address from_ = address(bOFT);
        bytes memory options_ = options;
        bytes32 guid_ = msgReceipt.guid;
        address to_ = address(composer);
        bytes memory composerMsg_ = OFTComposeMsgCodec.encode(
            msgReceipt.nonce,
            aEid,
            oftReceipt.amountReceivedLD,
            abi.encodePacked(addressToBytes32(userA), composeMsg)
        );
        this.lzCompose(dstEid_, from_, options_, guid_, to_, composerMsg_);

        assertEq(aToken.balanceOf(userA), initialBalance - tokensToSend);
        assertEq(aToken.balanceOf(address(aOFTAdapter)), tokensToSend);
        assertEq(bOFT.balanceOf(address(composer)), tokensToSend);

        assertEq(composer.from(), from_);
        assertEq(composer.guid(), guid_);
        assertEq(composer.message(), composerMsg_);
        assertEq(composer.executor(), address(this));
        assertEq(composer.extraData(), composerMsg_); // default to setting the extraData to the message as well to test
    }

    // -------------------------------------------------------------------------
    // fee-on-transfer guard on _debit
    // -------------------------------------------------------------------------

    /// @dev Confirms the override added in `ONOFTAdapter._debit` refuses to
    ///      under-collateralise the destination chain when the inner token
    ///      ships fee-on-transfer behaviour. Without the guard, the adapter
    ///      reports `amountSentLD` to LayerZero while having received less,
    ///      breaking the conservation invariant. With it, the send reverts.
    function test_debit_revertsOnFeeOnTransferInnerToken() public {
        FeeOnTransferERC20 feeOn = new FeeOnTransferERC20();
        ONOFTAdapterMock fotAdapter = ONOFTAdapterMock(
            _deployOApp(
                type(ONOFTAdapterMock).creationCode,
                abi.encode(address(feeOn), address(endpoints[aEid]), address(this))
            )
        );

        feeOn.mint(userA, 100 ether);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        SendParam memory sendParam = SendParam(
            bEid,
            addressToBytes32(userB),
            100 ether,
            100 ether,
            options,
            "",
            ""
        );
        // quoteSend would normally be called first to size native fee; the
        // FoT detection happens during `send()` in `_debit` and reverts
        // before the message is dispatched, so the fee value doesn't matter.
        MessagingFee memory fee = MessagingFee(0, 0);

        vm.startPrank(userA);
        feeOn.approve(address(fotAdapter), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ONOFTAdapter.UnexpectedTransferAmount.selector, uint256(100 ether), uint256(99 ether))
        );
        fotAdapter.send{ value: fee.nativeFee }(sendParam, fee, payable(userA));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // _credit recipient hardening: address(0) and address(this) reroute to 0xdead
    // -------------------------------------------------------------------------

    /// @dev Confirms that `ONOFTAdapter._credit` redirects `address(0)` and
    ///      `address(this)` to `address(0xdead)`.
    ///
    ///      - `address(0)` would cause `safeTransfer` to revert on a standard
    ///        ERC20 (OpenZeppelin rejects zero-address receivers), making the
    ///        inbound LayerZero message permanently undeliverable.
    ///      - `address(this)` is a self-transfer no-op on standard ERC20; the
    ///        message is marked delivered but the recipient receives nothing
    ///        (silent fund loss).
    ///
    ///      Both are redirected to 0xdead so the message always delivers.
    function test_credit_redirectsBadRecipientToDeadAddress() public {
        ERC20Mock token = new ERC20Mock("Token", "TOKEN");
        ONOFTAdapterMock fotAdapter = ONOFTAdapterMock(
            _deployOApp(
                type(ONOFTAdapterMock).creationCode,
                abi.encode(address(token), address(endpoints[aEid]), address(this))
            )
        );

        // Seed the adapter with locked tokens (simulating prior BSC-side inflows).
        uint256 locked = 200 ether;
        token.mint(address(fotAdapter), locked);

        uint256 amount = 10 ether;

        // Case 1: address(0) recipient → redirected to 0xdead.
        fotAdapter.credit(address(0), amount, bEid);
        assertEq(token.balanceOf(address(0xdead)), amount, "address(0) must redirect to 0xdead");
        assertEq(token.balanceOf(address(fotAdapter)), locked - amount, "adapter balance reduced");

        // Case 2: address(this) (the adapter itself) → redirected to 0xdead.
        fotAdapter.credit(address(fotAdapter), amount, bEid);
        assertEq(
            token.balanceOf(address(0xdead)),
            2 * amount,
            "address(this) must redirect to 0xdead"
        );
        assertEq(token.balanceOf(address(fotAdapter)), locked - 2 * amount, "adapter balance reduced again");
    }

    // -------------------------------------------------------------------------
    // _credit + composed + bad recipient: revert symmetrically with WrappedON
    // -------------------------------------------------------------------------

    /// @dev OFTCore's `_lzReceive` captures `toAddress` before calling
    ///      `_credit`, so the bare redirect-to-0xdead in `_credit` would still
    ///      let the caller dispatch `sendCompose` to the original bad address
    ///      — leaving the adapter's locked ON unlocked at 0xdead with a
    ///      compose stuck pending forever. `_credit` reverts when both the
    ///      bad-recipient redirect AND the composed flag fire, keeping the LZ
    ///      message in retryable-pending state. Mirrors the symmetric guard
    ///      in `WrappedON._credit`.
    ///
    ///      `creditComposed` on the mock sets the same transient flag that
    ///      `_lzReceive` sets in production, then calls `_credit` directly,
    ///      isolating the guard from the rest of LZ plumbing.
    function test_credit_composedBadRecipient_zero_reverts() public {
        ERC20Mock token = new ERC20Mock("Token", "TOKEN");
        ONOFTAdapterMock testAdapter = ONOFTAdapterMock(
            _deployOApp(
                type(ONOFTAdapterMock).creationCode,
                abi.encode(address(token), address(endpoints[aEid]), address(this))
            )
        );
        uint256 locked = 200 ether;
        token.mint(address(testAdapter), locked);

        vm.expectRevert(abi.encodeWithSelector(ONOFTAdapter.BadRecipientWithCompose.selector, address(0)));
        testAdapter.creditComposed(address(0), 10 ether, bEid);

        // No tokens unlocked from the adapter on the failed credit.
        assertEq(token.balanceOf(address(testAdapter)), locked, "adapter balance unchanged");
        assertEq(token.balanceOf(address(0xdead)), 0, "nothing forwarded to 0xdead");
    }

    function test_credit_composedBadRecipient_self_reverts() public {
        ERC20Mock token = new ERC20Mock("Token", "TOKEN");
        ONOFTAdapterMock testAdapter = ONOFTAdapterMock(
            _deployOApp(
                type(ONOFTAdapterMock).creationCode,
                abi.encode(address(token), address(endpoints[aEid]), address(this))
            )
        );
        uint256 locked = 200 ether;
        token.mint(address(testAdapter), locked);

        vm.expectRevert(
            abi.encodeWithSelector(ONOFTAdapter.BadRecipientWithCompose.selector, address(testAdapter))
        );
        testAdapter.creditComposed(address(testAdapter), 10 ether, bEid);

        assertEq(token.balanceOf(address(testAdapter)), locked, "adapter balance unchanged");
        assertEq(token.balanceOf(address(0xdead)), 0, "nothing forwarded to 0xdead");
    }

    /// @dev Sanity check: composed + GOOD recipient is unchanged by the guard
    ///      — the base credit path still runs and unlocks the real token.
    function test_credit_composedGoodRecipient_stillUnlocks() public {
        ERC20Mock token = new ERC20Mock("Token", "TOKEN");
        ONOFTAdapterMock testAdapter = ONOFTAdapterMock(
            _deployOApp(
                type(ONOFTAdapterMock).creationCode,
                abi.encode(address(token), address(endpoints[aEid]), address(this))
            )
        );
        uint256 locked = 200 ether;
        token.mint(address(testAdapter), locked);

        address bob = address(0xB0B);
        testAdapter.creditComposed(bob, 10 ether, bEid);

        assertEq(token.balanceOf(bob), 10 ether, "good recipient receives unlock");
        assertEq(token.balanceOf(address(testAdapter)), locked - 10 ether, "adapter balance reduced");
    }
}

/// @dev 18-decimal ERC20 that burns 1% on every user-to-user transfer,
///      matching the FoT helper used in WrappedON.t.sol. Kept duplicated
///      rather than centralised because both test files compile in
///      isolation; this is a self-contained helper.
contract FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("Fee On Transfer", "FOT") {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
