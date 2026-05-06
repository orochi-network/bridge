// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { RateLimiter } from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";
import { SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingFee } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";

import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { ONOFTAdapterMock } from "../../contracts/mocks/ONOFTAdapterMock.sol";
import { WrappedONMock } from "../../contracts/mocks/WrappedONMock.sol";

/// @notice Outbound rate-limit behaviour for both ONOFTAdapter (BSC side) and
///         WrappedON (ETH side). Inbound is intentionally NOT rate-limited;
///         see contract-level NatSpec for the rationale.
contract RateLimitTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 private constant BSC_EID = 1;
    uint32 private constant ETH_EID = 2;

    ERC20Mock private bscON;
    ERC20Mock private ethON;
    ONOFTAdapterMock private adapter;
    WrappedONMock private wON;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private outsider = address(0xBAD);

    uint256 private constant INITIAL = 1_000 ether;

    function setUp() public virtual override {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        bscON = ERC20Mock(_deployOApp(type(ERC20Mock).creationCode, abi.encode("BSC ON", "ON")));
        ethON = ERC20Mock(_deployOApp(type(ERC20Mock).creationCode, abi.encode("ETH ON", "ON")));

        adapter = ONOFTAdapterMock(
            _deployOApp(
                type(ONOFTAdapterMock).creationCode,
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

        bscON.mint(alice, INITIAL);
        wON.mint(alice, INITIAL);
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _bscSend(address _from, address _to, uint256 _amount) internal {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory p = SendParam({
            dstEid: ETH_EID,
            to: addressToBytes32(_to),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory fee = adapter.quoteSend(p, false);

        vm.startPrank(_from);
        bscON.approve(address(adapter), _amount);
        adapter.send{ value: fee.nativeFee }(p, fee, payable(_from));
        vm.stopPrank();
    }

    function _ethSend(address _from, address _to, uint256 _amount) internal {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory p = SendParam({
            dstEid: BSC_EID,
            to: addressToBytes32(_to),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory fee = wON.quoteSend(p, false);

        vm.startPrank(_from);
        wON.send{ value: fee.nativeFee }(p, fee, payable(_from));
        vm.stopPrank();
    }

    function _setLimit(address _oapp, uint32 _dstEid, uint192 _limit, uint64 _window) internal {
        RateLimiter.RateLimitConfig[] memory cfg = new RateLimiter.RateLimitConfig[](1);
        cfg[0] = RateLimiter.RateLimitConfig({ dstEid: _dstEid, limit: _limit, window: _window });
        // Both contracts expose `setRateLimits(RateLimitConfig[])` as onlyOwner.
        // The test contract is the owner via `_deployOApp`'s constructor wiring.
        if (_oapp == address(adapter)) {
            adapter.setRateLimits(cfg);
        } else {
            wON.setRateLimits(cfg);
        }
    }

    // -------------------------------------------------------------------------
    // unconfigured EID -> unlimited (bypass)
    // -------------------------------------------------------------------------

    function test_unconfigured_bypassesLimit_bsc() public {
        // No setRateLimits call. A 500-ether send must succeed because the
        // (limit=0, window=0) default is treated as "disabled".
        _bscSend(alice, bob, 500 ether);
        assertEq(bscON.balanceOf(address(adapter)), 500 ether);
    }

    function test_unconfigured_bypassesLimit_eth() public {
        _ethSend(alice, bob, 500 ether);
        assertEq(wON.balanceOf(alice), INITIAL - 500 ether);
    }

    // -------------------------------------------------------------------------
    // exceed-limit revert
    // -------------------------------------------------------------------------

    function test_exceedsLimit_reverts_bsc() public {
        _setLimit(address(adapter), ETH_EID, 100 ether, 60);

        // First send fits exactly; reaches the cap.
        _bscSend(alice, bob, 100 ether);

        // Second send (>= shared-decimals dust) exceeds the cap immediately;
        // 60s window has not elapsed yet so no decay. 1 ether stays well above
        // the OFT shared-decimals rounding threshold.
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory p = SendParam({
            dstEid: ETH_EID,
            to: addressToBytes32(bob),
            amountLD: 1 ether,
            minAmountLD: 1 ether,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory fee = adapter.quoteSend(p, false);
        vm.startPrank(alice);
        bscON.approve(address(adapter), 1 ether);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        adapter.send{ value: fee.nativeFee }(p, fee, payable(alice));
        vm.stopPrank();
    }

    function test_exceedsLimit_reverts_eth() public {
        _setLimit(address(wON), BSC_EID, 100 ether, 60);

        _ethSend(alice, bob, 100 ether);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory p = SendParam({
            dstEid: BSC_EID,
            to: addressToBytes32(bob),
            amountLD: 1 ether,
            minAmountLD: 1 ether,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory fee = wON.quoteSend(p, false);
        vm.startPrank(alice);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        wON.send{ value: fee.nativeFee }(p, fee, payable(alice));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // single-call > limit also reverts
    // -------------------------------------------------------------------------

    function test_singleSendOverLimit_reverts() public {
        _setLimit(address(adapter), ETH_EID, 100 ether, 60);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory p = SendParam({
            dstEid: ETH_EID,
            to: addressToBytes32(bob),
            amountLD: 101 ether,
            minAmountLD: 101 ether,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory fee = adapter.quoteSend(p, false);

        vm.startPrank(alice);
        bscON.approve(address(adapter), 101 ether);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        adapter.send{ value: fee.nativeFee }(p, fee, payable(alice));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // linear decay restores capacity over time
    // -------------------------------------------------------------------------

    function test_decayRestoresCapacityOverTime() public {
        _setLimit(address(adapter), ETH_EID, 100 ether, 60);

        _bscSend(alice, bob, 100 ether); // fills the bucket

        // Half the window passes -> ~50 ether of capacity restored.
        skip(30);

        (uint256 inFlight, uint256 canSend) = adapter.getAmountCanBeSent(ETH_EID);
        assertApproxEqAbs(inFlight, 50 ether, 1, "in flight should be ~50e18");
        assertApproxEqAbs(canSend, 50 ether, 1, "can-send should be ~50e18");

        // Sending exactly the available capacity must succeed.
        _bscSend(alice, bob, canSend);

        (, uint256 canSendAfter) = adapter.getAmountCanBeSent(ETH_EID);
        assertEq(canSendAfter, 0, "bucket fully refilled then drained");
    }

    function test_fullWindow_resetsCapacity() public {
        _setLimit(address(adapter), ETH_EID, 100 ether, 60);

        _bscSend(alice, bob, 100 ether);

        skip(60); // full window passes

        (, uint256 canSend) = adapter.getAmountCanBeSent(ETH_EID);
        assertEq(canSend, 100 ether, "full window restores full capacity");

        _bscSend(alice, bob, 100 ether);
    }

    // -------------------------------------------------------------------------
    // resetRateLimits clears in-flight
    // -------------------------------------------------------------------------

    function test_resetRateLimits_clearsInFlight() public {
        _setLimit(address(adapter), ETH_EID, 100 ether, 60);
        _bscSend(alice, bob, 100 ether);

        (uint256 inFlightBefore, ) = adapter.getAmountCanBeSent(ETH_EID);
        assertEq(inFlightBefore, 100 ether);

        uint32[] memory eids = new uint32[](1);
        eids[0] = ETH_EID;
        adapter.resetRateLimits(eids);

        (uint256 inFlightAfter, uint256 canSendAfter) = adapter.getAmountCanBeSent(ETH_EID);
        assertEq(inFlightAfter, 0, "reset zeros in-flight");
        assertEq(canSendAfter, 100 ether, "full capacity available immediately after reset");
    }

    // -------------------------------------------------------------------------
    // owner-only access control
    // -------------------------------------------------------------------------

    function test_setRateLimits_revertsForNonOwner_bsc() public {
        RateLimiter.RateLimitConfig[] memory cfg = new RateLimiter.RateLimitConfig[](1);
        cfg[0] = RateLimiter.RateLimitConfig({ dstEid: ETH_EID, limit: 100 ether, window: 60 });

        vm.prank(outsider);
        vm.expectRevert(); // OZ Ownable: OwnableUnauthorizedAccount
        adapter.setRateLimits(cfg);
    }

    function test_setRateLimits_revertsForNonOwner_eth() public {
        RateLimiter.RateLimitConfig[] memory cfg = new RateLimiter.RateLimitConfig[](1);
        cfg[0] = RateLimiter.RateLimitConfig({ dstEid: BSC_EID, limit: 100 ether, window: 60 });

        vm.prank(outsider);
        vm.expectRevert();
        wON.setRateLimits(cfg);
    }

    function test_resetRateLimits_revertsForNonOwner() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = ETH_EID;
        vm.prank(outsider);
        vm.expectRevert();
        adapter.resetRateLimits(eids);
    }

    // -------------------------------------------------------------------------
    // setRateLimits emits + preserves in-flight on reconfigure
    // -------------------------------------------------------------------------

    function test_setRateLimits_preservesAmountInFlightAcrossReconfigure() public {
        _setLimit(address(adapter), ETH_EID, 100 ether, 60);
        _bscSend(alice, bob, 60 ether);

        // Tighten the cap; in-flight (60e18) should remain.
        _setLimit(address(adapter), ETH_EID, 80 ether, 60);

        (uint256 inFlight, uint256 canSend) = adapter.getAmountCanBeSent(ETH_EID);
        assertApproxEqAbs(inFlight, 60 ether, 1, "in-flight preserved across reconfigure");
        assertApproxEqAbs(canSend, 20 ether, 1, "remaining headroom = newLimit - inFlight");
    }
}
