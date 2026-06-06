// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IVDAX} from "./interfaces/IVDAX.sol";

/**
 * @title VDAX - Valinity DAX Liquidity Pool Token
 * @notice ERC-20 token representing proportional ownership of all pools in the Valinity DAX
 * @dev This token uses a basket model where each VDAX token represents an equal share
 *      of reserves across all VY/Asset pools managed by the ValinityDAX contract.
 *
 * Key Features:
 * - Single token representing ownership across multiple liquidity pools
 * - Proportional ownership: x% of VDAX supply = x% of each pool's reserves
 * - Mint/burn operations restricted to ValinityDAX contract only
 * - Standard ERC-20 functionality with 18 decimals
 *
 * Access Control:
 * - ADMIN_ROLE: Can grant/revoke MINTER_ROLE, upgrade parameters
 * - MINTER_ROLE: Can mint and burn tokens (assigned to ValinityDAX contract)
 *
 * Security:
 * - Only ValinityDAX contract can mint/burn
 * - Admin cannot mint/burn directly
 * - All minting tied to actual liquidity deposits in ValinityDAX
 */
contract VDAX is IVDAX, ERC20Upgradeable, UUPSUpgradeable, AccessControl {
    // ═══════════════════════════════════════════════════════════════════════════
    // ROLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Role for administrative functions (grant/revoke roles)
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role for minting and burning tokens (ValinityDAX contract)
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initializes the VDAX token with admin access control
     * @dev Sets up the token with:
     *      - Name: "Valinity DAX"
     *      - Symbol: "VDAX"
     *      - Decimals: 18 (standard)
     *      - Admin role for the deployer
     * @param adminAddress Address that will have ADMIN_ROLE (can grant MINTER_ROLE)
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address adminAddress) public initializer {
        if (adminAddress == address(0)) {
            revert InvalidAddress();
        }

        __ERC20_init("Valinity DAX", "VDAX");

        // Grant admin roles
        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);

        // Set ADMIN_ROLE as the role admin for MINTER_ROLE
        // This means only ADMIN_ROLE can grant/revoke MINTER_ROLE
        _setRoleAdmin(MINTER_ROLE, ADMIN_ROLE);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - MINTING & BURNING (RESTRICTED)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IVDAX
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) {
            revert InvalidAddress();
        }
        if (amount == 0) {
            revert InvalidMintAmount();
        }

        _mint(to, amount);
        emit VDAXMinted(to, amount, totalSupply());
    }

    /**
     * @inheritdoc IVDAX
     */
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (from == address(0)) {
            revert InvalidAddress();
        }
        if (amount == 0) {
            revert InvalidBurnAmount();
        }
        if (balanceOf(from) < amount) {
            revert InsufficientBalance();
        }

        _burn(from, amount);
        emit VDAXBurned(from, amount, totalSupply());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IVDAX
     */
    function isMinter(address account) external view returns (bool) {
        return hasRole(MINTER_ROLE, account);
    }

    /**
     * @inheritdoc IVDAX
     */
    function isAdmin(address account) external view returns (bool) {
        return hasRole(ADMIN_ROLE, account);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev See {IERC165-supportsInterface}.
     * @notice Returns true if this contract implements the interface defined by interfaceId
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _msgSender() internal view override(ContextUpgradeable, Context) returns (address) {
        return super._msgSender();
    }

    function _msgData() internal view override(ContextUpgradeable, Context) returns (bytes calldata) {
        return super._msgData();
    }

    function _contextSuffixLength() internal view override(ContextUpgradeable, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UUPS UPGRADE
    // ═══════════════════════════════════════════════════════════════════════════

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    uint256[48] private __gap;
}
