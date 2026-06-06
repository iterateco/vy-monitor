// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ValinityCapOfficer} from "./ValinityCapOfficer.sol";
import {ValinityYieldTreasury} from "../treasury/ValinityYieldTreasury.sol";
import {ValinityReserveTreasury} from "../treasury/ValinityReserveTreasury.sol";
import {ValinityToken} from "../token/ValinityToken.sol";
import {IValinityDAX} from "../dex/interfaces/IValinityDAX.sol";
import {IKeeperRewards} from "../interfaces/IKeeperRewards.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMathWrapper as TickMath} from "../library/TickMathWrapper.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

/// @notice Minimal accessor on ValinityDAX not exposed by IValinityDAX (mirrors BBO pattern).
interface IValinityDAXLookup {
    function assetToPoolId(address asset) external view returns (uint256);
}

/// @notice Permissionless rebalance entry on the Reserve Yield Officer.
interface IValinityReserveYieldOfficer {
    function execute() external;
}

/**
 * @title ValinityAcquisitionOfficer (V2)
 * @notice Closed-circuit, permissionless asset acquisition for the Valinity protocol.
 *         Also acts as the on-chain TWAP oracle that VCO uses to value collateral.
 *
 *         Two permissionless entry points, each with its own cooldown:
 *
 *         ── executeAcquireByLTV() ────────────────────────────────────
 *         Trigger: ltvF(H) >= 1.05 x ltvF(L)  for some VCO asset pair (H, L).
 *         Closed-form half-the-gap on H:
 *             totalVy = capH * (ltvFH - ltvFL) / (ltvFH + ltvFL)
 *         Pull totalVy VY from VYT; 1% to BBO; swap rest on DAX for L;
 *         deposit L to VRT; raise cap on H by the FULL totalVy.
 *
 *         ── executeAcquireByMTP() ────────────────────────────────────
 *         Trigger: DAX (USD-per-VY) price >= 2.10 x ltvF(M)  for some asset M.
 *         Target:  push DAX price down to 1.90 x ltvF(M).
 *         Constant-product closed form for netVy; gross up for the 2% fee.
 *         Pull totalVy VY from VYT; 2% to BBO; swap rest on DAX for M;
 *         deposit M to VRT; raise cap on M by the FULL totalVy.
 *
 *         Routing is hard-wired through Valinity DAX. No caller params for routes.
 *         Admin can pause.
 *
 *         TWAP oracle (`getAssetTwapPrice`) is preserved exactly from V1 — VCO
 *         reads it for LTV-F.
 */
