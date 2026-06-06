// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ValinityYieldTreasury} from "../treasury/ValinityYieldTreasury.sol";

/**
 * @title ValinityMEVBotV2
 * @notice Upgradeable, permissionless MEV executor with closed-circuit settlement.
 * @dev Locked design goals:
 *  - Any caller can execute; per-caller cooldown throttles repeated calls.
 *  - Borrow VY from VYT, execute swaps, repay borrow, split profit.
 *  - Caller receives admin-set payout bps (1%-5%), Buyback Officer receives remainder.
 *  - End invariants: VY balance == 0 and every non-VY token touched in the route <= 1 wei.
 *    Keepers size legs from on-chain quote math; any rounding mistake reverts the tx.
 *  - No rescue function.
 *
 *  Admin model: deployed with the AWS-KMS multisig as ADMIN_ROLE. After burn-in,
 *  admin is transferred to the protocol governance contract via grantRole +
 *  renounceRole (see scripts/handoff_mevbot_v2_to_governance.ts). Once the
 *  handoff completes, the governance contract is the sole upgrader and
 *  configurator; bot-level upgrade timelocks are intentionally omitted because
 *  the governance contract enforces its own proposal / vote / timelock pipeline.
 */
contract ValinityMEVBotV2 is
    Initializable,
    UUPSUpgradeable,
    AccessControl,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_PAYOUT_BPS = 100; // 1%
    uint256 public constant MAX_PAYOUT_BPS = 500; // 5%
    uint256 public constant DEFAULT_PAYOUT_BPS = 100; // 1%

    uint256 public constant MIN_CALLER_COOLDOWN = 1 days;
    uint256 public constant MAX_CALLER_COOLDOWN = 30 days;
    uint256 public constant DEFAULT_CALLER_COOLDOWN = 7 days;

    /// @notice Maximum residual non-VY balance permitted after a route.
    uint256 public constant MAX_RESIDUAL_WEI = 1;

    IERC20 public vyToken;
    ValinityYieldTreasury public vyt;

    // Packed into one slot: 160 + 8 + 16 + 32 = 216 bits.
    address public buybackOfficer;
    bool    public execPaused;
    uint16  public payoutBps;
    uint32  public callerCooldown;

    mapping(address => uint256) public nextEligibleAt;
    mapping(address => bool) public whitelistedRouters;
    mapping(address => mapping(bytes4 => bool)) public routerSelectorAllowed;

    struct SwapStep {
        address router;
        address tokenIn;
        address tokenOut;
        bytes callData;
    }

    event Paused(bool paused);
    event PayoutBpsUpdated(uint256 newPayoutBps);
    event CallerCooldownUpdated(uint256 newCallerCooldown);
    event RouterWhitelisted(address indexed router, bool approved);
    event RouterSelectorSet(address indexed router, bytes4 indexed selector, bool allowed);
    event BuybackOfficerUpdated(address indexed newBuybackOfficer);
    event ArbExecuted(
        address indexed caller,
        uint256 borrowVY,
        uint256 netProfit,
        uint256 callerPayout,
        uint256 buybackPayout
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidSwapStep(uint256 stepIndex);
    error MalformedCallData(uint256 stepIndex);
    error SelectorNotAllowed(address router, bytes4 selector);
    error ExecutionPaused();
    error CooldownActive(uint256 eligibleAt);
    error NoSwapSteps();
    error RouterNotWhitelisted(address router);
    error SwapOutputZero(uint256 stepIndex);
    error InsufficientVYToRepay();
    error InvalidPayoutBps();
    error InvalidCooldown();
    error NonVYResidualTooHigh(address token, uint256 balance);
    error VYBalanceNotZero(uint256 balance);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vyTokenAddress,
        address vytAddress,
        address buybackOfficerAddress,
        address adminAddress
    ) external initializer {
        if (vyTokenAddress == address(0)) revert InvalidAddress();
        if (vytAddress == address(0)) revert InvalidAddress();
        if (buybackOfficerAddress == address(0)) revert InvalidAddress();
        if (adminAddress == address(0)) revert InvalidAddress();

        vyToken = IERC20(vyTokenAddress);
        vyt = ValinityYieldTreasury(vytAddress);
        buybackOfficer = buybackOfficerAddress;

        payoutBps = uint16(DEFAULT_PAYOUT_BPS);
        callerCooldown = uint32(DEFAULT_CALLER_COOLDOWN);

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @notice Execute a keeper-supplied arbitrage route.
     * @dev Closed-circuit: every non-VY token touched must end with <= 1 wei
     *      residual; final VY balance must be exactly 0.
     */
    function executeArb(
        uint256 borrowVY,
        SwapStep[] calldata swaps
    ) external nonReentrant {
        if (execPaused) revert ExecutionPaused();
        if (borrowVY == 0) revert InvalidAmount();
        if (swaps.length == 0) revert NoSwapSteps();

        uint256 eligibleAt = nextEligibleAt[msg.sender];
        if (block.timestamp < eligibleAt) revert CooldownActive(eligibleAt);

        // Cache hot state to stack (packed slot: 1 SLOAD covers all 4).
        address _buyback = buybackOfficer;
        uint256 _payoutBps = payoutBps;
        uint256 _cooldown = callerCooldown;
        IERC20 _vy = vyToken;
        address _vyAddr = address(_vy);
        ValinityYieldTreasury _vyt = vyt;

        // Self-heal pre-existing VY dust first.
        uint256 preBorrowVY = _vy.balanceOf(address(this));
        if (preBorrowVY > 0) {
            _vy.safeTransfer(_buyback, preBorrowVY);
        }

        // Pull VY for this cycle.
        _vyt.pullTokens(address(this), borrowVY);

        // Execute caller-provided route on whitelisted routers only.
        uint256 swapLen = swaps.length;
        for (uint256 i; i < swapLen; ) {
            SwapStep calldata step = swaps[i];
            if (step.router == address(0) || step.tokenIn == address(0) || step.tokenOut == address(0)) {
                revert InvalidSwapStep(i);
            }
            if (!whitelistedRouters[step.router]) {
                revert RouterNotWhitelisted(step.router);
            }
            if (step.callData.length < 4) revert MalformedCallData(i);

            bytes4 selector = _selectorFromCalldata(step.callData);
            if (!routerSelectorAllowed[step.router][selector]) {
                revert SelectorNotAllowed(step.router, selector);
            }

            uint256 tokenInBal = IERC20(step.tokenIn).balanceOf(address(this));
            if (tokenInBal == 0) revert InvalidSwapStep(i);
            IERC20(step.tokenIn).forceApprove(step.router, tokenInBal);

            uint256 outBefore = IERC20(step.tokenOut).balanceOf(address(this));
            (bool ok, bytes memory returnData) = step.router.call(step.callData);
            if (!ok) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }

            if (IERC20(step.tokenOut).balanceOf(address(this)) <= outBefore) {
                revert SwapOutputZero(i);
            }

            // Clear allowance so a later-revoked router cannot consume leftover approvals.
            IERC20(step.tokenIn).forceApprove(step.router, 0);

            unchecked {
                ++i;
            }
        }

        // Closed-circuit enforcement: every non-VY token touched must be <= 1 wei.
        _assertSwapResidualWithinEpsilon(swaps, _vyAddr);

        uint256 finalVY = _vy.balanceOf(address(this));
        if (finalVY < borrowVY) revert InsufficientVYToRepay();

        // Repay VYT first.
        _vy.safeTransfer(address(_vyt), borrowVY);

        uint256 netProfit;
        unchecked {
            netProfit = finalVY - borrowVY;
        }

        // Split net profit: caller bps + buyback remainder.
        uint256 callerPayout = (netProfit * _payoutBps) / BPS_DENOMINATOR;
        uint256 buybackPayout;
        unchecked {
            buybackPayout = netProfit - callerPayout;
        }

        if (callerPayout > 0) {
            _vy.safeTransfer(msg.sender, callerPayout);
        }
        if (buybackPayout > 0) {
            _vy.safeTransfer(_buyback, buybackPayout);
        }

        uint256 vyEnd = _vy.balanceOf(address(this));
        if (vyEnd != 0) revert VYBalanceNotZero(vyEnd);

        nextEligibleAt[msg.sender] = block.timestamp + _cooldown;

        emit ArbExecuted(
            msg.sender,
            borrowVY,
            netProfit,
            callerPayout,
            buybackPayout
        );
    }

    function _assertSwapResidualWithinEpsilon(SwapStep[] calldata swaps, address vy) internal view {
        uint256 len = swaps.length;
        for (uint256 i; i < len; ) {
            address tokenIn = swaps[i].tokenIn;
            address tokenOut = swaps[i].tokenOut;

            if (tokenIn != vy) {
                uint256 balIn = IERC20(tokenIn).balanceOf(address(this));
                if (balIn > MAX_RESIDUAL_WEI) revert NonVYResidualTooHigh(tokenIn, balIn);
            }
            if (tokenOut != vy && tokenOut != tokenIn) {
                uint256 balOut = IERC20(tokenOut).balanceOf(address(this));
                if (balOut > MAX_RESIDUAL_WEI) revert NonVYResidualTooHigh(tokenOut, balOut);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _selectorFromCalldata(bytes calldata data) internal pure returns (bytes4 selector) {
        assembly {
            selector := calldataload(data.offset)
        }
    }

    function setPaused(bool paused) external onlyRole(ADMIN_ROLE) {
        execPaused = paused;
        emit Paused(paused);
    }

    function setPayoutBps(uint256 newPayoutBps) external onlyRole(ADMIN_ROLE) {
        if (newPayoutBps < MIN_PAYOUT_BPS || newPayoutBps > MAX_PAYOUT_BPS) {
            revert InvalidPayoutBps();
        }
        payoutBps = uint16(newPayoutBps);
        emit PayoutBpsUpdated(newPayoutBps);
    }

    function setCallerCooldown(uint256 newCallerCooldown) external onlyRole(ADMIN_ROLE) {
        if (newCallerCooldown < MIN_CALLER_COOLDOWN || newCallerCooldown > MAX_CALLER_COOLDOWN) {
            revert InvalidCooldown();
        }
        callerCooldown = uint32(newCallerCooldown);
        emit CallerCooldownUpdated(newCallerCooldown);
    }

    function setRouterWhitelist(address router, bool approved) external onlyRole(ADMIN_ROLE) {
        if (router == address(0)) revert InvalidAddress();
        whitelistedRouters[router] = approved;
        emit RouterWhitelisted(router, approved);
    }

    function setRouterSelector(
        address router,
        bytes4 selector,
        bool allowed
    ) external onlyRole(ADMIN_ROLE) {
        if (router == address(0)) revert InvalidAddress();
        if (allowed && !whitelistedRouters[router]) revert RouterNotWhitelisted(router);
        routerSelectorAllowed[router][selector] = allowed;
        emit RouterSelectorSet(router, selector, allowed);
    }

    function setBuybackOfficer(address newBuybackOfficer) external onlyRole(ADMIN_ROLE) {
        if (newBuybackOfficer == address(0)) revert InvalidAddress();
        buybackOfficer = newBuybackOfficer;
        emit BuybackOfficerUpdated(newBuybackOfficer);
    }

    uint256[50] private __gap;
}
