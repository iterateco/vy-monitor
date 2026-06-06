// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {ValinityToken} from "../token/ValinityToken.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title ValinityYieldTreasury (VYT)
 * @notice Treasury that holds VY tokens and funds ecosystem operations.
 * @dev UUPS upgradeable. Auto-refills to TARGET_BALANCE via ValinityToken.mintAvailable().
 *      Priority officers (VAO, VMB) can pull from full balance.
 *      Standard officers (VYO) cannot pull below CUSHION.
 *      Rate limiting is hardcoded in ValinityToken — VYT just requests and takes what it gets.
 */
contract ValinityYieldTreasury is UUPSUpgradeable, AccessControl, ReentrancyGuardTransient, Initializable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER_ROLE");
    bytes32 public constant PRIORITY_OFFICER_ROLE = keccak256("PRIORITY_OFFICER_ROLE");

    /// @notice Immutable cushion reserved for priority officers (0.5% of max supply)
    uint256 public constant CUSHION = 350_000 * 10 ** 18;

    /// @notice Target balance — VYT auto-refills to this level
    uint256 public constant TARGET_BALANCE = 7_000_000 * 10 ** 18;

    /// @notice ValinityToken contract reference
    ValinityToken public vyToken;

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPRECATED STATE — Slots preserved for UUPS storage layout compatibility
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:deprecated Rate limiting moved to ValinityToken. Slot preserved.
    uint16 private __deprecated_maxMintBps;
    /// @custom:deprecated Slot preserved.
    uint16 private __deprecated_maxMintPerEpochBps;
    /// @custom:deprecated Slot preserved.
    uint32 private __deprecated_epochDuration;
    /// @custom:deprecated Slot preserved.
    bool private __deprecated_rateLimitingEnabled;

    /// @custom:deprecated Slot preserved.
    uint64 private __deprecated_currentEpochStart;
    /// @custom:deprecated Slot preserved.
    uint192 private __deprecated_mintedThisEpoch;

    /// @custom:deprecated Slot preserved.
    uint256 private __deprecated_epochSupplySnapshot;

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidAddress();
    error InvalidAmount();
    error CushionViolation();

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event TokensPulled(address indexed officer, address indexed recipient, uint256 amount, uint256 minted);
    event TreasuryMigrated(address indexed oldTreasury, address indexed newTreasury, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address vyTokenAddress, address adminAddress) public initializer {
        if (vyTokenAddress == address(0)) revert InvalidAddress();
        if (adminAddress == address(0)) revert InvalidAddress();
        vyToken = ValinityToken(vyTokenAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
        _setRoleAdmin(OFFICER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PRIORITY_OFFICER_ROLE, ADMIN_ROLE);
    }

    /**
     * @notice Pull VY tokens with automatic refill from ValinityToken
     * @dev Both OFFICER_ROLE and PRIORITY_OFFICER_ROLE can call.
     *      Auto-refills to TARGET_BALANCE via vyToken.mintAvailable() (non-reverting).
     *      Standard officers (OFFICER_ROLE) cannot pull below CUSHION.
     *      Priority officers (PRIORITY_OFFICER_ROLE) can pull from full balance.
     * @param recipient Address to receive the VY tokens
     * @param amount Total amount of VY needed
     * @return minted Amount of VY that was minted during auto-refill
     */
    function pullTokens(
        address recipient,
        uint256 amount
    ) external nonReentrant returns (uint256 minted) {
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        bool isPriority = hasRole(PRIORITY_OFFICER_ROLE, msg.sender);
        if (!isPriority && !hasRole(OFFICER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, OFFICER_ROLE);
        }

        // Auto-refill: if below target, try to mint the deficit (non-reverting)
        uint256 currentBalance = vyToken.balanceOf(address(this));
        if (currentBalance < TARGET_BALANCE) {
            uint256 deficit;
            unchecked { deficit = TARGET_BALANCE - currentBalance; }
            minted = vyToken.mintAvailable(address(this), deficit);
            currentBalance += minted;
        }

        // Cushion enforcement for standard officers
        if (!isPriority && currentBalance > CUSHION) {
            uint256 available;
            unchecked { available = currentBalance - CUSHION; }
            if (amount > available) revert CushionViolation();
        } else if (!isPriority && currentBalance <= CUSHION) {
            revert CushionViolation();
        }

        vyToken.transfer(recipient, amount);
        emit TokensPulled(msg.sender, recipient, amount, minted);
    }

    /**
     * @notice Get current VY balance of the treasury
     * @return Current VY balance
     */
    function getBalance() external view returns (uint256) {
        return vyToken.balanceOf(address(this));
    }

    /**
     * @notice Get VY available for yield distribution (balance minus cushion)
     * @return Available VY that the Yield Officer can consider for rate calculation
     */
    function getAvailableForYield() external view returns (uint256) {
        uint256 balance = vyToken.balanceOf(address(this));
        if (balance <= CUSHION) return 0;
        unchecked { return balance - CUSHION; }
    }

    /**
     * @notice Migrate all funds to a new treasury contract
     * @dev Only callable by admin. Transfers entire balance to new treasury.
     * @param newTreasury Address of the new treasury contract
     */
    function migrateTo(address newTreasury) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (newTreasury == address(0)) revert InvalidAddress();
        uint256 balance = vyToken.balanceOf(address(this));
        vyToken.transfer(newTreasury, balance);
        emit TreasuryMigrated(address(this), newTreasury, balance);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UUPS UPGRADE
    // ═══════════════════════════════════════════════════════════════════════════

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    uint256[46] private __gap;
}
