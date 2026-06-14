// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ValinityReserveTreasury} from "../treasury/ValinityReserveTreasury.sol";
import {ValinityCapOfficer} from "../officer/ValinityCapOfficer.sol";
import {IKeeperRewards} from "../interfaces/IKeeperRewards.sol";

// ─────────────────────────────────────────────────────────────────────────────
// EXTERNAL INTERFACES
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Permissionless rebalance entry on the Reserve Yield Officer.
interface IValinityReserveYieldOfficer {
    function execute() external;
}

/// @notice Balancer V2 Vault — 0% fee flash loans
interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

/// @notice Uniswap V2 Router02 — for the open-market VY/USDC pool
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice Uniswap V3 Factory — used to resolve pool addresses per fee tier
interface IUniswapV3Factory {
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);
}

/// @notice Uniswap V3 SwapRouter02 (no deadline)
interface ISwapRouter02 {
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

/// @notice Uniswap V3 QuoterV2 — simulates a swap and reports output
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );
}

/**
 * @title ValinityFloorOfficer
 * @notice Permissionless, closed-circuit VY floor defense.
 * @dev    Single button — `executeFloor(uint256 flashAmount)` — anyone can call,
 *         caller pays gas. UUPS upgradeable; ADMIN_ROLE only.
 *
 *         Per-call flow (atomic, inside one Balancer V2 flash loan):
 *           1. Caller passes a USDC flashAmount.
 *           2. Balancer sends `flashAmount` USDC → receiveFlashLoan.
 *           3. Buy VY on Uniswap V2 (USDC/VY public pool) with that USDC.
 *           4. Identify largest-cap asset on VCO (= farthest from floor).
 *              vyAmount must fit within that asset's headroom; revert if not.
 *           5. Transfer vyAmount VY → VYT (burned from circulation).
 *           6. withdrawAmount = vyAmount × reserve / cap  (exact on-chain LTV).
 *              Pull `withdrawAmount` of `asset` from VRT.
 *           7. vco.decreaseAssetCap(asset, vyAmount) (exact same amount).
 *           8. Sell `asset` → USDC on the deepest Uniswap V3 pool, picked
 *              automatically by scanning the 4 standard fee tiers via QuoterV2.
 *           9. Repay flash loan to Balancer (revert if insufficient — this is
 *              the natural self-protection against bad `flashAmount`).
 *          10. If excess USDC remains, buy more VY on Uniswap V2 and forward
 *              the whole VY balance to the Buyback Officer. If no excess,
 *              do nothing — the floor was defended either way.
 *
 *         Hardcoded routing (no caller params for swaps, no router whitelist):
 *           Balancer ── USDC ──▶ this ── USDC ──▶ Uni V2 ── VY ──▶ this
 *           VRT      ── asset ─▶ this ── asset ─▶ Uni V3 ── USDC ─▶ this ─▶ Balancer
 *           (excess) USDC ──▶ Uni V2 ── VY ──▶ this ── VY ──▶ Buyback Officer
 *
 *         Self-protection on `flashAmount`:
 *           - Too large: V3 sell can't cover repayment → revert.
 *           - Too large for headroom: vyAmount > headroom → revert.
 *           - Above floor: VY costs more than collateral redeems → repay fails.
 *           Caller eats gas on a bad call; protocol state is untouched.
 *
 *         Admin-only knobs:
 *           - `setBuybackOfficer`, `setBalancerVault`, `setV2Router`,
 *             `setV3Factory`, `setV3Router`, `setV3Quoter`, `setUsdc`,
 *             `setPaused`, `rescueToken`, `upgradeToAndCall`.
 */
