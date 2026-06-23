// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {IGetCCIPAdmin} from "@chainlink/contracts-ccip/interfaces/IGetCCIPAdmin.sol";

/// @title Wrapped Orochi Network Token (wON)
/// @notice CCIP `BurnMintTokenPool` token on Ethereum + 1:1 wrapper for canonical ON.
///
/// UUPS-upgradeable (ERC-1967 proxy). The implementation's constructor only
/// `_disableInitializers()`; all wiring happens in `initialize`. Upgrades are gated by
/// `UPGRADER_ROLE` (held by a `TimelockController` so changes carry a mandatory delay) and
/// the value paths carry an emergency `PAUSER_ROLE` pause. State lives in ERC-7201 namespaced
/// storage so future implementations can extend it without collision.
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
/// CCIP CONSERVATION (Chainlink-enforced, exact): every CCIP `mint` here is paired 1:1 with
/// a `lock` on the BSC `LockReleaseTokenPool`, and every CCIP burn here with a BSC
/// `release`. So the ON moved into the BSC pool BY CCIP always equals the wON minted on
/// Ethereum BY CCIP, message-for-message. That equality is upheld by the CCIP transport
/// layer (the DON + RMN), NOT by this contract: Ethereum has NO way to read the BSC pool's
/// balance, so the bridge TRUSTS Chainlink to deliver each message once and honour the
/// pairing. `mint` executes whenever the trusted CCIP off-ramp calls `releaseOrMint`; it
/// cannot independently verify that the matching BSC `lock` occurred. See SECURITY: CCIP-7
/// and the §3 trust model.
///
/// `MAX_CCIP_MINTED = 100M` caps `ccipMintHeadroomUsed` — a LOCAL ETH-side counter of how
/// much CCIP mint-cap headroom is consumed (M1 / #23 renamed it from the misleading
/// `ccipMintedSupply`). It exists only because the real CCIP-locked figure lives on BSC and
/// is unreadable from here, and it is NOT a gauge of BSC-locked liquidity: the
/// saturating-decrement (below) and operator-seeded BSC liquidity make it drift from the true
/// BSC balance. The cap bounds damage from a compromised pool; it does NOT bound
/// `totalSupply()` (the `deposit` path is uncapped). Not a per-token-provenance counter — wON
/// is fungible. Saturating-subtract on burn handles deposit-backed wON being bridged out;
/// pool lock/release accounting nets out regardless.
///
/// CAP REPLENISHMENT (SECURITY: M1 #23 / CCIP-7 / WON-3): the cap is NOT a lifetime
/// CCIP-mint bound. Deposit-backed wON cycled OUT through the bridge burns and
/// saturating-decrements `ccipMintHeadroomUsed` toward 0 even though the underlying mint was
/// never CCIP-sourced — refilling cap headroom for subsequent CCIP inbound mints. Because of
/// that saturation the counter can read BELOW the true BSC-locked balance, so it must NOT be
/// treated as a BSC-liquidity proxy. The safety invariant
/// (`lockedON_BSC + reserveON_ETH >= totalSupply(wON)`) holds regardless, because every CCIP
/// mint still pairs a BSC lock at the cap-checked moment and burns reverse both sides in
/// lockstep. For real cross-chain exposure read `IERC20(ON).balanceOf(BSC_pool)` as ground
/// truth — NOT this counter.
///
/// Safety invariant (mechanical): `lockedON_BSC + reserveON_ETH >= totalSupply(wON)`.
///
/// @dev `IBurnMintERC20` is NOT inherited — it brings the CCIP-vendored `IERC20`, which
/// conflicts with OZ `IERC20` linearization. Selectors match the interface exactly so
/// pool calls succeed; `type(IBurnMintERC20).interfaceId` is still reported by
/// `supportsInterface`.
///
/// @dev `ReentrancyGuardTransient` is the NON-upgradeable variant on purpose: its guard uses
/// a constant transient (EIP-1153) storage slot, so it holds no persistent state and needs no
/// initializer. OZ v5.6.1 ships no `ReentrancyGuardTransientUpgradeable`; this is OZ's own
/// documented pattern for upgradeable contracts.
contract WrappedON is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    IGetCCIPAdmin
{
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    /// @notice Gates `_authorizeUpgrade`. Held by a `TimelockController` so upgrades carry a
    ///         mandatory (48h) delay; never granted to an EOA in production.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @notice Gates the emergency `pause`/`unpause`. Halts the value paths
    ///         (mint/burn/deposit/withdraw); plain ERC20 transfers stay live.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Cap on `ccipMintHeadroomUsed`. Matches canonical BSC ON supply — the upper bound
    ///         on ON that can ever be locked on the BSC pool.
    uint256 public constant MAX_CCIP_MINTED = 100_000_000 ether;

    /// @custom:storage-location erc7201:orochi.storage.WrappedON
    struct WrappedONStorage {
        /// @dev Canonical ON on this chain (non-mintable ERC20); set once at `initialize`.
        IERC20 on;
        /// @dev CCIP mint-cap headroom currently consumed, bounded by `MAX_CCIP_MINTED`.
        uint256 ccipMintHeadroomUsed;
        /// @dev CCIP admin read by `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin`.
        address ccipAdmin;
        /// @dev Proposed-but-not-accepted CCIP admin (two-step rotation).
        address pendingCcipAdmin;
    }

    // = keccak256(abi.encode(uint256(keccak256("orochi.storage.WrappedON")) - 1)) & ~bytes32(uint256(0xff))
    // Verified with `cast index-erc7201 orochi.storage.WrappedON` and an independent
    // keccak/abi-encode recomputation.
    bytes32 private constant _STORAGE_LOCATION = 0xc9356e8aa19da270b9a132fda93e9af24668c8487450db15f9b9e8baeb751900;

    function _s() private pure returns (WrappedONStorage storage $) {
        assembly {
            $.slot := _STORAGE_LOCATION
        }
    }

    /// @notice Canonical ON on this chain (set once at initialize).
    function ON() public view returns (IERC20) {
        return _s().on;
    }

    /// @notice CCIP mint-cap headroom consumed, bounded by MAX_CCIP_MINTED.
    function ccipMintHeadroomUsed() external view returns (uint256) {
        return _s().ccipMintHeadroomUsed;
    }

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
    ///         `ccipMintHeadroomUsed` so monitors don't need a second `eth_call`. SECURITY: WON-4.
    event CCIPMinted(address indexed account, uint256 amount, uint256 ccipMintHeadroomUsed);
    /// @notice Emitted by every CCIP burn entrypoint. Sibling to `CCIPMinted` — gives indexers
    ///         a named event in addition to the inherited ERC20 `Transfer(account, 0, amount)`.
    ///         SECURITY: WON-4.
    event CCIPBurned(address indexed account, uint256 amount, uint256 ccipMintHeadroomUsed);
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-time init. `admin` gets `DEFAULT_ADMIN_ROLE` + `PAUSER_ROLE` and becomes the
    ///         initial CCIP admin; `timelock` gets `UPGRADER_ROLE` (gates `_authorizeUpgrade`).
    /// @dev Rejects zero-address (any of the three args), self-reserve, and decimals-mismatch
    ///      tokens — same guards the old constructor enforced. The CCIP admin and the
    ///      `DEFAULT_ADMIN_ROLE` both hand off to the multisig (two-step each) before the
    ///      deployer renounces.
    function initialize(IERC20 onToken, address admin, address timelock) external initializer {
        if (address(onToken) == address(0) || admin == address(0) || timelock == address(0)) {
            revert ZeroAddress();
        }
        // Self-reserve would make the wrap invariant circular (own ERC20 balance double-counts).
        if (address(onToken) == address(this)) {
            revert SelfReserve();
        }
        __ERC20_init("Wrapped Orochi Network", "wON");
        __AccessControl_init();
        __Pausable_init();
        // ReentrancyGuardTransient (non-upgradeable) has no initializer — its guard lives in a
        // constant transient slot. UUPSUpgradeable likewise has no initializer in OZ v5.6.1.

        // 1:1 wrap accounting requires matching decimals. Canonical ON is a standard
        // ERC20Metadata on both chains; rejects mis-wired testnet tokens.
        uint8 onDecimals = IERC20Metadata(address(onToken)).decimals();
        if (onDecimals != decimals()) {
            revert DecimalsMismatch(decimals(), onDecimals);
        }
        WrappedONStorage storage $ = _s();
        $.on = onToken;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, timelock);
        $.ccipAdmin = admin;
        emit CCIPAdminTransferred(address(0), admin);
    }

    /// @dev UUPS upgrade authorization — gated by `UPGRADER_ROLE` (the timelock). The
    ///      mandatory delay lives in the `TimelockController`, not here.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /// @notice Emergency stop on the value paths (mint/burn/deposit/withdraw). Transfers stay live.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ─── Wrap / Unwrap (1:1 against native ON) ────────────────────────────────

    /// @notice Pulls `amount` ON and mints wON to `msg.sender` (1:1). Permissionless.
    /// @dev Received-amount accounting keeps the wrap exact under fee-on-transfer variants
    ///      (defensive; canonical ON is plain ERC20). `nonReentrant` guards against future
    ///      hook-bearing tokens. Uncapped — bounded by ETH-side ON supply; independent of
    ///      `MAX_CCIP_MINTED` so heavy wrap usage can't starve inbound CCIP.
    /// @dev WON-14: also rejects `received == 0` after the transfer (see existing rationale).
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        IERC20 on = _s().on;
        uint256 before = on.balanceOf(address(this));
        on.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = on.balanceOf(address(this)) - before;
        // `received` is a balance delta; `== 0` is the intended zero-received guard (WON-14),
        // not an exact-balance comparison. Safe strict equality — Slither false positive.
        // slither-disable-next-line incorrect-equality
        if (received == 0) {
            revert ZeroAmount();
        }
        _mint(msg.sender, received);
        emit Wrapped(msg.sender, received);
    }

    /// @notice Burns `amount` wON from `msg.sender` and returns `amount` ON from the reserve.
    /// @dev Does NOT decrement `ccipMintHeadroomUsed` — `withdraw` only moves ETH-side reserve
    ///      and never triggers a BSC release, so decrementing would desync from BSC balance.
    ///      Cost: a CCIP-minted holder can drain the deposit reserve (intended arbitrage
    ///      layer).
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        IERC20 on = _s().on;
        uint256 reserve = on.balanceOf(address(this));
        if (reserve < amount) {
            revert InsufficientReserve(amount, reserve);
        }
        _burn(msg.sender, amount);
        on.safeTransfer(msg.sender, amount);
        emit Unwrapped(msg.sender, amount);
    }

    // ─── IBurnMintERC20 (pool-only) ───────────────────────────────────────────

    /// @notice CCIP `BurnMintTokenPool.releaseOrMint` entrypoint.
    /// @dev Always mints wON to `account` (EOA or contract); never reads the reserve or
    ///      delivers native ON, so the delivered asset is deterministic, not front-runnable
    ///      via the permissionless reserve (issue #48). Native ON is obtained via `withdraw`.
    ///      Capped at `MAX_CCIP_MINTED` via `ccipMintHeadroomUsed` (CAP REPLENISHMENT / CCIP-7
    ///      — a live BSC-balance approximation, not a lifetime ceiling). WON-17: `nonReentrant`
    ///      is defensive (OZ 5.x ERC20 has no hooks) — it pins the cap-counter / mint ordering
    ///      against a future `_update`-overriding subclass.
    function mint(address account, uint256 amount) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused {
        // Zero-amount mints emit a Transfer(pool, account, 0) log and otherwise no-op,
        // matching the asymmetry the `deposit`/`withdraw` guards exist to prevent.
        // SECURITY: WON-1.
        if (amount == 0) {
            revert ZeroAmount();
        }
        WrappedONStorage storage $ = _s();
        uint256 wouldBe = $.ccipMintHeadroomUsed + amount;
        if (wouldBe > MAX_CCIP_MINTED) {
            revert CCIPMintCapExceeded(MAX_CCIP_MINTED, wouldBe);
        }
        $.ccipMintHeadroomUsed = wouldBe;
        _mint(account, amount);
        emit CCIPMinted(account, amount, wouldBe);
    }

    /// @notice Burns from `msg.sender`. Called by `BurnMintTokenPool._burn` after the pool
    ///         transfers user tokens to itself.
    /// @dev WON-11: `ZeroAmount` guard mirrors the `mint`/`deposit`/`withdraw` pattern so a
    ///      misbehaving pool can't spam `CCIPBurned(_, 0, supply)` events. WON-17:
    ///      `nonReentrant` mirrors `mint` — defensive against future hookable subclasses.
    function burn(uint256 amount) external onlyRole(BURNER_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        _ccipBurn(msg.sender, amount);
    }

    /// @notice Burns from `account` without allowance check (matches `IBurnMintERC20`).
    /// @dev `BURNER_ROLE` must be held exclusively by the audited pool. Same WON-11 +
    ///      WON-17 rationale as the single-arg overload. CCIP-12: `account` is the burning
    ///      pool's caller-supplied target, NOT the pool itself; for the single-arg
    ///      `burn(uint256)` overload, `account` in the event is `msg.sender` (the pool).
    function burn(address account, uint256 amount) external onlyRole(BURNER_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        _ccipBurn(account, amount);
    }

    /// @notice Allowance-respecting burn. For pool variants that go through `approve`.
    function burnFrom(address account, uint256 amount) external onlyRole(BURNER_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) {
            revert ZeroAmount();
        }
        _spendAllowance(account, msg.sender, amount);
        _ccipBurn(account, amount);
    }

    // ─── IGetCCIPAdmin (two-step) ─────────────────────────────────────────────

    /// @notice Current CCIP admin. Read by `RegistryModuleOwnerCustom`.
    function getCCIPAdmin() external view returns (address) {
        return _s().ccipAdmin;
    }

    /// @notice Proposed-but-not-accepted CCIP admin (zero if none). Handoff scripts assert
    ///         this equals the multisig before the deployer renounces.
    function pendingCCIPAdmin() external view returns (address) {
        return _s().pendingCcipAdmin;
    }

    /// @notice Proposes a new CCIP admin; proposed address must call `acceptCCIPAdmin`.
    /// @dev Rejects self-proposal (would silently cancel any in-flight pending) and
    ///      `address(this)` (would write an unreachable pending, soft-locking the role).
    ///      Both via `InvalidCCIPAdmin` — R-56.
    function setCCIPAdmin(address newAdmin) external {
        WrappedONStorage storage $ = _s();
        if (msg.sender != $.ccipAdmin) {
            revert OnlyCCIPAdmin();
        }
        if (newAdmin == address(0)) {
            revert ZeroAddress();
        }
        if (newAdmin == $.ccipAdmin || newAdmin == address(this)) {
            revert InvalidCCIPAdmin();
        }
        // Emit a named cancellation event when overwriting an in-flight proposal to a
        // DIFFERENT address. Re-proposing the same pending admin is a no-op for the
        // pending slot, so suppressing the event there avoids spurious cancellation
        // signals during honest retry flows. SECURITY: WON-5.
        //
        // WON-12: write the new pending slot BEFORE emitting either event. The contract
        // makes no external calls here, so there's no reentrancy risk either way, but
        // emitting after the state write matches the `mint`/`burn` order and prevents an
        // indexer that subscribes to `CCIPAdminProposalCancelled` and immediately reads
        // `pendingCCIPAdmin()` from seeing the stale value. (`acceptCCIPAdmin` below is the
        // deliberate exception — it MUST emit before the write so `CCIPAdminTransferred`
        // captures the OLD `ccipAdmin` in its `previousAdmin` field.)
        address prev = $.pendingCcipAdmin;
        $.pendingCcipAdmin = newAdmin;
        if (prev != address(0) && prev != newAdmin) {
            emit CCIPAdminProposalCancelled(prev);
        }
        emit CCIPAdminTransferProposed($.ccipAdmin, newAdmin);
    }

    /// @notice Completes the two-step CCIP admin transfer. Caller must equal the pending
    ///         address; pending slot is cleared on success.
    function acceptCCIPAdmin() external {
        WrappedONStorage storage $ = _s();
        if (msg.sender != $.pendingCcipAdmin) {
            revert OnlyPendingCCIPAdmin();
        }
        emit CCIPAdminTransferred($.ccipAdmin, msg.sender);
        $.ccipAdmin = msg.sender;
        $.pendingCcipAdmin = address(0);
    }

    // ─── IERC165 ──────────────────────────────────────────────────────────────

    /// @notice ERC-165 advertisement. Reports `IBurnMintERC20` despite no formal inheritance
    ///         (selectors are reproduced manually — see contract NatSpec).
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC20Metadata).interfaceId
            || interfaceId == type(IBurnMintERC20).interfaceId || interfaceId == type(IGetCCIPAdmin).interfaceId
            || interfaceId == type(IAccessControl).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /// @dev Saturating subtract. Under honest CCIP each burn pairs a BSC `release`, so the
    ///      counter tracks `lockedON_BSC` down in lockstep. Saturation is a defensive floor —
    ///      only matters if a buggy/compromised pool over-burns. Not a per-token-provenance
    ///      counter (wON is fungible).
    /// @dev WON-13: returns the new supply so each burn entrypoint can emit `CCIPBurned`
    ///      with the local variable instead of re-reading storage (saves one SLOAD per burn
    ///      and matches the `mint` path's local-variable pattern).
    function _decrementCcipMintHeadroom(uint256 amount) internal returns (uint256 newSupply) {
        WrappedONStorage storage $ = _s();
        uint256 current = $.ccipMintHeadroomUsed;
        newSupply = amount >= current ? 0 : current - amount;
        $.ccipMintHeadroomUsed = newSupply;
    }

    /// @dev Shared tail for all three CCIP burn entrypoints: saturating-decrement, OZ `_burn`,
    ///      then `CCIPBurned`. Callers apply the `ZeroAmount` guard (WON-11) and, for
    ///      `burnFrom`, `_spendAllowance` BEFORE calling here. WON-13: emits the local
    ///      `newSupply` (one fewer SLOAD than re-reading storage; mirrors `mint`'s `wouldBe`).
    function _ccipBurn(address account, uint256 amount) private {
        uint256 newSupply = _decrementCcipMintHeadroom(amount);
        _burn(account, amount);
        emit CCIPBurned(account, amount, newSupply);
    }
}
