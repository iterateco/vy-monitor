// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IVDAX
 * @notice Interface for the VDAX token (Valinity DAX Liquidity Pool Token)
 * @dev Extends ERC20 with minting/burning restricted to ValinityDAX contract
 */
interface IVDAX is IERC20 {
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidAddress();
    error InvalidMintAmount();
    error InvalidBurnAmount();
    error InsufficientBalance();

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when VDAX tokens are minted
     * @param to Recipient of the minted tokens
     * @param amount Amount of tokens minted
     * @param totalSupply New total supply after minting
     */
    event VDAXMinted(
        address indexed to,
        uint256 indexed amount,
        uint256 indexed totalSupply
    );

    /**
     * @notice Emitted when VDAX tokens are burned
     * @param from Account whose tokens are burned
     * @param amount Amount of tokens burned
     * @param totalSupply New total supply after burning
     */
    event VDAXBurned(address indexed from, uint256 amount, uint256 totalSupply);

    /**
     * @notice Emitted when the ValinityDAX contract address is set
     * @param daxContract Address of the ValinityDAX contract
     */
    event DAXContractSet(address indexed daxContract);

    // ═══════════════════════════════════════════════════════════════════════════
    // FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Mint VDAX tokens to a recipient
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burn VDAX tokens from an account
     * @param from Address whose tokens will be burned
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external;

    /**
     * @notice Check if an address has the minter role
     * @param account Address to check
     * @return bool True if the account has MINTER_ROLE
     */
    function isMinter(address account) external view returns (bool);

    /**
     * @notice Check if an address has the admin role
     * @param account Address to check
     * @return bool True if the account has ADMIN_ROLE
     */
    function isAdmin(address account) external view returns (bool);

    /**
     * @notice Get the admin role constant
     * @return bytes32 Admin role identifier
     */
    function ADMIN_ROLE() external view returns (bytes32);

    /**
     * @notice Get the minter role constant
     * @return bytes32 Minter role identifier
     */
    function MINTER_ROLE() external view returns (bytes32);
}
