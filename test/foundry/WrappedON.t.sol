// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingFee } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";

import { OFTAdapterMock } from "../mocks/OFTAdapterMock.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
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
        // ERC20Mock returns 18 by default — deploy a 6-decimal variant via raw hack:
        // we can't easily change ERC20Mock's decimals, so use a token with non-18 decimals.
        // Skip this case if the mock doesn't support it; otherwise:
        SixDecimalERC20 wrong = new SixDecimalERC20();
        vm.expectRevert(abi.encodeWithSelector(WrappedON.DecimalsMismatch.selector, uint8(6)));
        new WrappedONMock("Wrapped ON", "wON", address(endpoints[ETH_EID]), address(this), address(wrong));
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
}

/// @dev Helper: a 6-decimal ERC20 to verify constructor enforces the decimals check.
contract SixDecimalERC20 {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}
