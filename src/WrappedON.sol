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
/// `MAX_CCIP_MINTED = 100M` caps `ccipEstimatedUsedHeadroom` — an ESTIMATE of how much of
/// that cap is currently consumed by CCIP-minted wON (remaining headroom is
/// `MAX_CCIP_MINTED - ccipEstimatedUsedHeadroom`). It approximates the BSC pool's locked-ON
/// balance (every CCIP `mint` here pairs a BSC `lock`; every CCIP burn pairs a BSC
/// `release`), but is NOT an authoritative liquidity figure — see the naming note below.
/// The cap bounds damage from a compromised pool; it does NOT bound `totalSupply()` (the
/// `deposit` path is uncapped). Not a per-token-provenance counter — wON is fungible.
/// Saturating-subtract on burn handles deposit-backed wON being bridged out; pool
/// lock/release accounting nets out regardless.
///
/// NAMING (SECURITY: Report M1 / WON-3): the counter was previously `ccipMintedSupply`,
/// which implied an authoritative tally of CCIP-minted supply. Because deposit-backed wON
/// can be bridged out and saturating-decrement the counter (see CAP REPLENISHMENT below),
/// it can read BELOW true BSC-locked exposure — so it must NOT be used as a source of truth
/// for BSC-side liquidity. The `Estimated`/`Used` framing makes that explicit. The
/// authoritative BSC-exposure read is `ON.balanceOf(BSC_LockReleaseTokenPool)` (off-chain).
///
/// CAP REPLENISHMENT (SECURITY: CCIP-7): the cap is a live BSC-balance approximation, NOT
/// a lifetime CCIP-mint bound. Deposit-backed wON cycled OUT through the bridge will burn
/// and saturating-decrement `ccipEstimatedUsedHeadroom` toward 0 even though the underlying mint
/// was never CCIP-sourced — refilling cap headroom for subsequent CCIP inbound mints. The
/// safety invariant (`lockedON_BSC + reserveON_ETH >= totalSupply(wON)`) is preserved
/// regardless, because every CCIP mint here still pairs a BSC lock at the cap-checked
/// moment, and burns reverse both sides in lockstep. Monitor `ccipEstimatedUsedHeadroom` AS A
/// FRACTION OF CURRENT BSC LOCKED BALANCE — not as a fraction of MAX_CCIP_MINTED — for an
/// accurate live-exposure read.
///
/// Safety invariant (mechanical): `lockedON_BSC + reserveON_ETH >= totalSupply(wON)`.
///
/// @dev `IBurnMintERC20` is NOT inherited — it brings the CCIP-vendored `IERC20`, which
/// conflicts with OZ `IERC20` linearization. Selectors match the interface exactly so
/// pool calls succeed; `type(IBurnMintERC20).interfaceId` is still reported by
/// `supportsInterface`.
contract WrappedON is ERC20, AccessControl, ReentrancyGuard, IGetCCIPAdmin {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Cap on `ccipEstimatedUsedHeadroom`. Matches canonical BSC ON supply — the upper bound
    ///         on ON that can ever be locked on the BSC pool.
    uint256 public constant MAX_CCIP_MINTED = 100_000_000 ether;

    /// @notice Canonical ON on this chain (non-mintable ERC20).
    IERC20 public immutable ON;

    /// @notice ESTIMATE of CCIP cap headroom currently consumed (remaining headroom is
    ///         `MAX_CCIP_MINTED - ccipEstimatedUsedHeadroom`). Incremented by CCIP `mint`,
    ///         saturating-decremented by CCIP burns, so it approximates — but does NOT
    ///         authoritatively track — the BSC pool's locked-ON balance. Cap bounds damage
    ///         from a buggy pool minting without a matching BSC lock. NOT a source of truth
    ///         for BSC liquidity (SECURITY: Report M1 / WON-3) and not a per-token-provenance
    ///         counter — see the contract NatSpec NAMING and CAP REPLENISHMENT notes.
    uint256 public ccipEstimatedUsedHeadroom;

    /// @notice CCIP admin read by `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin`.
    /// @dev Independent of `DEFAULT_ADMIN_ROLE`. Two-step rotation (propose + accept) so a
    /// typo can't lock the role.
    address private s_ccipAdmin;
    address private s_pendingCcipAdmin;

    /// @notice Emitted by `deposit`. `received` is the POST-fee credited amount (matches the
    ///         wON minted), not the user-supplied `amount` argument — fee-on-transfer ON
    ///         variants would credit less than requested. Canonical ON is plain ERC20 so the
    ///         two coincide in practice; rename made explicit per WON-9.
    event Wrapped(address indexed account, uint256 received);
    /// @notice Emitted by `withdraw`. `amount` is the wON burned AND the ON returned (no
    ///         received-amount accounting on the unwrap path — the contract holds the
    ///         reserve and the outbound `safeTransfer` doesn't apply a fee on canonical
    ///         ON). For a hypothetical future fee-on-transfer ON variant, `amount` would be
    ///         what the contract sent; the recipient's credited balance may be lower. See
    ///         WON-18 — the asymmetry vs `Wrapped(received)` is recorded by design.
    event Unwrapped(address indexed account, uint256 amount);
    /// @notice Emitted by the CCIP `releaseOrMint` path. Lets indexers distinguish CCIP-inbound
    ///         mints from `deposit`-wrap mints (which emit `Wrapped`). Reports the post-call
    ///         `ccipEstimatedUsedHeadroom` so monitors don't need a second `eth_call`. SECURITY: WON-4.
    event CCIPMinted(address indexed account, uint256 amount, uint256 ccipEstimatedUsedHeadroom);
    /// @notice Emitted by every CCIP burn entrypoint. Sibling to `CCIPMinted` — gives indexers
    ///         a named event in addition to the inherited ERC20 `Transfer(account, 0, amount)`.
    ///         SECURITY: WON-4.
    event CCIPBurned(address indexed account, uint256 amount, uint256 ccipEstimatedUsedHeadroom);
    event CCIPAdminTransferProposed(address indexed currentAdmin, address indexed proposed);
    event CCIPAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    /// @notice Emitted when an in-flight `setCCIPAdmin` proposal is overwritten by a new
    ///         proposal to a different address. Gives the previously proposed party an
    ///         unambiguous signal that any queued `acceptCCIPAdmin` tx will revert.
    ///         SECURITY: WON-5.
    event CCIPAdminProposalCancelled(address indexed cancelled);

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
    ///      zero-address, self-reserve, and decimals-mismatch tokens.
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
    /// @dev WON-14: also rejects `received == 0` after the transfer. A 100%-fee or buggy
    ///      ERC20 whose `transferFrom` returned `true` without actually moving anything
    ///      would otherwise let a `deposit(N)` call mint 0 wON and emit `Wrapped(_, 0)`.
    ///      Canonical ON cannot hit this, but the received-amount guard is what mints the
    ///      defensive accounting; rejecting `received == 0` matches the WON-1 mint guard.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 before = ON.balanceOf(address(this));
        ON.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = ON.balanceOf(address(this)) - before;
        if (received == 0) {
            revert ZeroAmount();
        }
        _mint(msg.sender, received);
        emit Wrapped(msg.sender, received);
    }

    /// @notice Burns `amount` wON from `msg.sender` and returns `amount` ON from the reserve.
    /// @dev Does NOT decrement `ccipEstimatedUsedHeadroom` — `withdraw` only moves ETH-side reserve
    ///      and never triggers a BSC release, so decrementing would desync from BSC balance.
    ///      Cost: a CCIP-minted holder can drain the deposit reserve (intended arbitrage
    ///      layer).
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

    /// @notice CCIP `BurnMintTokenPool.releaseOrMint` entrypoint.
    /// @dev Capped at `MAX_CCIP_MINTED` via `ccipEstimatedUsedHeadroom`. See the contract-level
    ///      CAP REPLENISHMENT block (CCIP-7) for the cycling-refill semantics — the cap
    ///      is a live BSC-balance approximation, not a lifetime CCIP-mint ceiling.
    ///      WON-17: `nonReentrant` is defensive — OZ 5.x ERC20 has no hooks, so re-entry
    ///      via `_mint` cannot happen today. The guard locks the cap-counter / mint
    ///      ordering against a future subclass that overrides `_update`.
    function mint(address account, uint256 amount) external onlyRole(MINTER_ROLE) nonReentrant {
        // Zero-amount mints emit a Transfer(pool, account, 0) log and otherwise no-op,
        // matching the asymmetry the `deposit`/`withdraw` guards exist to prevent.
        // SECURITY: WON-1.
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 wouldBe = ccipEstimatedUsedHeadroom + amount;
        if (wouldBe > MAX_CCIP_MINTED) {
            revert CCIPMintCapExceeded(MAX_CCIP_MINTED, wouldBe);
        }
        ccipEstimatedUsedHeadroom = wouldBe;
        _mint(account, amount);
        emit CCIPMinted(account, amount, wouldBe);
    }

    /// @notice Burns from `msg.sender`. Called by `BurnMintTokenPool._burn` after the pool
    ///         transfers user tokens to itself.
    /// @dev WON-11: `ZeroAmount` guard mirrors the `mint`/`deposit`/`withdraw` pattern so a
    ///      misbehaving pool can't spam `CCIPBurned(_, 0, supply)` events. WON-17:
    ///      `nonReentrant` mirrors `mint` — defensive against future hookable subclasses.
    function burn(uint256 amount) external onlyRole(BURNER_ROLE) nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 newUsedHeadroom = _decrementUsedHeadroom(amount);
        _burn(msg.sender, amount);
        emit CCIPBurned(msg.sender, amount, newUsedHeadroom);
    }

    /// @notice Burns from `account` without allowance check (matches `IBurnMintERC20`).
    /// @dev `BURNER_ROLE` must be held exclusively by the audited pool. Same WON-11 +
    ///      WON-17 rationale as the single-arg overload. CCIP-12: `account` is the burning
    ///      pool's caller-supplied target, NOT the pool itself; for the single-arg
    ///      `burn(uint256)` overload, `account` in the event is `msg.sender` (the pool).
    function burn(address account, uint256 amount) external onlyRole(BURNER_ROLE) nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }
        uint256 newUsedHeadroom = _decrementUsedHeadroom(amount);
        _burn(account, amount);
        emit CCIPBurned(account, amount, newUsedHeadroom);
    }

    /// @notice Allowance-respecting burn. For pool variants that go through `approve`.
    function burnFrom(address account, uint256 amount) external onlyRole(BURNER_ROLE) nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }
        _spendAllowance(account, msg.sender, amount);
        uint256 newUsedHeadroom = _decrementUsedHeadroom(amount);
        _burn(account, amount);
        emit CCIPBurned(account, amount, newUsedHeadroom);
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
        // Emit a named cancellation event when overwriting an in-flight proposal to a
        // DIFFERENT address. Re-proposing the same pending admin is a no-op for the
        // pending slot, so suppressing the event there avoids spurious cancellation
        // signals during honest retry flows. SECURITY: WON-5.
        //
        // WON-12: write the new pending slot BEFORE emitting either event. The contract
        // makes no external calls here, so there's no reentrancy risk either way, but
        // emitting after the state write matches the `mint`/`burn`/`acceptCCIPAdmin` order
        // and prevents an indexer that subscribes to `CCIPAdminProposalCancelled` and
        // immediately reads `pendingCCIPAdmin()` from seeing the stale value.
        address prev = s_pendingCcipAdmin;
        s_pendingCcipAdmin = newAdmin;
        if (prev != address(0) && prev != newAdmin) {
            emit CCIPAdminProposalCancelled(prev);
        }
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
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC20Metadata).interfaceId
            || interfaceId == type(IBurnMintERC20).interfaceId || interfaceId == type(IGetCCIPAdmin).interfaceId
            || interfaceId == type(IAccessControl).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /// @dev Saturating subtract. Under honest CCIP each burn pairs a BSC `release`, so the
    ///      counter tracks `lockedON_BSC` down in lockstep. Saturation is a defensive floor —
    ///      only matters if a buggy/compromised pool over-burns. Not a per-token-provenance
    ///      counter (wON is fungible).
    /// @dev WON-13: returns the new used-headroom value so each burn entrypoint can emit
    ///      `CCIPBurned` with the local variable instead of re-reading storage (saves one
    ///      SLOAD per burn and matches the `mint` path's local-variable pattern).
    function _decrementUsedHeadroom(uint256 amount) internal returns (uint256 newUsedHeadroom) {
        uint256 current = ccipEstimatedUsedHeadroom;
        newUsedHeadroom = amount >= current ? 0 : current - amount;
        ccipEstimatedUsedHeadroom = newUsedHeadroom;
    }
}
