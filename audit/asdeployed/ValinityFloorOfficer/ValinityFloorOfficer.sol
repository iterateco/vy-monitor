// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ValinityToken} from "../token/ValinityToken.sol";
import {ValinityYieldTreasury} from "../treasury/ValinityYieldTreasury.sol";
import {ValinityReserveTreasury} from "../treasury/ValinityReserveTreasury.sol";
import {ValinityCapOfficer} from "../officer/ValinityCapOfficer.sol";

/// @notice Balancer V2 Vault flash loan interface
interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

/// @notice Callback interface for Balancer V2 flash loans
interface IFlashLoanRecipient {
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

/**
 * @title ValinityFloorOfficer
 * @notice Arbitrages VY price below its LTV-F floor via flash-loaned capital
 * @dev "Dumb" design — backend provides swap instructions, contract enforces invariants.
 *
 *      Atomic flow (single transaction via Balancer V2 flash loan):
 *      1) Operator calls initiateFloor() with flash loan amount + instructions
 *      2) Balancer sends USDC to this contract, triggers receiveFlashLoan()
 *      3) Buy VY with flash-loaned USDC via whitelisted routers
 *      4) Send ALL VY to VYT (the X for the three-way lock)
 *      5) Decrease caps on VCO — sum(capReductions) must == VY sent to VYT
 *      6) Withdraw assets from VRT at exact on-chain LTV per asset
 *         (contract computes: withdrawAmount = capReduction × reserve / cap)
 *      7) Swap withdrawn assets → USDC via whitelisted routers
 *      8) Repay Balancer flash loan (exact amount, 0% fee)
 *      9) Convert remaining USDC profit → VY via whitelisted routers
 *     10) Send ALL profit VY to profitRecipient (BuybackOfficer)
 *     11) Enforce clean state: all token balances == 0
 *
 *      Hardcoded invariants (community-verifiable):
 *      - Only operator can trigger, only Balancer Vault can call callback
 *      - VY sent to VYT BEFORE any withdrawals
 *      - sum(capReductions) == VY sent to VYT (three-way lock)
 *      - Withdrawals computed at exact on-chain LTV (contract calculates)
 *      - Cap floors enforced by VCO itself (reverts if cap < floor)
 *      - Swaps only through admin-whitelisted routers
 *      - Flash loan fully repaid (Balancer enforces atomically)
 *      - ALL profit VY → profitRecipient (cannot be diverted)
 *      - Clean state: all balances zero at end
 */
contract ValinityFloorOfficer is
    AccessControl,
    ReentrancyGuardTransient,
    IFlashLoanRecipient
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLES
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice VY Token reference
    ValinityToken public immutable vyToken;

    /// @notice VYT (Valinity Yield Treasury) — receives VY
    ValinityYieldTreasury public immutable vyt;

    /// @notice Reserve Treasury — assets withdrawn from
    ValinityReserveTreasury public immutable vrt;

    /// @notice Cap Officer — caps decreased on
    ValinityCapOfficer public immutable vco;

    /// @notice Balancer V2 Vault — flash loan source
    IBalancerVault public immutable balancerVault;

    /// @notice USDC token address
    address public immutable usdcAddress;

    /// @notice Backend operator wallet
    address public operator;

    /// @notice Profit recipient (BuybackOfficer)
    address public profitRecipient;

    /// @notice Emergency pause flag
    bool public execPaused;

    /// @notice Transient storage slot for flash loan callback guard
    /// @dev Uses tstore/tload (100 gas each) instead of SSTORE (~20,000 gas)
    /// keccak256("ValinityFloorOfficer._inFlashLoan")
    uint256 private constant _IN_FLASH_LOAN_SLOT =
        0xc1b14fbf86bbd1247a7d7f6c07774230e7f4c0d947f8fdfd821f54ba1f37fbcc;

    /// @notice Admin-approved router contracts for swaps
    mapping(address => bool) public whitelistedRouters;

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Which asset cap to reduce (contract computes withdrawal amount)
    struct WithdrawalInstruction {
        address asset;        // reserve asset in VRT
        uint256 capReduction; // VY amount to reduce cap by (18 dec)
    }

    /// @notice Swap instruction via a whitelisted router
    struct SwapStep {
        address router;   // must be in whitelistedRouters
        address tokenIn;  // token being spent
        address tokenOut; // token expected back (balance verified)
        bytes callData;   // encoded call (e.g., swap)
    }

