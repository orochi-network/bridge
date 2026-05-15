// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBurnMintERC20} from "@chainlink/contracts-ccip/shared/token/ERC20/IBurnMintERC20.sol";
import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/ccip/interfaces/IGetCCIPAdmin.sol";

/// @title Wrapped Orochi Network Token (wON)
/// @notice Mintable/burnable ERC20 used by the Chainlink CCIP BurnMintTokenPool on Ethereum,
///         and a 1:1 wrapper around the canonical (non-mintable) ON token.
///
/// wON has two mint paths, both producing identical fungible tokens but backed differently:
///   1. `deposit(amount)` — user transfers native ON into this contract; wON minted is backed
///      1:1 by the ON held in this contract's reserve.
///   2. `mint(...)` (MINTER_ROLE) — CCIP pool mints when value arrives from BSC; backing is ON
///      locked on the BSC LockReleaseTokenPool, not on this contract.
///
/// Invariant (documented, not enforced on-chain):
///   wrapBackedSupply <= ON.balanceOf(WrappedON)
/// `withdraw` reverts when the reserve cannot cover the requested amount.
///
/// Supply cap: `MAX_CCIP_MINTED = 100M` bounds the `ccipMintedSupply` counter, which
/// approximates the BSC pool's expected locked-ON balance — every CCIP `mint` on this
/// contract is paired with a `lock` of the same amount on the BSC pool, and every CCIP
/// `burn` here is paired with a `release` there. The counter is therefore a defense-in-
/// depth check against a compromised or buggy pool minting wON without a matching BSC
/// lock; it does NOT bound `totalSupply()`, which can also grow via the `deposit()` path.
///
/// The cap is intentionally NOT a circulating-CCIP-minted ceiling — wON is fungible by
/// design, so once minted there is no on-chain way to tell whether a token came from
/// `deposit` or `mint`. Saturating-subtract on burn handles the case where deposit-backed
/// wON is bridged out (no corresponding BSC release was made via that wON specifically,
/// but the pool's lock/release accounting still nets out).
///
/// Safety invariant (preserved by mechanics, not by the counter alone):
///   `lockedON_BSC + reserveON_ETH >= totalSupply(wON)`
/// CCIP guarantees every mint here is paired with a lock on BSC, and every burn here is
/// paired with a release on BSC. `deposit` adds to both `totalSupply` and `reserveON_ETH`
/// in lockstep; `withdraw` subtracts from both. See SECURITY.md C-3 + R-1 + R-14 for the
/// full reasoning.
///
/// @dev `IBurnMintERC20` is NOT inherited because it transitively brings the CCIP-vendored
/// `IERC20` interface, which conflicts with OpenZeppelin's `IERC20` linearization. The
/// function selectors (`mint`, `burn`, `burn(address,uint256)`, `burnFrom`) match the
/// interface exactly, so the BurnMintTokenPool calls succeed at runtime regardless.
/// `type(IBurnMintERC20).interfaceId` is still reported by `supportsInterface`.
contract WrappedON is ERC20, AccessControl, ReentrancyGuard, IGetCCIPAdmin {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Hard cap on `ccipMintedSupply`. Matches the canonical ON supply on BSC, which
    ///         is the absolute upper bound on ON that can ever be locked on the BSC pool.
    uint256 public constant MAX_CCIP_MINTED = 100_000_000 ether;

    /// @notice Canonical Orochi Network token on this chain (non-mintable ERC20).
    IERC20 public immutable ON;

    /// @notice Approximates the BSC pool's expected locked-ON balance. Incremented by every
    ///         CCIP `mint()`, saturating-decremented by every CCIP burn. Under honest CCIP
    ///         operation `ccipMintedSupply == lockedON_BSC` at all times; under a hypothetical
    ///         CCIP-side bug (mint without lock) the cap at 100M still bounds the damage.
    ///         The counter does NOT track deposit-backed wON — see contract NatSpec for the
    ///         full reasoning on why a circulating-CCIP-minted accounting is not viable on a
    ///         fungible token, and why the safety invariant is preserved by mechanics anyway.
    uint256 public ccipMintedSupply;

    /// @notice CCIP admin used by `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin`.
    /// @dev Independent from `DEFAULT_ADMIN_ROLE`. Rotation is two-step (propose + accept) to
    /// prevent typos / wrong-address handoffs locking the role.
    address private s_ccipAdmin;
    address private s_pendingCcipAdmin;

    event Wrapped(address indexed account, uint256 amount);
    event Unwrapped(address indexed account, uint256 amount);
    event CCIPAdminTransferProposed(address indexed currentAdmin, address indexed proposed);
    event CCIPAdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error InsufficientReserve(uint256 requested, uint256 available);
    error OnlyCCIPAdmin();
    error OnlyPendingCCIPAdmin();
    error ZeroAddress();
    error ZeroAmount();
    error SelfReserve();
    error DecimalsMismatch(uint8 expected, uint8 actual);
    error CCIPMintCapExceeded(uint256 cap, uint256 wouldBe);
    error DecimalsUnreadable();

    constructor(IERC20 onToken, address admin) ERC20("Wrapped Orochi Network", "wON") {
        if (address(onToken) == address(0) || admin == address(0)) revert ZeroAddress();
        // Defensive: catches CREATE2 salt mistakes and testnet misconfigs where the supplied
        // ON address would collide with the wON deployment address — making the reserve
        // invariant `wrapBackedSupply <= ON.balanceOf(this)` circular and meaningless.
        if (address(onToken) == address(this)) revert SelfReserve();
        // Defensive: 1:1 wrap accounting only holds when both tokens use the same decimals.
        // Canonical ON is 18 decimals on both ETH and BSC; reject anything else early. Wrap
        // in try/catch so a non-conformant `onToken` (no `decimals()`) reverts with a clear
        // diagnostic instead of a low-level ABI-decode error (round-2 review [8]).
        try IERC20Metadata(address(onToken)).decimals() returns (uint8 onDecimals) {
            if (onDecimals != decimals()) revert DecimalsMismatch(decimals(), onDecimals);
        } catch {
            revert DecimalsUnreadable();
        }
        ON = onToken;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        s_ccipAdmin = admin;
        emit CCIPAdminTransferred(address(0), admin);
    }

    // ─── Wrap / Unwrap (1:1 against native ON) ────────────────────────────────

    /// @notice Pulls `amount` ON into the reserve and mints `amount` wON to msg.sender.
    /// @dev Uses received-amount accounting so the wrap remains exactly 1:1 even if the ON
    ///      contract is ever upgraded/replaced with a fee-on-transfer variant (defensive —
    ///      canonical ON is currently a plain ERC20). Reentrancy-guarded as a belt-and-braces
    ///      measure against future hook-bearing tokens.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = ON.balanceOf(address(this));
        ON.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = ON.balanceOf(address(this)) - before;
        // Deposit is uncapped — bounded naturally by the ETH-side ON supply. Independent of
        // MAX_CCIP_MINTED so heavy wrap usage cannot starve inbound CCIP messages.
        _mint(msg.sender, received);
        emit Wrapped(msg.sender, received);
    }

    /// @dev Does NOT decrement `ccipMintedSupply`. The counter approximates the BSC pool's
    /// locked-ON balance, which is unaffected by withdraws — `withdraw` only moves ETH-side
    /// reserve, never triggers a BSC release. Decrementing here would desync the counter
    /// from BSC pool balance and would not improve any safety property. The cost is that a
    /// CCIP-minted holder can consume the deposit reserve (intended: arbitrage-layer
    /// design, SECURITY.md C-1). Round-2 review [2].
    function withdraw(uint256 amount) external nonReentrant {
        uint256 reserve = ON.balanceOf(address(this));
        if (reserve < amount) revert InsufficientReserve(amount, reserve);
        _burn(msg.sender, amount);
        ON.safeTransfer(msg.sender, amount);
        emit Unwrapped(msg.sender, amount);
    }

    // ─── IBurnMintERC20 (pool-only) ───────────────────────────────────────────

    /// @notice CCIP `BurnMintTokenPool.releaseOrMint` entrypoint. Capped at `MAX_CCIP_MINTED`
    ///         (the canonical BSC ON supply) — the absolute upper bound on what the bridge can
    ///         ever reflect onto Ethereum. Tracked via `ccipMintedSupply` so the cap is not
    ///         consumed by deposit-backed wON.
    function mint(address account, uint256 amount) external onlyRole(MINTER_ROLE) {
        uint256 wouldBe = ccipMintedSupply + amount;
        if (wouldBe > MAX_CCIP_MINTED) revert CCIPMintCapExceeded(MAX_CCIP_MINTED, wouldBe);
        ccipMintedSupply = wouldBe;
        _mint(account, amount);
    }

    /// @notice Burns `amount` from `msg.sender`. Used by `BurnMintTokenPool._burn`,
    ///         which transfers user tokens to itself first and then calls `burn(amount)`.
    function burn(uint256 amount) external onlyRole(BURNER_ROLE) {
        _decrementCcipMinted(amount);
        _burn(msg.sender, amount);
    }

    /// @dev Does NOT check allowance — `BURNER_ROLE` must be held exclusively by the audited
    ///      `BurnMintTokenPool`. Matches `IBurnMintERC20` semantics.
    function burn(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        _decrementCcipMinted(amount);
        _burn(account, amount);
    }

    function burnFrom(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        _spendAllowance(account, msg.sender, amount);
        _decrementCcipMinted(amount);
        _burn(account, amount);
    }

    // ─── IGetCCIPAdmin (two-step) ─────────────────────────────────────────────

    function getCCIPAdmin() external view returns (address) {
        return s_ccipAdmin;
    }

    function pendingCCIPAdmin() external view returns (address) {
        return s_pendingCcipAdmin;
    }

    /// @notice Proposes a new CCIP admin. The proposed address must call `acceptCCIPAdmin`
    ///         to complete the transfer. Two-step prevents typos and lost-key handoffs.
    function setCCIPAdmin(address newAdmin) external {
        if (msg.sender != s_ccipAdmin) revert OnlyCCIPAdmin();
        if (newAdmin == address(0)) revert ZeroAddress();
        s_pendingCcipAdmin = newAdmin;
        emit CCIPAdminTransferProposed(s_ccipAdmin, newAdmin);
    }

    function acceptCCIPAdmin() external {
        if (msg.sender != s_pendingCcipAdmin) revert OnlyPendingCCIPAdmin();
        emit CCIPAdminTransferred(s_ccipAdmin, msg.sender);
        s_ccipAdmin = msg.sender;
        s_pendingCcipAdmin = address(0);
    }

    // ─── IERC165 ──────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId) public pure override(AccessControl) returns (bool) {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IBurnMintERC20).interfaceId
            || interfaceId == type(IGetCCIPAdmin).interfaceId || interfaceId == type(IAccessControl).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /// @dev Saturating subtract. Every CCIP-route burn here corresponds to a BSC pool
    /// `release` of the same amount on the other side — so the counter, viewed as the BSC
    /// pool's expected locked-ON balance, tracks down in lockstep. Saturation is a defensive
    /// floor: under honest CCIP operation `ccipMintedSupply` never falls below 0 anyway
    /// (BSC pool balance can't go negative), so the saturation only matters if a buggy or
    /// compromised pool over-burns. See contract NatSpec + SECURITY.md R-14 for the
    /// reasoning on why this is NOT a per-token-provenance counter.
    function _decrementCcipMinted(uint256 amount) internal {
        uint256 current = ccipMintedSupply;
        ccipMintedSupply = amount >= current ? 0 : current - amount;
    }
}
