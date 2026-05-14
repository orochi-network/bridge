// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

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
/// @dev `IBurnMintERC20` is NOT inherited because it transitively brings the CCIP-vendored
/// `IERC20` interface, which conflicts with OpenZeppelin's `IERC20` linearization. The
/// function selectors (`mint`, `burn`, `burn(address,uint256)`, `burnFrom`) match the
/// interface exactly, so the BurnMintTokenPool calls succeed at runtime regardless.
/// `type(IBurnMintERC20).interfaceId` is still reported by `supportsInterface`.
contract WrappedON is ERC20, AccessControl, IGetCCIPAdmin {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Canonical Orochi Network token on this chain (non-mintable ERC20).
    IERC20 public immutable ON;

    /// @notice CCIP admin used by `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin`.
    /// @dev Independent from `DEFAULT_ADMIN_ROLE`; transferable by the current ccipAdmin.
    address private s_ccipAdmin;

    event Wrapped(address indexed account, uint256 amount);
    event Unwrapped(address indexed account, uint256 amount);
    event CCIPAdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error InsufficientReserve(uint256 requested, uint256 available);
    error OnlyCCIPAdmin();
    error ZeroAddress();

    constructor(IERC20 onToken, address admin) ERC20("Wrapped Orochi Network", "wON") {
        if (address(onToken) == address(0) || admin == address(0)) revert ZeroAddress();
        ON = onToken;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        s_ccipAdmin = admin;
        emit CCIPAdminTransferred(address(0), admin);
    }

    // ─── Wrap / Unwrap (1:1 against native ON) ────────────────────────────────

    function deposit(uint256 amount) external {
        ON.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        emit Wrapped(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        uint256 reserve = ON.balanceOf(address(this));
        if (reserve < amount) revert InsufficientReserve(amount, reserve);
        _burn(msg.sender, amount);
        ON.safeTransfer(msg.sender, amount);
        emit Unwrapped(msg.sender, amount);
    }

    // ─── IBurnMintERC20 (pool-only) ───────────────────────────────────────────

    function mint(address account, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(account, amount);
    }

    /// @notice Burns `amount` from `msg.sender`. Used by `BurnMintTokenPool._burn`,
    ///         which transfers user tokens to itself first and then calls `burn(amount)`.
    function burn(uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(msg.sender, amount);
    }

    function burn(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(account, amount);
    }

    function burnFrom(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    // ─── IGetCCIPAdmin ────────────────────────────────────────────────────────

    function getCCIPAdmin() external view returns (address) {
        return s_ccipAdmin;
    }

    function setCCIPAdmin(address newAdmin) external {
        if (msg.sender != s_ccipAdmin) revert OnlyCCIPAdmin();
        if (newAdmin == address(0)) revert ZeroAddress();
        emit CCIPAdminTransferred(s_ccipAdmin, newAdmin);
        s_ccipAdmin = newAdmin;
    }

    // ─── IERC165 ──────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId) public pure override(AccessControl) returns (bool) {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IBurnMintERC20).interfaceId
            || interfaceId == type(IGetCCIPAdmin).interfaceId || interfaceId == type(IAccessControl).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