contract ValinityFloorOfficer is
    UUPSUpgradeable,
    AccessControl,
    ReentrancyGuardTransient,
    Initializable,
    IFlashLoanRecipient
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLES / CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev Transient slot guarding the Balancer flash callback.
    bytes32 private constant _IN_FLASH_LOAN_SLOT =
        keccak256("valinity.vfo.inFlashLoan");

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE (upgrade-safe layout)
    // ═══════════════════════════════════════════════════════════════════════════

    // -- Valinity system --
    IERC20 public vyToken;
    address public vyt;
    ValinityReserveTreasury public vrt;
    ValinityCapOfficer public vco;
    address public buybackOfficer; // profit recipient (VBBO)
    IValinityReserveYieldOfficer public vryo;

    /// @notice Keeper-reward engine (VGO). address(0) disables keeper refunds —
    ///         the floor defense still works, the caller just isn't reimbursed.
    IKeeperRewards public vgo;

    // -- External venues --
    IBalancerVault public balancerVault;
    IUniswapV2Router02 public v2Router;
    IUniswapV3Factory public v3Factory;
    ISwapRouter02 public v3Router;
    IQuoterV2 public v3Quoter;
    address public usdc;

    // -- Control --
    bool public execPaused;

    /// @dev Reserved storage for future upgrades.
    uint256[43] private __gap; // 44 -> 43: vgo consumed one slot
    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event BuybackOfficerUpdated(address indexed newBuybackOfficer);
    event VryoUpdated(address indexed newVryo);
    event VgoUpdated(address indexed newVgo);
    event KeeperRewardFailed(bytes reason);
    event BalancerVaultUpdated(address indexed newVault);
    event V2RouterUpdated(address indexed newRouter);
    event V3FactoryUpdated(address indexed newFactory);
    event V3RouterUpdated(address indexed newRouter);
    event V3QuoterUpdated(address indexed newQuoter);
    event UsdcUpdated(address indexed newUsdc);
    event Paused(bool execPaused);
    event FloorExecuted(
        address indexed caller,
        uint256 flashAmount,
        address indexed asset,
        uint256 vyBurned,
        uint256 assetWithdrawn,
        uint24 sellFeeTier,
        uint256 profitVY,
        uint256 timestamp
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidAddress();
    error InvalidAmount();
    error ExecutionPaused();
    error UnauthorizedCaller();
    error FlashLoanReentrancy();
    error NoHeadroom();
    error VyExceedsHeadroom(uint256 vyAmount, uint256 headroom);
    error NoV3PoolFound(address asset);
    error TokenBalanceNotZero(address token);
    error VyBuyReturnedZero();

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZER / UPGRADE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vyTokenAddress,
        address vytAddress,
        address vrtAddress,
        address vcoAddress,
        address buybackOfficerAddress,
        address balancerVaultAddress,
        address v2RouterAddress,
        address v3FactoryAddress,
        address v3RouterAddress,
        address v3QuoterAddress,
        address usdcAddress,
        address adminAddress,
        address vryoAddress
    ) public initializer {
        if (vyTokenAddress == address(0)) revert InvalidAddress();
        if (vytAddress == address(0)) revert InvalidAddress();
        if (vrtAddress == address(0)) revert InvalidAddress();
        if (vcoAddress == address(0)) revert InvalidAddress();
        if (buybackOfficerAddress == address(0)) revert InvalidAddress();
        if (balancerVaultAddress == address(0)) revert InvalidAddress();
        if (v2RouterAddress == address(0)) revert InvalidAddress();
        if (v3FactoryAddress == address(0)) revert InvalidAddress();
        if (v3RouterAddress == address(0)) revert InvalidAddress();
        if (v3QuoterAddress == address(0)) revert InvalidAddress();
        if (usdcAddress == address(0)) revert InvalidAddress();
        if (adminAddress == address(0)) revert InvalidAddress();
        if (vryoAddress == address(0)) revert InvalidAddress();

        vyToken = IERC20(vyTokenAddress);
        vyt = vytAddress;
        vrt = ValinityReserveTreasury(vrtAddress);
        vco = ValinityCapOfficer(vcoAddress);
        buybackOfficer = buybackOfficerAddress;

        balancerVault = IBalancerVault(balancerVaultAddress);
        v2Router = IUniswapV2Router02(v2RouterAddress);
        v3Factory = IUniswapV3Factory(v3FactoryAddress);
        v3Router = ISwapRouter02(v3RouterAddress);
        v3Quoter = IQuoterV2(v3QuoterAddress);
        usdc = usdcAddress;
        vryo = IValinityReserveYieldOfficer(vryoAddress);

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
    }

    /// @dev UUPS gate: only ADMIN_ROLE can push a new implementation.
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN ENTRY — PERMISSIONLESS, ONE ARG
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Defend the VY floor with one Balancer flash loan.
     * @param  flashAmount  USDC to flash-borrow (6 decimals).
     *                      Caller picks. Atomic repay protects against bad sizing.
     */
    function executeFloor(uint256 flashAmount) external nonReentrant {
        if (execPaused) revert ExecutionPaused();
        if (flashAmount == 0) revert InvalidAmount();

        // Arm the keeper reward: snapshot gas on the VGO. Best-effort — if the
        // VGO is unset, or VFO lacks OFFICER_ROLE / an enabled officer config on
        // it, this must NOT brick the floor defense, so it is wrapped. payReward
        // (at the end) only fires if arming succeeded.
        IKeeperRewards _vgo = vgo;
        bool _rewardArmed;
        if (address(_vgo) != address(0)) {
            try _vgo.beginReward() {
                _rewardArmed = true;
            } catch {}
        }

        // Set transient flash-loan guard
        bytes32 slot = _IN_FLASH_LOAN_SLOT;
        assembly { tstore(slot, 1) }

        address[] memory tokens = new address[](1);
        tokens[0] = usdc;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashAmount;

        // Pass the caller through userData so the callback can log it
        // without resorting to tx.origin.
        balancerVault.flashLoan(
            address(this),
            tokens,
            amounts,
            abi.encode(msg.sender)
        );

        // Clear guard
        assembly { tstore(slot, 0) }

        // Pay the keeper via the VGO (gas refund + flat bonus in VGC, from VGO
        // funds). Best-effort: a VGO failure must never brick the floor defense —
        // the floor already settled atomically inside the flash callback.
        if (_rewardArmed) {
            try _vgo.payReward(msg.sender) {} catch (bytes memory reason) {
                emit KeeperRewardFailed(reason);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BALANCER FLASH CALLBACK — runs the whole cycle
    // ═══════════════════════════════════════════════════════════════════════════

    function receiveFlashLoan(
        IERC20[] memory /* tokens */,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        // ---- Gates ----
        IBalancerVault _vault = balancerVault;
        if (msg.sender != address(_vault)) revert UnauthorizedCaller();
        bytes32 slot = _IN_FLASH_LOAN_SLOT;
        uint256 active;
        assembly { active := tload(slot) }
        if (active == 0) revert FlashLoanReentrancy();

        address caller_ = abi.decode(userData, (address));
        uint256 flashAmount = amounts[0];
        uint256 repayAmount = flashAmount + feeAmounts[0]; // Balancer V2 fee = 0

        // Cache state references once
        IERC20 _vyToken = vyToken;
        address _vyt = vyt;
        ValinityReserveTreasury _vrt = vrt;
        ValinityCapOfficer _vco = vco;
        IUniswapV2Router02 _v2Router = v2Router;
        address _usdc = usdc;
        address _buyback = buybackOfficer;

        // ---- 1. Buy VY on Uniswap V2 with flash USDC ----
        uint256 vyAmount = _buyVYonV2(_v2Router, _usdc, _vyToken, flashAmount);
        if (vyAmount == 0) revert VyBuyReturnedZero();

        // ---- 2. Pick the asset with the largest cap on VCO ----
        //         headroom == 0 also implies asset == address(0).
        (address asset, uint256 headroom, uint256 cap) = _findBestAsset(_vco);
        if (headroom == 0) revert NoHeadroom();

        // ---- 3. vyAmount must fit within that asset's headroom ----
        //         (else cap-decrease would drop below floor → revert)
        if (vyAmount > headroom) revert VyExceedsHeadroom(vyAmount, headroom);

        // ---- 4. Compute exact LTV withdrawal (fail-fast before the burn) ----
        uint256 reserve = IERC20(asset).balanceOf(address(_vrt));
        uint256 withdrawAmount = (vyAmount * reserve) / cap;
        if (withdrawAmount == 0) revert InvalidAmount();

        // ---- 5. Burn vyAmount to VYT ----
        _vyToken.safeTransfer(_vyt, vyAmount);

        // Snapshot pre-asset balance for the closed-circuit delta check
        uint256 preAssetBal = IERC20(asset).balanceOf(address(this));

        // ---- 6. Withdraw asset from VRT ----
        address[] memory wAssets = new address[](1);
        uint256[] memory wAmounts = new uint256[](1);
        wAssets[0] = asset;
        wAmounts[0] = withdrawAmount;
        _vrt.withdrawForBuyback(wAssets, wAmounts, address(this));

        // ---- 7. Decrease cap on VCO by exactly vyAmount ----
        _vco.decreaseAssetCap(asset, vyAmount);

        // ---- 8. Sell asset → USDC on the deepest V3 pool (auto-pick fee) ----
        (uint24 sellFee, ) = _swapAssetToUSDCv3(asset, _usdc, withdrawAmount);

        // ---- Closed-circuit invariant: no NEW residual collateral ----
        if (IERC20(asset).balanceOf(address(this)) > preAssetBal) {
            revert TokenBalanceNotZero(asset);
        }

        // ---- 9. Repay Balancer (natural revert on bad flashAmount) ----
        IERC20(_usdc).safeTransfer(address(_vault), repayAmount);

        // ---- 10. If excess USDC, buy more VY on V2 and forward to BBO ----
        uint256 leftover = IERC20(_usdc).balanceOf(address(this));
        uint256 profitVY;
        if (leftover > 0) {
            profitVY = _buyVYonV2(_v2Router, _usdc, _vyToken, leftover);
            if (profitVY > 0) {
                _vyToken.safeTransfer(_buyback, profitVY);
            }
        }

        emit FloorExecuted(
            caller_,
            flashAmount,
            asset,
            vyAmount,
            withdrawAmount,
            sellFee,
            profitVY,
            block.timestamp
        );

        // ---- 11. Trigger VRYO rebalance in the same transaction ----
        IValinityReserveYieldOfficer _vryo = vryo;
        if (address(_vryo) != address(0)) _vryo.execute();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Asset with the largest collateral cap on VCO. Because the effective
     *      floor is uniform across all assets, "largest cap" == "largest
     *      headroom". Returns (0, 0, 0) if every asset is at the floor.
     */
    function _findBestAsset(ValinityCapOfficer _vco)
        internal
        view
        returns (address bestAsset, uint256 bestHeadroom, uint256 bestCap)
    {
        address[] memory assets_ = _vco.getAssets();
        uint256 floor = _vco.effectiveFloor();
        uint256 len = assets_.length;
        for (uint256 i; i < len; ) {
            address a = assets_[i];
            uint256 c = _vco.getAssetCap(a);
            if (c > floor) {
                uint256 h;
                unchecked { h = c - floor; }
                if (h > bestHeadroom) {
                    bestHeadroom = h;
                    bestAsset = a;
                    bestCap = c;
                }
            }
            unchecked { ++i; }
        }
    }

    /// @dev Buy VY with USDC on the Uniswap V2 USDC/VY public pool.
    function _buyVYonV2(
        IUniswapV2Router02 _router,
        address _usdc,
        IERC20 _vyToken,
        uint256 usdcIn
    ) internal returns (uint256 vyOut) {
        IERC20(_usdc).forceApprove(address(_router), usdcIn);

        address[] memory path = new address[](2);
        path[0] = _usdc;
        path[1] = address(_vyToken);

        uint256 balBefore = _vyToken.balanceOf(address(this));
        // amountOutMin = 0 — atomic repay enforces overall profitability.
        _router.swapExactTokensForTokens(
            usdcIn,
            0,
            path,
            address(this),
            block.timestamp
        );
        vyOut = _vyToken.balanceOf(address(this)) - balBefore;
    }

    /**
     * @dev Sell `asset` for USDC on Uniswap V3, picking the deepest of the
     *      4 standard fee tiers {0.01%, 0.05%, 0.30%, 1.00%} via QuoterV2.
     *      Reverts if no V3 pool exists for the asset.
     */
    function _swapAssetToUSDCv3(
        address asset,
        address _usdc,
        uint256 amountIn
    ) internal returns (uint24 bestFee, uint256 usdcOut) {
        IUniswapV3Factory _factory = v3Factory;
        IQuoterV2 _quoter = v3Quoter;

        uint24[4] memory feeTiers = [
            uint24(100),
            uint24(500),
            uint24(3000),
            uint24(10000)
        ];

        uint256 bestOut;
        for (uint256 i; i < 4; ) {
            uint24 fee = feeTiers[i];
            address pool = _factory.getPool(asset, _usdc, fee);
            if (pool != address(0)) {
                try
                    _quoter.quoteExactInputSingle(
                        IQuoterV2.QuoteExactInputSingleParams({
                            tokenIn: asset,
                            tokenOut: _usdc,
                            amountIn: amountIn,
                            fee: fee,
                            sqrtPriceLimitX96: 0
                        })
                    )
                returns (uint256 q, uint160, uint32, uint256) {
                    if (q > bestOut) {
                        bestOut = q;
                        bestFee = fee;
                    }
                } catch {
                    // pool exists but quote failed (e.g., no in-range
                    // liquidity for this size). Skip silently.
                }
            }
            unchecked { ++i; }
        }
        if (bestFee == 0) revert NoV3PoolFound(asset);

        ISwapRouter02 _router = v3Router;
        IERC20(asset).forceApprove(address(_router), amountIn);

        usdcOut = _router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: asset,
                tokenOut: _usdc,
                fee: bestFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0, // atomic repay = effective slippage gate
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    function setBuybackOfficer(address newBuyback)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (newBuyback == address(0)) revert InvalidAddress();
        buybackOfficer = newBuyback;
        emit BuybackOfficerUpdated(newBuyback);
    }

    function setVryo(address newVryo) external onlyRole(ADMIN_ROLE) {
        if (newVryo == address(0)) revert InvalidAddress();
        vryo = IValinityReserveYieldOfficer(newVryo);
        emit VryoUpdated(newVryo);
    }

    /// @notice Configure the keeper-reward engine (VGO). Pass `newVgo =
    ///         address(0)` to disable keeper refunds. VFO must hold OFFICER_ROLE
    ///         + an enabled officer config on the VGO for payReward to succeed.
    function setVgo(address newVgo) external onlyRole(ADMIN_ROLE) {
        vgo = IKeeperRewards(newVgo);
        emit VgoUpdated(newVgo);
    }

    function setBalancerVault(address newVault)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (newVault == address(0)) revert InvalidAddress();
        balancerVault = IBalancerVault(newVault);
        emit BalancerVaultUpdated(newVault);
    }

    function setV2Router(address newRouter) external onlyRole(ADMIN_ROLE) {
        if (newRouter == address(0)) revert InvalidAddress();
        v2Router = IUniswapV2Router02(newRouter);
        emit V2RouterUpdated(newRouter);
    }

    function setV3Factory(address newFactory) external onlyRole(ADMIN_ROLE) {
        if (newFactory == address(0)) revert InvalidAddress();
        v3Factory = IUniswapV3Factory(newFactory);
        emit V3FactoryUpdated(newFactory);
    }

    function setV3Router(address newRouter) external onlyRole(ADMIN_ROLE) {
        if (newRouter == address(0)) revert InvalidAddress();
        v3Router = ISwapRouter02(newRouter);
        emit V3RouterUpdated(newRouter);
    }

    function setV3Quoter(address newQuoter) external onlyRole(ADMIN_ROLE) {
        if (newQuoter == address(0)) revert InvalidAddress();
        v3Quoter = IQuoterV2(newQuoter);
        emit V3QuoterUpdated(newQuoter);
    }

    function setUsdc(address newUsdc) external onlyRole(ADMIN_ROLE) {
        if (newUsdc == address(0)) revert InvalidAddress();
        usdc = newUsdc;
        emit UsdcUpdated(newUsdc);
    }

    function setPaused(bool paused) external onlyRole(ADMIN_ROLE) {
        execPaused = paused;
        emit Paused(paused);
    }

    /**
     * @notice Admin rescue for tokens stranded by misconfiguration.
     * @dev    VY is blocked — it must only flow to VYT (cycle) or to the
     *         Buyback Officer (profit).
     */
    function rescueToken(address token, address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (token == address(vyToken)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
    }
}
