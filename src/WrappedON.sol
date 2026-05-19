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
/// @notice CCIP `BurnMintTokenPool` token on Ethereum + 1:1 wrapper for canonical ON.
///
/// Two mint paths, both fungible, backed differently:
///   1. `deposit` — pulls ON, mints wON; backed by `ON.balanceOf(this)`.
///   2. `mint` (MINTER_ROLE) — CCIP pool mints on BSC→ETH arrival; backed by ON locked on
///      the BSC `LockReleaseTokenPool`.
///
/// Wrap-reserve invariant (mechanical, not stored): `{wON minted via deposit and still
/// circulating} <= ON.balanceOf(this)`. Enforced by `withdraw` reverting when reserve is
/// insufficient, plus `deposit`'s received-amount accounting.
///
/// `MAX_CCIP_MINTED = 100M` caps `ccipMintedSupply`, which approximates the BSC pool's
/// locked-ON balance (every CCIP `mint` here pairs a BSC `lock`; every CCIP burn pairs a
/// BSC `release`). The cap bounds damage from a compromised pool; it does NOT bound
/// `totalSupply()` (the `deposit` path is uncapped). Not a per-token-provenance counter —
/// wON is fungible. Saturating-subtract on burn handles deposit-backed wON being bridged
/// out; pool lock/release accounting nets out regardless.
///
/// Safety invariant (mechanical): `lockedON_BSC + reserveON_ETH >= totalSupply(wON)`.
/// See SECURITY.md C-3 / R-1 / R-14 for the full reasoning.
///
/// @dev `IBurnMintERC20` is NOT inherited — it brings the CCIP-vendored `IERC20`, which
/// conflicts with OZ `IERC20` linearization. Selectors match the interface exactly so
/// pool calls succeed; `type(IBurnMintERC20).interfaceId` is still reported by
/// `supportsInterface`.
contract WrappedON is ERC20, AccessControl, ReentrancyGuard, IGetCCIPAdmin {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Cap on `ccipMintedSupply`. Matches canonical BSC ON supply — the upper bound
    ///         on ON that can ever be locked on the BSC pool.
    uint256 public constant MAX_CCIP_MINTED = 100_000_000 ether;

    /// @notice Canonical ON on this chain (non-mintable ERC20).
    IERC20 public immutable ON;

    /// @notice Approximates BSC pool's locked-ON balance. Incremented by CCIP `mint`,
    ///         saturating-decremented by CCIP burns. Cap bounds damage from a buggy pool
    ///         minting without a matching BSC lock. See contract NatSpec for why this is
    ///         not a per-token-provenance counter.
    uint256 public ccipMintedSupply;

    /// @notice CCIP admin read by `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin`.
    /// @dev Independent of `DEFAULT_ADMIN_ROLE`. Two-step rotation (propose + accept) so a
    /// typo can't lock the role.
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
    error InvalidCCIPAdmin();

    /// @notice Deploys wON wired to canonical ON and a bootstrap `admin`.
    /// @dev `admin` gets `DEFAULT_ADMIN_ROLE` AND becomes initial `s_ccipAdmin`; both
    ///      hand off to the multisig (two-step each) before the deployer renounces. Rejects
    ///      zero-address, self-reserve, and decimals-mismatch / unreadable tokens.
    constructor(IERC20 onToken, address admin) ERC20("Wrapped Orochi Network", "wON") {
        if (address(onToken) == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        // Self-reserve would make the wrap invariant circular (own ERC20 balance double-counts).
        if (address(onToken) == address(this)) {
            revert SelfReserve();
        }
        // 1:1 wrap accounting requires matching decimals. Canonical ON is a standard ERC20Metadata
        // on both chains; rejects mis-wired testnet tokens.
        uint8 onDecimals = IERC20Metadata(address(onToken)).decimals();
        if (onDecimals != decimals()) {
            revert DecimalsMismatch(decimals(), onDecimals);
        }
        ON = onToken;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        s_ccipAdmin = admin;
        emit CCIPAdminTransferred(address(0), admin);
    }

    // ─── Wrap / Unwrap (1:1 against native ON) ────────────────────────────────

    /// @notice Pulls `amount` ON and mints wON to `msg.sender` (1:1).
    /// @dev Received-amount accounting keeps the wrap exact under fee-on-transfer variants
    ///      (defensive; canonical ON is plain ERC20). `nonReentrant` guards against future
    ///      hook-bearing tokens. Uncapped — bounded by ETH-side ON supply; independent of
    ///      `MAX_CCIP_MINTED` so heavy wrap usage can't starve inbound CCIP.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 before = ON.balanceOf(address(this));
        ON.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = ON.balanceOf(address(this)) - before;
        _mint(msg.sender, received);
        emit Wrapped(msg.sender, received);
    }

    /// @notice Burns `amount` wON from `msg.sender` and returns `amount` ON from the reserve.
    /// @dev Does NOT decrement `ccipMintedSupply` — `withdraw` only moves ETH-side reserve
    ///      and never triggers a BSC release, so decrementing would desync from BSC balance.
    ///      Cost: a CCIP-minted holder can drain the deposit reserve (intended arbitrage
    ///      layer; SECURITY.md C-1 / R-15).
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 reserve = ON.balanceOf(address(this));
        if (reserve < amount) {
            revert InsufficientReserve(amount, reserve);
        }
        _burn(msg.sender, amount);
        ON.safeTransfer(msg.sender, amount);
        emit Unwrapped(msg.sender, amount);
    }

    // ─── IBurnMintERC20 (pool-only) ───────────────────────────────────────────

    /// @notice CCIP `BurnMintTokenPool.releaseOrMint` entrypoint. Capped at
    ///         `MAX_CCIP_MINTED`; cap tracked via `ccipMintedSupply` so deposit-backed wON
    ///         does not consume it.
    function mint(address account, uint256 amount) external onlyRole(MINTER_ROLE) {
        uint256 wouldBe = ccipMintedSupply + amount;
        if (wouldBe > MAX_CCIP_MINTED) {
            revert CCIPMintCapExceeded(MAX_CCIP_MINTED, wouldBe);
        }
        ccipMintedSupply = wouldBe;
        _mint(account, amount);
    }

    /// @notice Burns from `msg.sender`. Called by `BurnMintTokenPool._burn` after the pool
    ///         transfers user tokens to itself.
    function burn(uint256 amount) external onlyRole(BURNER_ROLE) {
        _decrementCcipMinted(amount);
        _burn(msg.sender, amount);
    }

    /// @notice Burns from `account` without allowance check (matches `IBurnMintERC20`).
    /// @dev `BURNER_ROLE` must be held exclusively by the audited pool.
    function burn(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        _decrementCcipMinted(amount);
        _burn(account, amount);
    }

    /// @notice Allowance-respecting burn. For pool variants that go through `approve`.
    function burnFrom(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        _spendAllowance(account, msg.sender, amount);
        _decrementCcipMinted(amount);
        _burn(account, amount);
    }

    // ─── IGetCCIPAdmin (two-step) ─────────────────────────────────────────────

    /// @notice Current CCIP admin. Read by `RegistryModuleOwnerCustom`.
    function getCCIPAdmin() external view returns (address) {
        return s_ccipAdmin;
    }

    /// @notice Proposed-but-not-accepted CCIP admin (zero if none). Handoff scripts assert
    ///         this equals the multisig before the deployer renounces.
    function pendingCCIPAdmin() external view returns (address) {
        return s_pendingCcipAdmin;
    }

    /// @notice Proposes a new CCIP admin; proposed address must call `acceptCCIPAdmin`.
    /// @dev Rejects self-proposal (would silently cancel any in-flight pending) and
    ///      `address(this)` (would write an unreachable pending, soft-locking the role).
    ///      Both via `InvalidCCIPAdmin` — R-56.
    function setCCIPAdmin(address newAdmin) external {
        if (msg.sender != s_ccipAdmin) {
            revert OnlyCCIPAdmin();
        }
        if (newAdmin == address(0)) {
            revert ZeroAddress();
        }
        if (newAdmin == s_ccipAdmin || newAdmin == address(this)) {
            revert InvalidCCIPAdmin();
        }
        s_pendingCcipAdmin = newAdmin;
        emit CCIPAdminTransferProposed(s_ccipAdmin, newAdmin);
    }

    /// @notice Completes the two-step CCIP admin transfer. Caller must equal the pending
    ///         address; pending slot is cleared on success.
    function acceptCCIPAdmin() external {
        if (msg.sender != s_pendingCcipAdmin) {
            revert OnlyPendingCCIPAdmin();
        }
        emit CCIPAdminTransferred(s_ccipAdmin, msg.sender);
        s_ccipAdmin = msg.sender;
        s_pendingCcipAdmin = address(0);
    }

    // ─── IERC165 ──────────────────────────────────────────────────────────────

    /// @notice ERC-165 advertisement. Reports `IBurnMintERC20` despite no formal inheritance
    ///         (selectors are reproduced manually — see contract NatSpec).
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IBurnMintERC20).interfaceId
            || interfaceId == type(IGetCCIPAdmin).interfaceId || interfaceId == type(IAccessControl).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /// @dev Saturating subtract. Under honest CCIP each burn pairs a BSC `release`, so the
    ///      counter tracks `lockedON_BSC` down in lockstep. Saturation is a defensive floor —
    ///      only matters if a buggy/compromised pool over-burns. See SECURITY.md R-14 / R-23
    ///      for why this is not a per-token-provenance counter.
    function _decrementCcipMinted(uint256 amount) internal {
        uint256 current = ccipMintedSupply;
        ccipMintedSupply = amount >= current ? 0 : current - amount;
    }
}