    /// @notice Encoded parameters passed through flash loan userData
    struct FloorParams {
        WithdrawalInstruction[] withdrawals;
        SwapStep[] buySwaps;
        SwapStep[] sellSwaps;
        SwapStep[] profitSwaps;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event OperatorUpdated(address indexed newOperator);
    event ProfitRecipientUpdated(address indexed newRecipient);
    event Paused(bool execPaused);
    event RouterWhitelisted(address indexed router, bool approved);
    event AssetWithdrawn(
        address indexed asset,
        uint256 amount,
        uint256 capReduction
    );
    event FloorExecuted(
        address indexed operator,
        uint256 flashAmount,
        uint256 vyToVYT,
        uint256 profitVY,
        uint256 timestamp
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidAddress();
    error InvalidAmount();
    error ExecutionPaused();
    error UnauthorizedOperator();
    error UnauthorizedCaller();
    error DeadlineExpired();
    error CapReductionMismatch();
    error RouterNotWhitelisted();
    error SwapOutputZero();
    error TokenBalanceNotZero(address token);
    error FinalSwapMustOutputVY();
    error NoSwapSteps();
    error FlashLoanReentrancy();

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(
        address vyTokenAddress,
        address vytAddress,
        address vrtAddress,
        address vcoAddress,
        address balancerVaultAddress,
        address usdcAddr,
        address operatorAddress,
        address profitRecipientAddress,
        address adminAddress
    ) {
        if (vyTokenAddress == address(0)) revert InvalidAddress();
        if (vytAddress == address(0)) revert InvalidAddress();
        if (vrtAddress == address(0)) revert InvalidAddress();
        if (vcoAddress == address(0)) revert InvalidAddress();
        if (balancerVaultAddress == address(0)) revert InvalidAddress();
        if (usdcAddr == address(0)) revert InvalidAddress();
        if (operatorAddress == address(0)) revert InvalidAddress();
        if (profitRecipientAddress == address(0)) revert InvalidAddress();
        if (adminAddress == address(0)) revert InvalidAddress();

        vyToken = ValinityToken(vyTokenAddress);
        vyt = ValinityYieldTreasury(vytAddress);
        vrt = ValinityReserveTreasury(vrtAddress);
        vco = ValinityCapOfficer(vcoAddress);
        balancerVault = IBalancerVault(balancerVaultAddress);
        usdcAddress = usdcAddr;
        operator = operatorAddress;
        profitRecipient = profitRecipientAddress;

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    modifier onlyOperator() {
        if (msg.sender != operator) revert UnauthorizedOperator();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN ENTRY POINT (operator calls this)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initiate floor arbitrage via Balancer V2 flash loan
     * @dev Operator provides flash loan amount + all swap/withdrawal instructions.
     *      Balancer sends USDC, calls receiveFlashLoan(), pulls USDC back.
     *      Entire arb happens atomically inside the callback.
     *
     * @param flashAmount USDC to flash loan (6 decimals)
     * @param withdrawals Which assets to withdraw and their cap reductions
     * @param buySwaps Swap instructions: USDC → VY
     * @param sellSwaps Swap instructions: withdrawn assets → USDC
     * @param profitSwaps Swap instructions: remaining USDC → VY (profit)
     * @param deadline Prevents stale execution
     */
    function initiateFloor(
        uint256 flashAmount,
        WithdrawalInstruction[] calldata withdrawals,
        SwapStep[] calldata buySwaps,
        SwapStep[] calldata sellSwaps,
        SwapStep[] calldata profitSwaps,
        uint256 deadline
    ) external onlyOperator nonReentrant {
        // ─────────────────────────────────────────────────────────────────────
        // CHECKS
        // ─────────────────────────────────────────────────────────────────────
        if (execPaused) revert ExecutionPaused();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (flashAmount == 0) revert InvalidAmount();
        if (buySwaps.length == 0) revert NoSwapSteps();
        if (sellSwaps.length == 0) revert NoSwapSteps();

        // ─────────────────────────────────────────────────────────────────────
        // ENCODE PARAMS & REQUEST FLASH LOAN
        // ─────────────────────────────────────────────────────────────────────
        bytes memory userData = abi.encode(
            FloorParams({
                withdrawals: withdrawals,
                buySwaps: buySwaps,
                sellSwaps: sellSwaps,
                profitSwaps: profitSwaps
            })
        );

        address[] memory tokens = new address[](1);
        tokens[0] = usdcAddress;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashAmount;

        // Set flash loan guard (transient storage — 100 gas vs 20,000 SSTORE)
        assembly { tstore(_IN_FLASH_LOAN_SLOT, 1) }

        // Balancer sends USDC → calls receiveFlashLoan() → pulls USDC back
        balancerVault.flashLoan(address(this), tokens, amounts, userData);

        // Clear flash loan guard
        assembly { tstore(_IN_FLASH_LOAN_SLOT, 0) }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FLASH LOAN CALLBACK (called ONLY by Balancer Vault)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Balancer V2 flash loan callback — executes the full arb
     * @dev Called by Balancer Vault after sending USDC. Must leave enough
     *      USDC in contract for Balancer to pull back (flashAmount + fee).
     *      Fee is 0 on Balancer V2.
     */
    function receiveFlashLoan(
        IERC20[] memory,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        // ─────────────────────────────────────────────────────────────────────
        // SECURITY: Only Balancer Vault can call, and only during our flash loan
        // ─────────────────────────────────────────────────────────────────────
        if (msg.sender != address(balancerVault)) revert UnauthorizedCaller();
        bool _isInFlashLoan;
        assembly { _isInFlashLoan := tload(_IN_FLASH_LOAN_SLOT) }
        if (!_isInFlashLoan) revert FlashLoanReentrancy();

        // Decode parameters
        FloorParams memory params = abi.decode(userData, (FloorParams));
        uint256 flashAmount = amounts[0];
        uint256 flashFee = feeAmounts[0];
        uint256 repayAmount = flashAmount + flashFee;

        // Cache storage reads
        address _profitRecipient = profitRecipient;
        IERC20 _vyToken = IERC20(address(vyToken));
        address _usdcAddress = usdcAddress;

        // ─────────────────────────────────────────────────────────────────────
        // STEP 1: BUY VY WITH FLASH-LOANED USDC
        // ─────────────────────────────────────────────────────────────────────
        _executeSwaps(params.buySwaps);

        // ─────────────────────────────────────────────────────────────────────
        // STEP 2: RECORD VY AMOUNT (the X for the three-way lock)
        // ─────────────────────────────────────────────────────────────────────
        uint256 vyAmount = _vyToken.balanceOf(address(this));

        // ─────────────────────────────────────────────────────────────────────
        // STEP 3: MOVE 1 — SEND ALL VY TO VYT
        // ─────────────────────────────────────────────────────────────────────
        _vyToken.safeTransfer(address(vyt), vyAmount);

        // ─────────────────────────────────────────────────────────────────────
        // STEP 4: MOVES 2 & 3 — VALIDATE, COMPUTE, WITHDRAW, DECREASE CAPS
        // ─────────────────────────────────────────────────────────────────────
        uint256 wLen = params.withdrawals.length;
        address[] memory assets = new address[](wLen);
        uint256[] memory withdrawAmounts = new uint256[](wLen);
        uint256 totalCapReduction;

        for (uint256 i; i < wLen; ) {
            address asset = params.withdrawals[i].asset;
            uint256 capReduction = params.withdrawals[i].capReduction;

            if (asset == address(0)) revert InvalidAddress();
            if (capReduction == 0) revert InvalidAmount();

            // Read current on-chain state
            uint256 reserve = IERC20(asset).balanceOf(address(vrt));
            uint256 cap = vco.getAssetCap(asset);
            if (cap == 0) revert InvalidAmount();

            // Contract computes exact withdrawal at current LTV
            // LTV = reserve / cap → withdrawAmount = capReduction × reserve / cap
            uint256 withdrawAmount = (capReduction * reserve) / cap;
            if (withdrawAmount == 0) revert InvalidAmount();

            assets[i] = asset;
            withdrawAmounts[i] = withdrawAmount;
            totalCapReduction += capReduction;

            emit AssetWithdrawn(asset, withdrawAmount, capReduction);

            unchecked { ++i; }
        }

        // ─────────────────────────────────────────────────────────────────────
        // STEP 4.1: THREE-WAY LOCK — EVERY VY MUST BE ACCOUNTED FOR
        // ─────────────────────────────────────────────────────────────────────
        if (totalCapReduction != vyAmount) revert CapReductionMismatch();

        // ─────────────────────────────────────────────────────────────────────
        // STEP 5: WITHDRAW FROM VRT + REDUCE CAPS ON VCO
        // ─────────────────────────────────────────────────────────────────────
        vrt.withdrawForBuyback(assets, withdrawAmounts, address(this));

        for (uint256 i; i < wLen; ) {
            vco.decreaseAssetCap(
                params.withdrawals[i].asset,
                params.withdrawals[i].capReduction
            );
            unchecked { ++i; }
        }

        // ─────────────────────────────────────────────────────────────────────
        // STEP 6: SELL WITHDRAWN ASSETS → USDC
        // ─────────────────────────────────────────────────────────────────────
        _executeSwaps(params.sellSwaps);

        // ─────────────────────────────────────────────────────────────────────
        // STEP 7: REPAY FLASH LOAN
        // ─────────────────────────────────────────────────────────────────────
        IERC20(_usdcAddress).safeTransfer(
            address(balancerVault),
            repayAmount
        );

        // ─────────────────────────────────────────────────────────────────────
        // STEP 8: CONVERT REMAINING USDC PROFIT → VY
        // ─────────────────────────────────────────────────────────────────────
        if (params.profitSwaps.length > 0) {
            // Last profit swap MUST output VY
            if (
                params.profitSwaps[params.profitSwaps.length - 1].tokenOut !=
                address(vyToken)
            ) {
                revert FinalSwapMustOutputVY();
            }
            _executeSwaps(params.profitSwaps);
        }

        // ─────────────────────────────────────────────────────────────────────
        // STEP 9: SEND ALL PROFIT VY TO BUYBACK OFFICER
        // ─────────────────────────────────────────────────────────────────────
        uint256 profitVY = _vyToken.balanceOf(address(this));
        if (profitVY > 0) {
            _vyToken.safeTransfer(_profitRecipient, profitVY);
        }

        // ─────────────────────────────────────────────────────────────────────
        // STEP 10: ENFORCE CLEAN STATE
        // ─────────────────────────────────────────────────────────────────────

        // All withdrawn assets must be fully converted (zero remaining)
        for (uint256 i; i < wLen; ) {
            if (IERC20(assets[i]).balanceOf(address(this)) != 0) {
                revert TokenBalanceNotZero(assets[i]);
            }
            unchecked { ++i; }
        }

        // USDC must be zero (flash loan repaid + profit converted)
        if (IERC20(_usdcAddress).balanceOf(address(this)) != 0) {
            revert TokenBalanceNotZero(_usdcAddress);
        }

        // VY must be zero (all profit sent to recipient)
        if (_vyToken.balanceOf(address(this)) != 0) {
            revert TokenBalanceNotZero(address(vyToken));
        }

        // All swap intermediates must be zero (covers multi-hop routes)
        _checkSwapIntermediates(params.buySwaps, _usdcAddress);
        _checkSwapIntermediates(params.sellSwaps, _usdcAddress);
        _checkSwapIntermediates(params.profitSwaps, _usdcAddress);

        emit FloorExecuted(
            operator,
            flashAmount,
            vyAmount,
            profitVY,
            block.timestamp
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL SWAP EXECUTOR
    // ═══════════════════════════════════════════════════════════════════════════

    function _executeSwaps(SwapStep[] memory swaps) internal {
        uint256 sLen = swaps.length;
        for (uint256 i; i < sLen; ) {
            SwapStep memory step = swaps[i];

            if (!whitelistedRouters[step.router]) {
                revert RouterNotWhitelisted();
            }

            // Approve full tokenIn balance to whitelisted router
            uint256 tokenInBal = IERC20(step.tokenIn).balanceOf(address(this));
            IERC20(step.tokenIn).forceApprove(step.router, tokenInBal);

            // Snapshot tokenOut balance before swap
            uint256 outBefore = IERC20(step.tokenOut).balanceOf(address(this));

            // Execute swap — bubbles up revert reason on failure
            (bool ok, bytes memory returnData) = step.router.call(
                step.callData
            );
            if (!ok) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }

            // Output MUST have landed in this contract
            if (IERC20(step.tokenOut).balanceOf(address(this)) <= outBefore) {
                revert SwapOutputZero();
            }

            unchecked { ++i; }
        }
    }

    /// @dev Verify all intermediate tokens from a swap phase have zero balance
    /// @param swaps Swap steps to check
    /// @param excludeToken Token already checked explicitly (USDC)
    function _checkSwapIntermediates(
        SwapStep[] memory swaps,
        address excludeToken
    ) internal view {
        address _vyAddr = address(vyToken);
        uint256 len = swaps.length;
        for (uint256 i; i < len; ) {
            address tokenIn = swaps[i].tokenIn;
            address tokenOut = swaps[i].tokenOut;
            if (
                tokenIn != excludeToken &&
                tokenIn != _vyAddr &&
                IERC20(tokenIn).balanceOf(address(this)) != 0
            ) {
                revert TokenBalanceNotZero(tokenIn);
            }
            if (
                tokenOut != excludeToken &&
                tokenOut != _vyAddr &&
                IERC20(tokenOut).balanceOf(address(this)) != 0
            ) {
                revert TokenBalanceNotZero(tokenOut);
            }
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function setOperator(
        address newOperator
    ) external onlyRole(ADMIN_ROLE) {
        if (newOperator == address(0)) revert InvalidAddress();
        operator = newOperator;
        emit OperatorUpdated(newOperator);
    }

    function setProfitRecipient(
        address newRecipient
    ) external onlyRole(ADMIN_ROLE) {
        if (newRecipient == address(0)) revert InvalidAddress();
        profitRecipient = newRecipient;
        emit ProfitRecipientUpdated(newRecipient);
    }

    function setRouterWhitelist(
        address router,
        bool approved
    ) external onlyRole(ADMIN_ROLE) {
        if (router == address(0)) revert InvalidAddress();
        whitelistedRouters[router] = approved;
        emit RouterWhitelisted(router, approved);
    }

    function setPaused(bool paused) external onlyRole(ADMIN_ROLE) {
        execPaused = paused;
        emit Paused(paused);
    }

    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        IERC20(token).safeTransfer(to, amount);
    }
}
