// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ValinityYieldTreasury} from "../treasury/ValinityYieldTreasury.sol";
import {IKeeperRewards} from "../interfaces/IKeeperRewards.sol";

/// @notice Uniswap V2 (and forks) exact-input swap surface.
interface IUniV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice Uniswap V3 SwapRouter02 exact-input single-hop surface (no deadline field).
interface IUniV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice Valinity DAX exact-input swap surface.
interface IValinityDAXSwap {
    function swapExactIn(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);
}

/**
 * @title ValinityMEVBotV2
 * @notice Upgradeable, permissionless MEV executor with closed-circuit settlement.
 * @dev Locked design goals:
 *  - Any caller can execute; per-caller cooldown throttles repeated calls.
 *  - The keeper supplies ONLY: how much VY to borrow + the ROUTE (an ordered list of
 *    legs, each naming a DEX, a whitelisted router, tokenIn, tokenOut, and a pool
 *    selector). The keeper never specifies per-leg amounts or minimum outputs.
 *  - The contract sizes every leg at 100% of its current tokenIn balance, builds the
 *    swap call itself (recipient hardcoded to the bot, amountOutMinimum = 0), and runs
 *    the route one way: VY -> ... -> VY. Because each leg spends the full balance, every
 *    intermediate token is fully consumed and the bot can only ever finish holding VY —
 *    there is no non-VY residual to manage, and the Buyback Officer only ever receives VY.
 *  - Hardcoded on-chain flow-of-funds enforcement (the ONLY things enforced):
 *      1. The route starts in VY and ends in VY, and is a single connected chain.
 *      2. Each swap's output returns to the bot (SwapOutputZero).
 *      3. VYT is repaid 100% of the borrowed VY (else InsufficientVYToRepay).
 *      4. Net VY profit clears the minProfitVY floor (else ProfitBelowMinimum); 100% of
 *         that profit goes to the Buyback Officer; VY ends 0. The keeper is NOT paid from
 *         profit — it is reimbursed by the VGO (gas refund + flat bonus) via a best-effort
 *         beginReward()/payReward() bracket that can never brick an arb. The floor stops a
 *         keeper from running dust-profit loops purely to collect the VGO reimbursement.
 *    Per-leg sizing and slippage are deliberately NOT enforced — fee-bearing assets and
 *    quote/execution drift never block a trade; an unprofitable loop simply reverts at
 *    the repay check and the borrow is rolled back atomically. The bot can never end at a
 *    loss to the treasury, and no token can leave except VYT repayment and the Buyback
 *    Officer's VY (the keeper's reward comes from the VGO, not from this contract's funds).
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

    uint256 public constant MIN_CALLER_COOLDOWN = 1 days;
    uint256 public constant MAX_CALLER_COOLDOWN = 30 days;
    uint256 public constant DEFAULT_CALLER_COOLDOWN = 7 days;

    IERC20 public vyToken;
    ValinityYieldTreasury public vyt;

    // Packed into one slot: 160 + 8 + 16 + 32 = 216 bits.
    address public buybackOfficer;
    bool    public execPaused;
    /// @dev DEPRECATED and unused. The caller profit-share was removed — 100% of arb
    ///      profit now goes to the Buyback Officer and the keeper is reimbursed by the VGO.
    ///      Retained in its packed slot only to preserve the deployed proxy's layout.
    uint16  public payoutBps;
    uint32  public callerCooldown;

    mapping(address => uint256) public nextEligibleAt;
    mapping(address => bool) public whitelistedRouters;

    /// @dev DEPRECATED and unused. Retained with its original name/type/slot only to
    ///      preserve the deployed proxy's storage layout; the route model no longer uses a
    ///      per-selector allowlist (the contract builds each swap call itself). Any values
    ///      left from the prior implementation are inert and never read.
    mapping(address => mapping(bytes4 => bool)) public routerSelectorAllowed;

    /// @notice Keeper-reward engine (ValinityGasOfficerV3). executeArb brackets its work
    ///         with vgo.beginReward()/payReward(msg.sender) so the VGO reimburses the keeper
    ///         a gas refund + flat bonus out of VGO funds (replacing the old profit share).
    ///         address(0) disables rewards. Appended after the deprecated mapping (consumes
    ///         one previously-gapped slot) — layout stays compatible with the deployed proxy.
    IKeeperRewards public vgo;

    /// @notice Minimum VY profit an arb must clear, all of which goes to the Buyback
    ///         Officer. Anti-grief: without it a keeper could run dust-profit loops
    ///         purely to collect the VGO gas refund + bonus. An arb whose net profit
    ///         is below this floor reverts (ProfitBelowMinimum) and rolls back. 0
    ///         disables the floor. Appended after `vgo` (consumes one previously-gapped
    ///         slot) — defaults to 0 on the live proxy until an admin sets it.
    uint256 public minProfitVY;

    /// @notice Which DEX family a leg targets. Determines how the contract encodes the
    ///         swap call. ABI-decoding rejects out-of-range values automatically.
    enum DexKind {
        UniV2,
        UniV3,
        ValinityDAX
    }

    /// @notice One hop of a route. The keeper supplies no amounts and no minimum out.
    /// @param kind     Which DEX family `router` belongs to (selects the encoder).
    /// @param router   The whitelisted DEX router/contract to call.
    /// @param tokenIn  Token spent by this leg (the bot's full balance is swapped).
    /// @param tokenOut Token received by this leg (must return to the bot).
    /// @param extra    UniV3: the pool fee tier (uint24). ValinityDAX: the poolId. UniV2: unused.
    struct Leg {
        DexKind kind;
        address router;
        address tokenIn;
        address tokenOut;
        uint256 extra;
    }

    event Paused(bool paused);
    event CallerCooldownUpdated(uint256 newCallerCooldown);
    event RouterWhitelisted(address indexed router, bool approved);
    event BuybackOfficerUpdated(address indexed newBuybackOfficer);
    event VgoUpdated(address indexed newVgo);
    event MinProfitUpdated(uint256 newMinProfitVY);
    event KeeperRewardFailed(bytes reason);
    event ArbExecuted(
        address indexed caller,
        uint256 borrowVY,
        uint256 netProfit,
        uint256 callerPayout,
        uint256 buybackPayout
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidLeg(uint256 legIndex);
    error ExecutionPaused();
    error CooldownActive(uint256 eligibleAt);
    error NoLegs();
    error RouterNotWhitelisted(address router);
    error RouteNotConnected(uint256 legIndex);
    error RouteMustStartInVY();
    error RouteMustEndInVY();
    error SwapOutputZero(uint256 legIndex);
    error TokenInNotDrained(uint256 legIndex);
    error InsufficientVYToRepay();
    error ProfitBelowMinimum(uint256 netProfit, uint256 minProfitVY);
    error InvalidCooldown();
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

        callerCooldown = uint32(DEFAULT_CALLER_COOLDOWN);

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @notice Borrow VY, run a keeper-supplied route, repay VYT, pay out the profit.
     * @dev Closed-circuit: the route must start and end in VY and be a single connected
     *      chain; every leg spends 100% of its tokenIn balance, so the bot finishes holding
     *      only VY. The contract sets each swap's recipient to itself and amountOutMinimum
     *      to 0 — per-leg sizing and slippage are intentionally not enforced. The only hard
     *      guarantees are: VYT repaid in full, 100% of profit to the Buyback Officer, VY ends 0.
     *      The keeper is reimbursed by the VGO (best-effort), never from arb profit.
     * @param borrowVY Amount of VY to borrow from VYT and route (the keeper's only "amount").
     * @param legs     Ordered route; each leg names a DEX, a whitelisted router, and a token pair.
     */
    function executeArb(
        uint256 borrowVY,
        Leg[] calldata legs
    ) external nonReentrant {
        if (execPaused) revert ExecutionPaused();
        if (borrowVY == 0) revert InvalidAmount();
        uint256 legCount = legs.length;
        if (legCount == 0) revert NoLegs();

        uint256 eligibleAt = nextEligibleAt[msg.sender];
        if (block.timestamp < eligibleAt) revert CooldownActive(eligibleAt);

        // Cache hot state to stack.
        address _buyback = buybackOfficer;
        uint256 _cooldown = callerCooldown;
        IERC20 _vy = vyToken;
        address _vyAddr = address(_vy);
        ValinityYieldTreasury _vyt = vyt;

        // Arm the keeper reward: snapshot gas on the VGO. Best-effort — if the VGO is unset,
        // or the bot lacks OFFICER_ROLE / an enabled officer config on it, this must NOT brick
        // the arb, so it is wrapped. payReward (at the end) only fires if arming succeeded.
        IKeeperRewards _vgo = vgo;
        bool _rewardArmed;
        if (address(_vgo) != address(0)) {
            try _vgo.beginReward() {
                _rewardArmed = true;
            } catch {}
        }

        // The route is a closed VY loop: it must begin and end in VY.
        if (legs[0].tokenIn != _vyAddr) revert RouteMustStartInVY();
        if (legs[legCount - 1].tokenOut != _vyAddr) revert RouteMustEndInVY();

        // Self-heal pre-existing VY dust first so leg 1 swaps exactly the borrowed VY.
        uint256 preBorrowVY = _vy.balanceOf(address(this));
        if (preBorrowVY > 0) {
            _vy.safeTransfer(_buyback, preBorrowVY);
        }

        // Pull VY for this cycle.
        _vyt.pullTokens(address(this), borrowVY);

        // Run the route on whitelisted routers only. Each leg swaps the bot's FULL current
        // tokenIn balance; the contract sizes and encodes the call (recipient = this, minOut = 0).
        for (uint256 i; i < legCount; ) {
            Leg calldata leg = legs[i];

            if (leg.router == address(0) || leg.tokenIn == address(0) || leg.tokenOut == address(0)) {
                revert InvalidLeg(i);
            }
            if (leg.tokenIn == leg.tokenOut) revert InvalidLeg(i);
            if (!whitelistedRouters[leg.router]) revert RouterNotWhitelisted(leg.router);
            // Single connected chain: this leg's input is the previous leg's output.
            if (i != 0 && leg.tokenIn != legs[i - 1].tokenOut) revert RouteNotConnected(i);

            uint256 amountIn = IERC20(leg.tokenIn).balanceOf(address(this));
            if (amountIn == 0) revert InvalidLeg(i);

            IERC20(leg.tokenIn).forceApprove(leg.router, amountIn);

            uint256 outBefore = IERC20(leg.tokenOut).balanceOf(address(this));
            _executeSwap(leg, amountIn, i);
            if (IERC20(leg.tokenOut).balanceOf(address(this)) <= outBefore) {
                revert SwapOutputZero(i);
            }
            // Enforce the closed-loop invariant directly instead of trusting the router:
            // the leg must consume the bot's ENTIRE tokenIn balance. Canonical exact-input
            // routers (UniV2/UniV3/DAX) always pull the full approved amount; a misbehaving
            // or non-canonical whitelisted router that under-pulls would otherwise strand a
            // non-VY residual the VY-only end checks never catch. Reverts + rolls back atomically.
            if (IERC20(leg.tokenIn).balanceOf(address(this)) != 0) {
                revert TokenInNotDrained(i);
            }

            // Clear allowance so a later-revoked router cannot consume leftover approvals.
            IERC20(leg.tokenIn).forceApprove(leg.router, 0);

            unchecked {
                ++i;
            }
        }

        // Route ended in VY (enforced above) and every intermediate token was fully
        // consumed, so the bot holds only VY now. Repay VYT 100% of the borrow.
        uint256 finalVY = _vy.balanceOf(address(this));
        if (finalVY < borrowVY) revert InsufficientVYToRepay();

        uint256 netProfit;
        unchecked {
            netProfit = finalVY - borrowVY;
        }

        // Anti-grief floor: the arb must clear a minimum VY profit (all of which goes
        // to the Buyback Officer). Checked before any settlement so a sub-floor loop
        // fails fast and rolls the borrow back — a keeper cannot run dust-profit arbs
        // just to collect the VGO gas refund + bonus. minProfitVY == 0 disables it.
        if (netProfit < minProfitVY) revert ProfitBelowMinimum(netProfit, minProfitVY);

        // Repay VYT 100% of the borrow, then 100% of the VY profit goes to the Buyback
        // Officer. The keeper is NOT paid from profit — it is reimbursed by the VGO
        // (gas refund + flat bonus) below.
        _vy.safeTransfer(address(_vyt), borrowVY);
        if (netProfit > 0) {
            _vy.safeTransfer(_buyback, netProfit);
        }

        uint256 vyEnd = _vy.balanceOf(address(this));
        if (vyEnd != 0) revert VYBalanceNotZero(vyEnd);

        nextEligibleAt[msg.sender] = block.timestamp + _cooldown;

        emit ArbExecuted(
            msg.sender,
            borrowVY,
            netProfit,
            0,         // callerPayout: removed — keeper is reimbursed by the VGO, not from profit
            netProfit  // buybackPayout: 100% of profit to the Buyback Officer
        );

        // Pay the keeper via the VGO (gas refund + flat bonus, from VGO funds). Best-effort:
        // a VGO failure (missing role/config, cooldown, disabled) must never brick an arb —
        // the profit already settled and VY ended at 0.
        if (_rewardArmed) {
            try _vgo.payReward(msg.sender) {} catch (bytes memory reason) {
                emit KeeperRewardFailed(reason);
            }
        }
    }

    /// @dev Build and execute one leg's swap, sizing amountIn at the bot's full balance,
    ///      pinning the recipient to this contract and the minimum output to 0. The DEX
    ///      kind selects the encoder; a typed external call bubbles any router revert.
    function _executeSwap(Leg calldata leg, uint256 amountIn, uint256 legIndex) internal {
        if (leg.kind == DexKind.UniV2) {
            address[] memory path = new address[](2);
            path[0] = leg.tokenIn;
            path[1] = leg.tokenOut;
            IUniV2Router(leg.router).swapExactTokensForTokens(
                amountIn,
                0,
                path,
                address(this),
                block.timestamp
            );
        } else if (leg.kind == DexKind.UniV3) {
            if (leg.extra > type(uint24).max) revert InvalidLeg(legIndex);
            IUniV3SwapRouter(leg.router).exactInputSingle(
                IUniV3SwapRouter.ExactInputSingleParams({
                    tokenIn: leg.tokenIn,
                    tokenOut: leg.tokenOut,
                    fee: uint24(leg.extra),
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        } else {
            // DexKind.ValinityDAX
            IValinityDAXSwap(leg.router).swapExactIn(
                leg.extra, // poolId
                leg.tokenIn,
                amountIn,
                0,
                address(this)
            );
        }
    }

    function setPaused(bool paused) external onlyRole(ADMIN_ROLE) {
        execPaused = paused;
        emit Paused(paused);
    }

    /// @notice Set the VGO keeper-reward engine. address(0) disables keeper rewards (arbs
    ///         still run; keepers simply aren't reimbursed). For payouts to fire, the MEVBot
    ///         must hold OFFICER_ROLE + an enabled officer config on the VGO.
    function setVgo(address newVgo) external onlyRole(ADMIN_ROLE) {
        vgo = IKeeperRewards(newVgo);
        emit VgoUpdated(newVgo);
    }

    /// @notice Set the minimum VY profit an arb must clear (all to the Buyback Officer).
    ///         0 disables the floor. Below the floor, executeArb reverts ProfitBelowMinimum.
    function setMinProfitVY(uint256 newMinProfitVY) external onlyRole(ADMIN_ROLE) {
        minProfitVY = newMinProfitVY;
        emit MinProfitUpdated(newMinProfitVY);
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

    function setBuybackOfficer(address newBuybackOfficer) external onlyRole(ADMIN_ROLE) {
        if (newBuybackOfficer == address(0)) revert InvalidAddress();
        buybackOfficer = newBuybackOfficer;
        emit BuybackOfficerUpdated(newBuybackOfficer);
    }

    // Reduced from 50 -> 48: `vgo` and `minProfitVY` each consumed one previously-gapped slot.
    uint256[48] private __gap;
}
