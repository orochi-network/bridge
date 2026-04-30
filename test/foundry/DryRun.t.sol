// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { ONOFTAdapter } from "../../contracts/ONOFTAdapter.sol";
import { WrappedON } from "../../contracts/WrappedON.sol";

/// @title Forked-mainnet dry-run for the ON bridge.
/// @notice Forks BSC + ETH mainnet, deploys ONOFTAdapter / WrappedON against the real
///         ON tokens, and exercises the full bridge flow by impersonating the LayerZero
///         endpoint to deliver messages on the destination side. Real DVN/Executor
///         infrastructure is bypassed — only the on-chain logic of the bridge contracts
///         (and of the real ON tokens) is exercised.
///
///         Run with:
///             RPC_URL_BSC=https://... RPC_URL_ETH=https://... \
///                 forge test --match-contract DryRun -vvv
///
///         Skips cleanly when either RPC env var is missing.
contract DryRunTest is Test {
    using OptionsBuilder for bytes;

    // -------------------------------------------------------------------------
    // Mainnet constants (CLAUDE.md)
    // -------------------------------------------------------------------------

    address internal constant ON_BSC = 0x0e4F6209eD984b21EDEA43acE6e09559eD051D48;
    address internal constant ON_ETH = 0x33f6BE84becfF45ea6aA2952d7eF890B44bFB59d;
    address internal constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint32 internal constant EID_BSC = 30102;
    uint32 internal constant EID_ETH = 30101;

    // OFT shared decimals are 6, local decimals are 18 -> conversion factor 1e12.
    // Cross-chain amounts get rounded to multiples of DCR; pick test amounts that
    // are exact multiples to avoid dust loss confusing the assertions.
    uint256 internal constant DCR = 1e12;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    uint256 internal bscFork;
    uint256 internal ethFork;

    ONOFTAdapter internal adapter;
    WrappedON internal wON;

    address internal alice;
    address internal bob;
    address internal treasury;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        string memory rpcBsc = vm.envOr("RPC_URL_BSC", string(""));
        string memory rpcEth = vm.envOr("RPC_URL_ETH", string(""));
        if (bytes(rpcBsc).length == 0 || bytes(rpcEth).length == 0) {
            vm.skip(true, "DryRun: set RPC_URL_BSC and RPC_URL_ETH to run forked-mainnet tests");
            return;
        }

        bscFork = vm.createFork(rpcBsc);
        ethFork = vm.createFork(rpcEth);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        treasury = makeAddr("treasury");

        // Deploy the BSC-side adapter against the real ON token. The test contract
        // is owner + delegate; that's fine for a dry-run since we never hand off.
        vm.selectFork(bscFork);
        adapter = new ONOFTAdapter(ON_BSC, LZ_ENDPOINT, address(this));

        // Deploy the ETH-side WrappedON against the real ETH ON. Constructor will
        // revert with DecimalsMismatch if the reserve token is not 18 decimals,
        // which doubles as our pre-flight check.
        vm.selectFork(ethFork);
        wON = new WrappedON("Wrapped ON", "wON", LZ_ENDPOINT, address(this), ON_ETH);

        // Wire peers. We deliberately skip the full lz:oapp:wire flow (custom
        // libraries, DVNs, executor config) — defaults on the real endpoint are
        // sufficient for source-side send to succeed, and the destination side
        // is delivered by direct endpoint impersonation rather than DVN attestation.
        bytes32 wONPeer = bytes32(uint256(uint160(address(wON))));
        bytes32 adapterPeer = bytes32(uint256(uint160(address(adapter))));

        vm.selectFork(bscFork);
        adapter.setPeer(EID_ETH, wONPeer);

        vm.selectFork(ethFork);
        wON.setPeer(EID_BSC, adapterPeer);
    }

    // -------------------------------------------------------------------------
    // Token-assumption pre-flight checks (CLAUDE.md "things to fill in")
    // -------------------------------------------------------------------------

    /// @notice Asserts the real BSC ON token is lossless on transferFrom — i.e.
    ///         not fee-on-transfer or rebasing. The default ONOFTAdapter trusts
    ///         this and will silently lose backing if it's not true.
    function test_bsc_innerToken_isLossless() public {
        vm.selectFork(bscFork);

        address sender = makeAddr("losslessSender");
        address receiver = makeAddr("losslessReceiver");
        uint256 amount = 100 ether;

        deal(ON_BSC, sender, amount);

        uint256 senderBefore = IERC20(ON_BSC).balanceOf(sender);
        uint256 receiverBefore = IERC20(ON_BSC).balanceOf(receiver);

        vm.prank(sender);
        IERC20(ON_BSC).approve(address(this), amount);
        IERC20(ON_BSC).transferFrom(sender, receiver, amount);

        assertEq(
            IERC20(ON_BSC).balanceOf(sender),
            senderBefore - amount,
            "BSC ON: sender balance delta != amount (fee-on-transfer or rebase?)"
        );
        assertEq(
            IERC20(ON_BSC).balanceOf(receiver),
            receiverBefore + amount,
            "BSC ON: receiver balance delta != amount (fee-on-transfer or rebase?)"
        );
    }

    /// @notice Asserts the real ETH ON token reports 18 decimals. WrappedON's
    ///         constructor reverts on mismatch, so this passing also means the
    ///         setUp deploy succeeded — but we leave the explicit check for
    ///         clarity in the dry-run report.
    function test_eth_reserveToken_decimalsIs18() public {
        vm.selectFork(ethFork);
        assertEq(IERC20Metadata(ON_ETH).decimals(), 18, "ETH ON: decimals must be 18");
    }

    // -------------------------------------------------------------------------
    // Bridge: BSC -> ETH
    // -------------------------------------------------------------------------

    /// @notice Empty reserve on ETH -> wON is minted to the recipient (fallback path).
    function test_bridge_bscToEth_emptyReserve_mintsWON() public {
        uint256 amount = 100 ether;

        _bridgeBscToEth(alice, bob, amount, "");

        vm.selectFork(ethFork);
        assertEq(wON.balanceOf(bob), amount, "bob should hold wON");
        assertEq(IERC20(ON_ETH).balanceOf(bob), 0, "bob should hold no real ETH ON");
        assertEq(wON.reserve(), 0, "reserve should still be empty");

        vm.selectFork(bscFork);
        assertEq(IERC20(ON_BSC).balanceOf(address(adapter)), amount, "adapter must hold the locked ON");
    }

    /// @notice Sufficient reserve -> auto-unwrap pays out real ON, no wON minted.
    function test_bridge_bscToEth_seededReserve_autoUnwraps() public {
        uint256 amount = 100 ether;
        _seedReserve(2 * amount);

        _bridgeBscToEth(alice, bob, amount, "");

        vm.selectFork(ethFork);
        assertEq(IERC20(ON_ETH).balanceOf(bob), amount, "bob should receive real ETH ON");
        assertEq(wON.balanceOf(bob), 0, "no wON should be minted");
        assertEq(wON.reserve(), amount, "reserve should be drained by amount");
    }

    /// @notice Composed message must force the mint path even when the reserve
    ///         could cover the amount — the compose handler downstream expects
    ///         to operate on a wON balance.
    function test_bridge_bscToEth_composed_forcesMint() public {
        uint256 amount = 100 ether;
        uint256 seed = 5 * amount;
        _seedReserve(seed);

        // Use a fresh address as the "composer". We don't execute the compose;
        // we only verify the OFT delivered wON (not real ON) and the reserve
        // is untouched.
        address composer = makeAddr("composer");

        _bridgeBscToEth(alice, composer, amount, hex"1234");

        vm.selectFork(ethFork);
        assertEq(wON.balanceOf(composer), amount, "composer must hold wON (compose forces mint)");
        assertEq(IERC20(ON_ETH).balanceOf(composer), 0, "composer must NOT hold real ON");
        assertEq(wON.reserve(), seed, "reserve must be untouched on composed message");
    }

    // -------------------------------------------------------------------------
    // Manual swap surface against the real ETH ON
    // -------------------------------------------------------------------------

    /// @notice wrap mints wON 1:1 and adds to the reserve; unwrap reverses it.
    ///         seedReserve adds to the reserve without minting.
    function test_eth_wrap_unwrap_seedReserve_workWithRealReserve() public {
        vm.selectFork(ethFork);

        uint256 wrapAmount = 50 ether;
        uint256 seedAmount = 30 ether;

        deal(ON_ETH, alice, wrapAmount);
        deal(ON_ETH, treasury, seedAmount);

        // wrap
        vm.startPrank(alice);
        IERC20(ON_ETH).approve(address(wON), wrapAmount);
        wON.wrap(wrapAmount);
        vm.stopPrank();

        assertEq(wON.balanceOf(alice), wrapAmount, "alice should hold wON 1:1");
        assertEq(wON.reserve(), wrapAmount, "reserve should hold the wrap deposit");
        assertEq(IERC20(ON_ETH).balanceOf(alice), 0, "alice should have spent her ON");

        // seedReserve (one-way subsidy)
        uint256 totalSupplyBefore = wON.totalSupply();
        vm.startPrank(treasury);
        IERC20(ON_ETH).approve(address(wON), seedAmount);
        wON.seedReserve(seedAmount);
        vm.stopPrank();

        assertEq(wON.reserve(), wrapAmount + seedAmount, "reserve should grow by seed amount");
        assertEq(wON.totalSupply(), totalSupplyBefore, "seedReserve must not mint wON");

        // unwrap
        vm.prank(alice);
        wON.unwrap(wrapAmount);

        assertEq(wON.balanceOf(alice), 0, "alice's wON should be burned");
        assertEq(IERC20(ON_ETH).balanceOf(alice), wrapAmount, "alice should get her ON back");
        assertEq(wON.reserve(), seedAmount, "reserve should still hold the donation");
    }

    // -------------------------------------------------------------------------
    // Bridge: ETH -> BSC (round trip)
    // -------------------------------------------------------------------------

    /// @notice Full round trip: BSC -> ETH locks real ON in the adapter and
    ///         mints wON; ETH -> BSC burns wON and unlocks real ON on BSC.
    function test_bridge_ethToBsc_unlocksRealON_afterRoundTrip() public {
        uint256 amount = 100 ether;

        // Outbound: alice locks 100 ON on BSC, gets 100 wON on ETH (empty reserve).
        _bridgeBscToEth(alice, alice, amount, "");

        vm.selectFork(ethFork);
        assertEq(wON.balanceOf(alice), amount, "alice should hold wON after outbound");

        // Inbound: alice burns 100 wON on ETH, bob receives 100 real ON on BSC.
        _bridgeEthToBsc(alice, bob, amount);

        vm.selectFork(bscFork);
        assertEq(IERC20(ON_BSC).balanceOf(bob), amount, "bob should receive real BSC ON");
        assertEq(IERC20(ON_BSC).balanceOf(address(adapter)), 0, "adapter should no longer hold the lock");

        vm.selectFork(ethFork);
        assertEq(wON.balanceOf(alice), 0, "alice's wON should be burned");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Simulates a BSC -> ETH bridge:
    ///      1. On BSC fork: dial alice with real ON via cheatcode, approve adapter,
    ///         call adapter.send() through the real LZ endpoint (real fees paid).
    ///      2. Reconstruct the OFT message that was sent.
    ///      3. On ETH fork: impersonate the LZ endpoint and deliver the message
    ///         to wON.lzReceive. Bypasses real DVN/Executor.
    function _bridgeBscToEth(address from, address to, uint256 amount, bytes memory composeMsg) internal {
        // Source side
        vm.selectFork(bscFork);
        deal(ON_BSC, from, IERC20(ON_BSC).balanceOf(from) + amount);

        // Composed messages need a larger destination gas budget that includes
        // the lzCompose option (matches what the production wire config uses).
        bytes memory options = composeMsg.length == 0
            ? OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0)
            : OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                500_000,
                0
            );

        SendParam memory sp = SendParam({
            dstEid: EID_ETH,
            to: bytes32(uint256(uint160(to))),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: options,
            composeMsg: composeMsg,
            oftCmd: ""
        });

        MessagingFee memory fee = adapter.quoteSend(sp, false);
        vm.deal(from, fee.nativeFee);

        vm.startPrank(from);
        IERC20(ON_BSC).approve(address(adapter), amount);
        (MessagingReceipt memory mReceipt, ) = adapter.send{ value: fee.nativeFee }(sp, fee, payable(from));
        vm.stopPrank();

        // Destination side
        vm.selectFork(ethFork);
        bytes memory message = composeMsg.length == 0
            ? _buildPlainMessage(to, amount)
            : _buildComposedMessage(to, amount, from, composeMsg);

        Origin memory origin = Origin({
            srcEid: EID_BSC,
            sender: bytes32(uint256(uint160(address(adapter)))),
            nonce: mReceipt.nonce
        });

        vm.prank(LZ_ENDPOINT);
        wON.lzReceive(origin, mReceipt.guid, message, address(0), "");
    }

    /// @dev Simulates an ETH -> BSC bridge. Caller must already hold wON
    ///      (acquired via prior inbound bridge or wrap()).
    function _bridgeEthToBsc(address from, address to, uint256 amount) internal {
        // Source side (ETH)
        vm.selectFork(ethFork);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0);
        SendParam memory sp = SendParam({
            dstEid: EID_BSC,
            to: bytes32(uint256(uint160(to))),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory fee = wON.quoteSend(sp, false);
        vm.deal(from, fee.nativeFee);

        vm.startPrank(from);
        (MessagingReceipt memory mReceipt, ) = wON.send{ value: fee.nativeFee }(sp, fee, payable(from));
        vm.stopPrank();

        // Destination side (BSC)
        vm.selectFork(bscFork);
        bytes memory message = _buildPlainMessage(to, amount);

        Origin memory origin = Origin({
            srcEid: EID_ETH,
            sender: bytes32(uint256(uint160(address(wON)))),
            nonce: mReceipt.nonce
        });

        vm.prank(LZ_ENDPOINT);
        adapter.lzReceive(origin, mReceipt.guid, message, address(0), "");
    }

    /// @dev Drops `amount` real ETH ON into the wON reserve via seedReserve,
    ///      using a freshly-funded treasury account.
    function _seedReserve(uint256 amount) internal {
        vm.selectFork(ethFork);
        deal(ON_ETH, treasury, IERC20(ON_ETH).balanceOf(treasury) + amount);
        vm.startPrank(treasury);
        IERC20(ON_ETH).approve(address(wON), amount);
        wON.seedReserve(amount);
        vm.stopPrank();
    }

    /// @dev OFTMsgCodec plain-message encoding: bytes32(to) || uint64(amountSD).
    function _buildPlainMessage(address to, uint256 amountLD) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(to))), uint64(amountLD / DCR));
    }

    /// @dev OFTMsgCodec composed-message encoding:
    ///      bytes32(to) || uint64(amountSD) || bytes32(from) || composeMsg.
    function _buildComposedMessage(
        address to,
        uint256 amountLD,
        address from,
        bytes memory composeMsg
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                bytes32(uint256(uint160(to))),
                uint64(amountLD / DCR),
                bytes32(uint256(uint160(from))),
                composeMsg
            );
    }
}