contract ValinityAcquisitionOfficer is
    UUPSUpgradeable,
    AccessControl,
    ReentrancyGuardTransient,
    Initializable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @custom:deprecated V1 caller gate; V2 entries are permissionless. ABI continuity.
    bytes32 public constant WALLET_ROLE = keccak256("WALLET_ROLE");
    uint16 public constant BPS_MULTIPLIER = 10_000;
    uint24 public constant DEFAULT_FEE_TIER = 3000;
    uint32 public constant DEFAULT_TWAP_INTERVAL = 1800; // 30 minutes (TWAP oracle)
    uint8 internal constant DEFAULT_DECIMALS = 18;
    uint16 public constant MAX_POOL_CAP_BPS = 2500; // legacy

    /// @notice Trigger threshold for LTV-disparity acquisition (105% = 5% gap).
    uint256 public constant LTV_TRIGGER_BPS = 10_500;
    /// @notice Trigger threshold for MTP-disparity (210% of ltvF), scaled 1e18.
    uint256 public constant MTP_TRIGGER_X = 2.1e18;
    /// @notice Target price after MTP acquisition (190% of ltvF), scaled 1e18.
    uint256 public constant MTP_TARGET_X = 1.9e18;
    /// @notice Max cooldown allowed (matches BBO pattern).
    uint32 public constant MAX_COOLDOWN = 1 days;
    /// @notice 18-decimal scaling unit.
    uint256 internal constant WAD = 1e18;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE — STORAGE LAYOUT FROZEN FROM V1, NEW VARS APPENDED ONLY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Recipient of acquisition fees. In V2: the Buyback Officer.
    address public feeRecipient;
    address public usdcAddress;

    /// @notice Fee BPS for MTP path. V2 default: 200 (2%).
    uint16 public priceDisparityFeeBps;
    /// @notice Fee BPS for LTV path. V2 default: 100 (1%).
    uint16 public ltvDisparityFeeBps;
    /// @notice Max slippage tolerated on the DAX swap leg (BPS). V2 default: 100 (1%).
    ///         Reuses the V1 `slippageBps` storage slot (was unused).
    /// @custom:oz-renamed-from slippageBps
    uint16 public swapSlippageBps;

    /// @notice Cooldown (seconds) between MTP acquisitions. Capped at MAX_COOLDOWN.
    uint32 public priceDisparityCooldown;
    /// @notice Cooldown (seconds) between LTV acquisitions. Capped at MAX_COOLDOWN.
    uint32 public ltvDisparityCooldown;

    uint256 public lastPriceDisparityTrigger;
    uint256 public lastLTVDisparityTrigger;

    /// @custom:deprecated V1 swap routing slot.
    mapping(address => uint24) internal __deprecated_assetPoolFeeTiers;
    /// @custom:deprecated V1 V2-router slot.
    address internal __deprecated_uniswapV2Router;

    IUniswapV3Factory internal uniswapV3Factory;

    ValinityCapOfficer public vco;
    ValinityReserveTreasury public vrt;
    ValinityYieldTreasury public vyt;
    ValinityToken public vyToken;

    address public vyUsdcV2Pair;
    bool public vyIsToken0;

    address public wethAddress;
    uint24 public wethUsdcTwapFeeTier;

    mapping(address => address) public assetTwapQuoteToken;
    mapping(address => uint24) public assetTwapFeeTier;

    /// @custom:deprecated V1 pool cap limiter.
    uint16 public poolCapBps;
    /// @custom:deprecated V1 router allowlist.
    mapping(address => bool) public whitelistedRouters;

    // ─── NEW IN V2 ─────────────────────────────────────────────────────────────

    /// @notice Valinity DAX router/pool registry.
    IValinityDAX public dax;
    /// @notice Pause kill-switch on the two acquire entries.
    bool public execPaused;
    /// @notice Reserve Yield Officer; called once at the end of every cycle.
    IValinityReserveYieldOfficer public vryo;

    /// @notice Valinity Gas Officer — keeper-reward bracket sink.
    ///         When set, the two permissionless entries are wrapped in
    ///         `vgo.beginReward()` / `vgo.payReward(msg.sender)` so VGO
    ///         reimburses the caller's gas + flat bonus. Best-effort.
    IKeeperRewards public vgo;

    /// @dev Reserved storage for future upgrades.
    uint256[42] private __gap;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted on a successful acquisition.
    /// @param  reason          0 = MTP (price disparity), 1 = LTV disparity.
    event Acquired(
        uint8   indexed reason,
        address indexed assetBought,
        address indexed capIncreaseAsset,
        uint256 totalVY,
        uint256 fee,
        uint256 assetReceived
    );

    event DaxUpdated(address indexed newDax);
    event BuybackOfficerUpdated(address indexed newRecipient);
    event VryoUpdated(address indexed newVryo);
    event VgoUpdated(address indexed newVgo);
    event Paused(bool execPaused);
    event SwapSlippageUpdated(uint16 newBps);
    event VryoHeartbeatFailed(bytes reason);
    event KeeperRewardFailed(bytes reason);

    // Retained V1 admin events (indexer continuity)
    event PriceDisparityCooldownUpdated(uint32 value);
    event LTVDisparityCooldownUpdated(uint32 value);
    event PriceDisparityFeeUpdated(uint16 newBps);
    event LTVDisparityFeeUpdated(uint16 newBps);
    event TokenRescued(address token, address to, uint256 amount);
    event AssetTwapConfigUpdated(address indexed asset, address quoteToken, uint24 feeTier);
    event WethUsdcTwapFeeTierUpdated(uint24 feeTier);
    event WethAddressUpdated(address weth);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error FeeTooHigh();
    error InvalidAddress();
    error InvalidFeeTier();
    error InvalidAmount();
    error PoolDoesNotExist();
    error TriggerCooldownActive();
    error CooldownTooLong();
    error ExecutionPaused();
    error NoLtvDisparity();
    error NoMtpDisparity();
    error InvalidVyBalance(uint256 expected, uint256 actual);
    error InvalidAssetBalance(address asset);
    error DaxPoolNotFound(address asset);
    error SlippageTooHigh();
    error InsufficientOutput();

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR & INITIALIZERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice V1 initializer — kept for ABI/upgrade-tooling continuity.
    /// @dev    Existing proxies have already executed this; new V2 deploys MUST
    ///         then call `initializeV2` to wire the DAX + BBO.
    function initialize(
        address vcoAddress,
        address vrtAddress,
        address vytAddress,
        address vyTokenAddress,
        address adminAddress,
        address uniswapV3FactoryAddress,
        address usdcAddr
    ) public initializer {
        if (
            vcoAddress == address(0) ||
            vrtAddress == address(0) ||
            vytAddress == address(0) ||
            vyTokenAddress == address(0) ||
            adminAddress == address(0) ||
            uniswapV3FactoryAddress == address(0) ||
            usdcAddr == address(0)
        ) {
            revert InvalidAddress();
        }

        vco = ValinityCapOfficer(vcoAddress);
        vrt = ValinityReserveTreasury(vrtAddress);
        vyt = ValinityYieldTreasury(vytAddress);
        vyToken = ValinityToken(vyTokenAddress);

        usdcAddress = usdcAddr;
        uniswapV3Factory = IUniswapV3Factory(uniswapV3FactoryAddress);

        priceDisparityFeeBps = 200;  // 2%
        ltvDisparityFeeBps = 100;    // 1%
        priceDisparityCooldown = 1 hours;
        ltvDisparityCooldown = 1 hours;
        poolCapBps = 500; // legacy

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
        _setRoleAdmin(WALLET_ROLE, ADMIN_ROLE);
    }

    /// @notice V2 initializer — wires the DAX, BBO fee sink, VRYO heartbeat,
    ///         and the VGO keeper-reward bracket. Also pre-approves DAX to
    ///         spend VY (MAX) so every cycle skips the per-call approve cost.
    /// @dev    Call once via
    ///         `upgradeToAndCall(newImpl, abi.encodeCall(initializeV2,(dax,bbo,vryo,vgo)))`.
    function initializeV2(
        address daxAddress,
        address buybackOfficerAddress,
        address vryoAddress,
        address vgoAddress
    ) external reinitializer(2) {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert InvalidAddress();
        if (daxAddress == address(0)) revert InvalidAddress();
        if (buybackOfficerAddress == address(0)) revert InvalidAddress();
        if (vryoAddress == address(0)) revert InvalidAddress();
        // vgoAddress MAY be address(0) — bracket is best-effort and skipped

        dax = IValinityDAX(daxAddress);
        feeRecipient = buybackOfficerAddress;
        vryo = IValinityReserveYieldOfficer(vryoAddress);
        vgo = IKeeperRewards(vgoAddress);

        // Re-assert locked V2 defaults (idempotent)
        priceDisparityFeeBps = 200;
        ltvDisparityFeeBps = 100;
        if (priceDisparityCooldown == 0 || priceDisparityCooldown > MAX_COOLDOWN) {
            priceDisparityCooldown = 1 hours;
        }
        if (ltvDisparityCooldown == 0 || ltvDisparityCooldown > MAX_COOLDOWN) {
            ltvDisparityCooldown = 1 hours;
        }
        if (swapSlippageBps == 0 || swapSlippageBps > 1_000) {
            swapSlippageBps = 100; // 1% default cap
        }
        execPaused = false;

        // One-shot MAX approve so `_executeCycle` skips per-call forceApprove.
        IERC20(address(vyToken)).forceApprove(daxAddress, type(uint256).max);

        emit DaxUpdated(daxAddress);
        emit BuybackOfficerUpdated(buybackOfficerAddress);
        emit VryoUpdated(vryoAddress);
        emit VgoUpdated(vgoAddress);
        emit SwapSlippageUpdated(swapSlippageBps);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PERMISSIONLESS ENTRY POINTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Rebalance backing across assets when LTV-F disparity >= 5%.
    function executeAcquireByLTV() external nonReentrant {
        if (execPaused) revert ExecutionPaused();
        if (block.timestamp < lastLTVDisparityTrigger + ltvDisparityCooldown) {
            revert TriggerCooldownActive();
        }

        // VGO keeper-reward bracket — best effort, never blocks the cycle.
        IKeeperRewards _vgo = vgo;
        bool useVgo = address(_vgo) != address(0);
        if (useVgo) {
            try _vgo.beginReward() {} catch (bytes memory reason) {
                useVgo = false;
                emit KeeperRewardFailed(reason);
            }
        }

        ValinityCapOfficer _vco = vco;
        ValinityYieldTreasury _vyt = vyt;
        ValinityReserveTreasury _vrt = vrt;
        ValinityToken _vy = vyToken;
        IValinityDAX _dax = dax;
        address _bbo = feeRecipient;

        // 1. Find H (max ltvF) and L (min ltvF, > 0)
        (address assetH, uint256 ltvFH, uint256 capH, address assetL, uint256 ltvFL) =
            _findLtvExtremes(_vco);
        if (assetH == address(0) || assetL == address(0) || assetH == assetL) {
            revert NoLtvDisparity();
        }

        // 2. Disparity gate: ltvFH * 10_000 >= ltvFL * 10_500
        if (ltvFH * BPS_MULTIPLIER < ltvFL * LTV_TRIGGER_BPS) revert NoLtvDisparity();

        // 3. Closed form: totalVy = capH * (ltvFH - ltvFL) / (ltvFH + ltvFL)
        uint256 totalVy = Math.mulDiv(capH, ltvFH - ltvFL, ltvFH + ltvFL);
        if (totalVy == 0) revert InvalidAmount();

        // 4. Execute cycle
        uint256 fee = _feeOf(totalVy, ltvDisparityFeeBps);
        uint256 assetReceived = _executeCycle(
            _vyt, _vy, _dax, _vrt, _vco,
            assetL,   // swap target / VRT deposit
            assetH,   // cap-raise target
            totalVy,
            fee,
            _bbo
        );

        lastLTVDisparityTrigger = block.timestamp;
        emit Acquired(1, assetL, assetH, totalVy, fee, assetReceived);

        // Pay caller's gas refund + flat bonus. Best-effort.
        if (useVgo) {
            try _vgo.payReward(msg.sender) {} catch (bytes memory reason) {
                emit KeeperRewardFailed(reason);
            }
        }
    }

    /// @notice Bring DAX VY/asset price back to 1.9x ltvF when it exceeds 2.1x ltvF.
    function executeAcquireByMTP() external nonReentrant {
        if (execPaused) revert ExecutionPaused();
        if (block.timestamp < lastPriceDisparityTrigger + priceDisparityCooldown) {
            revert TriggerCooldownActive();
        }

        // VGO keeper-reward bracket — best effort, never blocks the cycle.
        IKeeperRewards _vgo = vgo;
        bool useVgo = address(_vgo) != address(0);
        if (useVgo) {
            try _vgo.beginReward() {} catch (bytes memory reason) {
                useVgo = false;
                emit KeeperRewardFailed(reason);
            }
        }

        ValinityCapOfficer _vco = vco;
        ValinityYieldTreasury _vyt = vyt;
        ValinityReserveTreasury _vrt = vrt;
        ValinityToken _vy = vyToken;
        IValinityDAX _dax = dax;
        address _bbo = feeRecipient;

        (
            address assetM,
            uint256 ltvFM,
            uint256 daxPriceM,
            uint256 reserveVY
        ) = _findMtpCandidate(_vco, _dax);
        if (assetM == address(0)) revert NoMtpDisparity();

        // Solve netVy for target price = 1.9 * ltvFM, then gross-up for fee.
        uint256 netVy = _solveMtpNetVy(reserveVY, daxPriceM, ltvFM);
        if (netVy == 0) revert InvalidAmount();

        uint16 feeBps = priceDisparityFeeBps;
        uint256 totalVy = (netVy * BPS_MULTIPLIER) / (BPS_MULTIPLIER - feeBps);
        if (totalVy == 0) revert InvalidAmount();

        uint256 fee = _feeOf(totalVy, feeBps);
        uint256 assetReceived = _executeCycle(
            _vyt, _vy, _dax, _vrt, _vco,
            assetM,
            assetM,
            totalVy,
            fee,
            _bbo
        );

        lastPriceDisparityTrigger = block.timestamp;
        emit Acquired(0, assetM, assetM, totalVy, fee, assetReceived);

        // Pay caller's gas refund + flat bonus. Best-effort.
        if (useVgo) {
            try _vgo.payReward(msg.sender) {} catch (bytes memory reason) {
                emit KeeperRewardFailed(reason);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE CYCLE (shared)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Pull, fee, swap, deposit, cap-raise, invariants.
     *      Asset-locked: only VY and `swapAsset` may transit the contract.
     *      On the LTV path, `capRaiseAsset` differs from `swapAsset` by design
     *      (raising the cap on the over-collateralized asset H while adding
     *      reserves to the under-collateralized asset L).
     *      On the MTP path, both are the same asset M.
     */
    function _executeCycle(
        ValinityYieldTreasury _vyt,
        ValinityToken _vy,
        IValinityDAX _dax,
        ValinityReserveTreasury _vrt,
        ValinityCapOfficer _vco,
        address swapAsset,
        address capRaiseAsset,
        uint256 totalVy,
        uint256 fee,
        address bbo
    ) internal returns (uint256 assetReceived) {
        uint256 preVyBal    = IERC20(address(_vy)).balanceOf(address(this));
        uint256 preAssetBal = IERC20(swapAsset).balanceOf(address(this));

        // 1. Pull totalVy from VYT
        _vyt.pullTokens(address(this), totalVy);

        // 2. Fee → BBO
        if (fee > 0) IERC20(address(_vy)).safeTransfer(bbo, fee);
        uint256 netVy = totalVy - fee;

        // 3. Swap netVy VY → swapAsset on Valinity DAX (MAX allowance set in init).
        //    minOut = constant-product expected output minus `swapSlippageBps`
        //    floor. Defends against sandwich attacks on the permissionless path.
        uint256 poolId = _resolvePoolId(_dax, swapAsset);
        (uint256 minOut, ) = _previewSwap(_dax, poolId, swapAsset, netVy);
        assetReceived = _dax.swapExactIn(poolId, address(_vy), netVy, minOut, address(this));
        if (assetReceived == 0) revert InvalidAmount();

        // 4. Deposit received asset → VRT
        IERC20(swapAsset).safeTransfer(address(_vrt), assetReceived);

        // 5. Raise cap by the FULL totalVy (incl. fee, per spec)
        _vco.increaseAssetCap(capRaiseAsset, totalVy);

        // 6. Closed-circuit invariants
        uint256 postVyBal    = IERC20(address(_vy)).balanceOf(address(this));
        uint256 postAssetBal = IERC20(swapAsset).balanceOf(address(this));
        if (postVyBal != preVyBal) revert InvalidVyBalance(preVyBal, postVyBal);
        if (postAssetBal > preAssetBal) revert InvalidAssetBalance(swapAsset);

        // 7. Trigger VRYO rebalance in the same transaction. Best-effort —
        //    a paused/buggy VRYO must NEVER brick acquisitions.
        IValinityReserveYieldOfficer _vryo = vryo;
        if (address(_vryo) != address(0)) {
            try _vryo.execute() {} catch (bytes memory reason) {
                emit VryoHeartbeatFailed(reason);
            }
        }
    }

    /**
     * @dev Compute (minOut, expectedOut) for the constant-product swap of
     *      `vyIn` VY into `swapAsset` on DAX pool `poolId`.
     *      minOut = expectedOut * (10_000 - swapSlippageBps) / 10_000.
     *      Pool reserves are read live; `assetIs0 == true` when asset is token0.
     */
    function _previewSwap(
        IValinityDAX _dax,
        uint256 poolId,
        address /* swapAsset */,
        uint256 vyIn
    ) internal view returns (uint256 minOut, uint256 expectedOut) {
        // DAX returns (asset, reserveVY, reserveAsset). The pool has already
        // been resolved by `_resolvePoolId` to match `swapAsset`.
        (, uint256 rVY, uint256 rAsset) = _dax.getPoolReserves(poolId);
        if (rVY == 0 || rAsset == 0) revert InsufficientOutput();
        // Constant-product expected output (no fee modelled — DAX is feeless
        // on internal officer swaps; this is intentionally conservative).
        expectedOut = Math.mulDiv(vyIn, rAsset, rVY + vyIn);
        minOut = (expectedOut * (BPS_MULTIPLIER - swapSlippageBps)) / BPS_MULTIPLIER;
    }

    /// @dev Resolve DAX poolId for asset; reverts if not registered.
    function _resolvePoolId(IValinityDAX _dax, address asset)
        internal
        view
        returns (uint256 poolId)
    {
        poolId = IValinityDAXLookup(address(_dax)).assetToPoolId(asset);
        if (poolId == 0) {
            // Disambiguate "unregistered" vs "pool 0"
            if (_dax.getNumPools() == 0) revert DaxPoolNotFound(asset);
            (address a0, , ) = _dax.getPoolReserves(0);
            if (a0 != asset) revert DaxPoolNotFound(asset);
        }
    }

    function _feeOf(uint256 amount, uint16 feeBps) internal pure returns (uint256) {
        return (amount * feeBps) / BPS_MULTIPLIER;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LTV / MTP SELECTORS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Single pass over VCO assets: track max and min ltvF (>0).
    function _findLtvExtremes(ValinityCapOfficer _vco)
        internal
        view
        returns (
            address assetH,
            uint256 ltvFH,
            uint256 capH,
            address assetL,
            uint256 ltvFL
        )
    {
        address[] memory assets_ = _vco.getAssets();
        uint256 len = assets_.length;
        uint256 lowestSeen = type(uint256).max;
        for (uint256 i; i < len; ) {
            address a = assets_[i];
            uint256 l = _vco.getAssetMetrics(a).ltvF;
            if (l != 0) {
                if (l > ltvFH) {
                    ltvFH = l;
                    assetH = a;
                    capH = _vco.getAssetCap(a);
                }
                if (l < lowestSeen) {
                    lowestSeen = l;
                    ltvFL = l;
                    assetL = a;
                }
            }
            unchecked { ++i; }
        }
    }

    /// @dev Return the first asset with daxPriceUSDPerVY >= 2.1 * ltvF.
    function _findMtpCandidate(ValinityCapOfficer _vco, IValinityDAX _dax)
        internal
        view
        returns (
            address assetM,
            uint256 ltvFM,
            uint256 daxPriceM,
            uint256 reserveVY
        )
    {
        address[] memory assets_ = _vco.getAssets();
        uint256 len = assets_.length;
        for (uint256 i; i < len; ) {
            address a = assets_[i];
            uint256 l = _vco.getAssetMetrics(a).ltvF;
            if (l != 0) {
                (uint256 rVY, uint256 rAssetNorm, uint256 pUSD) = _getDaxPriceInputs(_dax, a);
                if (rVY != 0 && rAssetNorm != 0 && pUSD != 0) {
                    uint256 dp = Math.mulDiv(rAssetNorm, pUSD, rVY);
                    if (dp * WAD >= l * MTP_TRIGGER_X) {
                        return (a, l, dp, rVY);
                    }
                }
            }
            unchecked { ++i; }
        }
    }

    /// @dev Returns (rVY, rAsset_normalized_to_18dec, priceUSD_scaled_1e18) or all zeros.
    function _getDaxPriceInputs(IValinityDAX _dax, address asset)
        internal
        view
        returns (uint256 rVY, uint256 rAssetNorm, uint256 priceUSD)
    {
        uint256 poolId;
        try IValinityDAXLookup(address(_dax)).assetToPoolId(asset) returns (uint256 p) {
            poolId = p;
        } catch {
            return (0, 0, 0);
        }
        if (poolId == 0) {
            if (_dax.getNumPools() == 0) return (0, 0, 0);
            (address a0, , ) = _dax.getPoolReserves(0);
            if (a0 != asset) return (0, 0, 0);
        }
        (, uint256 rV, uint256 rA) = _dax.getPoolReserves(poolId);
        rVY = rV;
        uint8 dec = _getAssetDecimals(asset);
        rAssetNorm = dec <= 18 ? rA * (10 ** (18 - dec)) : rA / (10 ** (dec - 18));

        // priceUSD via the TWAP getter; wrap in try to be defensive.
        try this.getAssetTwapPrice(asset) returns (uint256 px) {
            priceUSD = px;
        } catch {
            priceUSD = 0;
        }
    }

    /**
     * @dev Solve netVy s.t. post-swap marginal price equals 1.9 * ltvF on a
     *      constant-product pool.
     *
     *      newPrice = oldPrice * (rVY / (rVY + netVy))^2
     *      => netVy = rVY * (sqrt(oldPrice / newPrice) - 1)
     *
     *      Fixed-point:
     *        R     = oldPrice * 1e18 / newPrice     (scaled 1e18)
     *        sqrtR = sqrt(R * 1e18)                 (scaled 1e18, since sqrt(1e36) = 1e18)
     *        netVy = rVY * (sqrtR - 1e18) / 1e18
     */
    function _solveMtpNetVy(
        uint256 rVY,
        uint256 oldDaxPrice,
        uint256 ltvF
    ) internal pure returns (uint256 netVy) {
        uint256 newPrice = (ltvF * MTP_TARGET_X) / WAD; // 1.9 * ltvF
        if (newPrice == 0 || newPrice >= oldDaxPrice) return 0;

        uint256 ratio = Math.mulDiv(oldDaxPrice, WAD, newPrice);    // scaled 1e18
        uint256 sqrtScaled = Math.sqrt(ratio * WAD);                // scaled 1e18
        if (sqrtScaled <= WAD) return 0;

        netVy = Math.mulDiv(rVY, sqrtScaled - WAD, WAD);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TWAP ORACLE — UNCHANGED FROM V1 (consumed by VCO)
    // ═══════════════════════════════════════════════════════════════════════════

    function _getV3TwapPrice(
        address token0,
        address token1,
        uint24 fee
    ) internal view returns (uint256 price) {
        if (fee == 0) fee = DEFAULT_FEE_TIER;

        address pool = uniswapV3Factory.getPool(token0, token1, fee);
        if (pool == address(0)) revert PoolDoesNotExist();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0;
        secondsAgos[1] = DEFAULT_TWAP_INTERVAL;

        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 tickCumulativeDelta = tickCumulatives[0] - tickCumulatives[1];
        int56 twapInterval = int56(uint56(DEFAULT_TWAP_INTERVAL));
        int24 avgTick = int24(tickCumulativeDelta / twapInterval);
        if (tickCumulativeDelta < 0 && (tickCumulativeDelta % twapInterval != 0)) avgTick--;

        price = _tickToPrice(token0, token1, avgTick);
    }

    function _tickToPrice(
        address token0,
        address token1,
        int24 tick
    ) internal view returns (uint256 price) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        uint256 priceX96 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 2 ** 96);

        uint8 decimals0 = _getAssetDecimals(token0);
        uint8 decimals1 = _getAssetDecimals(token1);

        if (token0 < token1) {
            if (decimals0 >= decimals1) {
                price = Math.mulDiv(priceX96, 10 ** (18 + decimals0 - decimals1), 2 ** 96);
            } else {
                price = Math.mulDiv(priceX96, 10 ** 18, 2 ** 96 * 10 ** (decimals1 - decimals0));
            }
        } else {
            if (decimals0 >= decimals1) {
                price = Math.mulDiv(2 ** 96, 10 ** (18 + decimals0 - decimals1), priceX96);
            } else {
                price = Math.mulDiv(2 ** 96, 10 ** 18, priceX96 * 10 ** (decimals1 - decimals0));
            }
        }
    }

    function _getAssetDecimals(address asset) internal view returns (uint8) {
        try IERC20Metadata(asset).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return DEFAULT_DECIMALS;
        }
    }

    /// @notice Get TWAP price of an asset in USD (scaled 1e18). Used by VCO.
    function getAssetTwapPrice(address asset) public view returns (uint256) {
        if (asset == usdcAddress) return 1e18;

        address quoteToken = assetTwapQuoteToken[asset];
        uint24 feeTier = assetTwapFeeTier[asset];

        if (quoteToken == address(0) || quoteToken == usdcAddress) {
            return _getV3TwapPrice(asset, usdcAddress, feeTier);
        }

        uint256 priceInQuote = _getV3TwapPrice(asset, quoteToken, feeTier);
        uint24 quoteFee = quoteToken == wethAddress ? wethUsdcTwapFeeTier : DEFAULT_FEE_TIER;
        uint256 quoteInUsdc = _getV3TwapPrice(quoteToken, usdcAddress, quoteFee);
        return Math.mulDiv(priceInQuote, quoteInUsdc, 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════════

    function setDax(address newDax) external onlyRole(ADMIN_ROLE) {
        if (newDax == address(0)) revert InvalidAddress();
        address oldDax = address(dax);
        // Revoke old MAX approval and grant new, keeping per-cycle gas low.
        if (oldDax != address(0) && oldDax != newDax) {
            IERC20(address(vyToken)).forceApprove(oldDax, 0);
        }
        dax = IValinityDAX(newDax);
        IERC20(address(vyToken)).forceApprove(newDax, type(uint256).max);
        emit DaxUpdated(newDax);
    }

    function setVgo(address newVgo) external onlyRole(ADMIN_ROLE) {
        // address(0) is permitted — disables the keeper-reward bracket.
        vgo = IKeeperRewards(newVgo);
        emit VgoUpdated(newVgo);
    }

    function setSwapSlippageBps(uint16 newBps) external onlyRole(ADMIN_ROLE) {
        if (newBps == 0 || newBps > 1_000) revert SlippageTooHigh(); // 10% cap
        swapSlippageBps = newBps;
        emit SwapSlippageUpdated(newBps);
    }

    function setBuybackOfficer(address newRecipient) external onlyRole(ADMIN_ROLE) {
        if (newRecipient == address(0)) revert InvalidAddress();
        feeRecipient = newRecipient;
        emit BuybackOfficerUpdated(newRecipient);
    }

    function setVryo(address newVryo) external onlyRole(ADMIN_ROLE) {
        if (newVryo == address(0)) revert InvalidAddress();
        vryo = IValinityReserveYieldOfficer(newVryo);
        emit VryoUpdated(newVryo);
    }

    function setPaused(bool paused) external onlyRole(ADMIN_ROLE) {
        execPaused = paused;
        emit Paused(paused);
    }

    function setAssetTwapConfig(
        address asset,
        address quoteToken,
        uint24 feeTier
    ) external onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) revert InvalidAddress();
        if (feeTier != 100 && feeTier != 500 && feeTier != 3000 && feeTier != 10000) {
            revert InvalidFeeTier();
        }
        assetTwapQuoteToken[asset] = quoteToken;
        assetTwapFeeTier[asset] = feeTier;
        emit AssetTwapConfigUpdated(asset, quoteToken, feeTier);
    }

    function setWethUsdcTwapFeeTier(uint24 feeTier) external onlyRole(ADMIN_ROLE) {
        if (feeTier != 100 && feeTier != 500 && feeTier != 3000 && feeTier != 10000) {
            revert InvalidFeeTier();
        }
        wethUsdcTwapFeeTier = feeTier;
        emit WethUsdcTwapFeeTierUpdated(feeTier);
    }

    function setWethAddress(address weth) external onlyRole(ADMIN_ROLE) {
        if (weth == address(0)) revert InvalidAddress();
        wethAddress = weth;
        emit WethAddressUpdated(weth);
    }

    function setPriceDisparityFeeBps(uint16 newBps) external onlyRole(ADMIN_ROLE) {
        if (newBps > 1_000) revert FeeTooHigh(); // 10% cap
        priceDisparityFeeBps = newBps;
        emit PriceDisparityFeeUpdated(newBps);
    }

    function setLTVDisparityFeeBps(uint16 newBps) external onlyRole(ADMIN_ROLE) {
        if (newBps > 1_000) revert FeeTooHigh();
        ltvDisparityFeeBps = newBps;
        emit LTVDisparityFeeUpdated(newBps);
    }

    function setPriceDisparityCooldown(uint32 newCooldown) external onlyRole(ADMIN_ROLE) {
        if (newCooldown > MAX_COOLDOWN) revert CooldownTooLong();
        priceDisparityCooldown = newCooldown;
        emit PriceDisparityCooldownUpdated(newCooldown);
    }

    function setLTVDisparityCooldown(uint32 newCooldown) external onlyRole(ADMIN_ROLE) {
        if (newCooldown > MAX_COOLDOWN) revert CooldownTooLong();
        ltvDisparityCooldown = newCooldown;
        emit LTVDisparityCooldownUpdated(newCooldown);
    }

    /// @notice Admin rescue. VY is blocked — it must only flow VYT→DAX→… or to BBO.
    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (token == address(vyToken)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal override onlyRole(ADMIN_ROLE) {}
}
