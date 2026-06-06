// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {TickMathWrapper as TickMath} from "../library/TickMathWrapper.sol";
import {V3LiquidityMath} from "../library/V3LiquidityMath.sol";
import {V3ZapMath} from "../library/V3ZapMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V3PositionValue} from "../library/V3PositionValue.sol";
import {V3SnapbackGate} from "../library/V3SnapbackGate.sol";
import {IKeeperRewards} from "../interfaces/IKeeperRewards.sol";
import {
    PositionSnapshot,
    pairKeyOf,
    IValinityReserveTreasury
} from "../interfaces/IValinityPositions.sol";

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function burn(uint256 tokenId) external payable;
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

/**
 * @title ValinityLiquidityManager (VLM)
 * @notice Sole author of Uniswap V3 positions for the Valinity system. Mints NFTs
 *         directly to VRT (permanent owner), operates on them as an NPM-approved
 *         operator (no NFT transfers into VLM), and maintains a fresh
 *         `PositionSnapshot` in VRT per pair.
 * @dev Bands are ASYMMETRIC: `lowerRangeBps` and `upperRangeBps` are independent
 *      half-widths in basis points of PRICE. The resulting band is
 *      `[P·(1 − lowerRangeBps/10000), P·(1 + upperRangeBps/10000)]`, converted to
 *      ticks via `TickMath.getTickAtSqrtRatio` and aligned to the pool's
 *      `tickSpacing`. Setting `lowerRangeBps == upperRangeBps` reproduces the
 *      legacy symmetric behavior. Default recommended: 1000 / 1000 (±10%).
 *      Each side is bounded by the global `[MIN_RANGE_BPS, MAX_RANGE_BPS]`.
 */
contract ValinityLiquidityManager is
    UUPSUpgradeable,
    AccessControl,
    ReentrancyGuardTransient,
    Initializable,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16  public constant ABSOLUTE_MAX_SLIPPAGE_BPS = 500;
    uint32  public constant ABSOLUTE_MIN_REBALANCE_INTERVAL = 5 minutes;
    uint16  public constant MIN_RANGE_BPS = 50;      // 0.5%
    uint16  public constant MAX_RANGE_BPS = 1000;    // 10%

    /// @notice Default TWAP window (seconds) used for sandwich-deviation guard.
    uint32  public constant DEFAULT_TWAP_INTERVAL = 1800;     // 30 min
    /// @notice Absolute lower bound on configurable TWAP window — 1 minute.
    uint32  public constant MIN_TWAP_INTERVAL     = 60;
    /// @notice Absolute upper bound on configurable TWAP window — 1 day.
    uint32  public constant MAX_TWAP_INTERVAL     = 1 days;
    /// @notice Default max |slot0 tick − TWAP tick|. 1 tick ≈ 1 bp price → 300 = ±3%.
    uint16  public constant DEFAULT_MAX_TICK_DEVIATION_BPS = 300;
    /// @notice Hard ceiling on configurable deviation (10% — looser than this is unsafe).
    uint16  public constant MAX_ALLOWED_TICK_DEVIATION_BPS = 1000;

    /// @dev Storage variables — set in `initialize`. Were `immutable` in the
    ///      pre-upgradeable (V1) deployment; demoted to storage to support
    ///      UUPS proxy redeploy. New deployments are behind an ERC1967 proxy.
    IValinityReserveTreasury public vrt;
    INonfungiblePositionManager public npm;
    IUniswapV3Factory public factory;
    /// @notice Uniswap V3 SwapRouter (e.g. SwapRouter02). Used to balance
    ///         `needsZap` pairs on mint/rebalance and to convert counterparty
    ///         (unmanaged) tokens back into the managed reserve before
    ///         returning value to VRT.
    ISwapRouter public swapRouter;

    struct PairConfig {
        address pool;
        uint24  fee;
        int24   tickSpacing;
        uint16  lowerRangeBps;
        uint16  upperRangeBps;
        address token0;
        uint32  minRefreshInterval;
        uint32  minRebalanceInterval;
        uint16  mintSlippageBps;
        uint16  closeSlippageBps;
        address token1;
        uint256 seedAmount0;
        uint256 seedAmount1;
        /// @notice The pair's managed reserve asset. Must equal token0 or token1
        ///         when `needsZap == true`. Set to address(0) for pairs whose
        ///         BOTH sides are managed reserves (e.g. WETH/WBTC).
        address managedReserve;
        /// @notice True when one side of the pair is an unmanaged token (e.g.
        ///         USDC for the PAXG/USDC pair). Triggers a zap swap on mint
        ///         (managed -> counterparty) and on close (counterparty ->
        ///         managed) so VRT only ever receives `managedReserve`.
        bool    needsZap;
        /// @notice Slippage cap (bps) for zap swaps on this pair. Bounded by
        ///         `ABSOLUTE_MAX_SLIPPAGE_BPS`. Ignored when `needsZap` is false.
        uint16  zapSlippageBps;
    }

    mapping(bytes32 pairKey => PairConfig) public pairConfig;
    mapping(bytes32 pairKey => uint256) public activeTokenId;
    mapping(bytes32 pairKey => uint64)  public lastRefreshAt;
    mapping(bytes32 pairKey => uint64)  public lastRebalanceAt;

    /// @dev Per-pair one-shot seed authorization. Set on first successful
    ///      `mintPosition`; with `reauthorizeSeed` removed in V3, this flag
    ///      can never be reset — initial seed is permanent. Defense-in-depth
    ///      against repeated VRT pulls.
    mapping(bytes32 pairKey => bool) internal seedConsumed;

    bool public paused;

    /// @dev TWAP window used by `_assertTwapAligned` (seconds).
    uint32 internal twapInterval;
    /// @dev Max |slot0 tick − TWAP tick| permitted. 0 = guard disabled.
    uint16 internal maxTickDeviationBps;

    /// @dev Deprecated storage slot — was the per-pair `bandBounds` mapping
    ///      (V2). Removed in V3. Slot is reserved (mappings only consume the
    ///      single declaration slot for layout purposes; their data lives at
    ///      keccak-derived addresses) so the OZ storage-layout validator
    ///      stays aligned across the upgrade. Do NOT repurpose without a
    ///      storage migration.
    mapping(bytes32 => bytes32) private __deprecated_bandBounds;

    // -------- V3 (snapback-home) appended storage --------
    // Appended at the end of storage; each slot below consumes one entry
    // from `__gap` so prior V1/V2 slot positions are preserved. Set by
    // admin post-upgrade via `setSnapbackPairs` / `setSnapbackParams`.

    /// @dev Permissionless snapback eligibility set: at most two pair keys.
    ///      `bytes32(0)` slots are ignored. Read via `snapbackConfig()`.
    bytes32 internal _snapbackPairA;
    bytes32 internal _snapbackPairB;
    /// @dev Symmetric half-width (bps) and cooldown (sec) for `snapbackHome`.
    ///      Packed into one storage slot. Read via `snapbackConfig()`.
    uint16  internal _snapbackDefaultBps;
    uint32  internal _snapbackCooldown;

    // -------- V4 (permissionless + economic gate) appended storage --------
    // Consumes 2 slots out of `__gap`. Set post-upgrade by admin via
    // `setVgo` / `setVryo` / `setNearBandBps`. Until set, snapback degrades
    // safely: VGO calls are skipped, no caller is treated as VRYO, and
    // `nearBandBps == 0` disables the near-band override (only OOR or
    // economically-positive cycles execute).

    /// @notice Gas-officer used to refund + reward permissionless callers of
    ///         `snapbackHome`. Skipped (no revert) when unset OR when the
    ///         caller is the registered VRYO (whose own keeper already paid).
    IKeeperRewards public vgo;
    /// @notice ValinityReserveYieldOfficer. When `msg.sender == vryo`, the
    ///         VGO bracket is skipped to avoid double-paying the keeper that
    ///         already kicked off the VRYO cycle.
    address public vryo;
    /// @notice Near-band tolerance. The inner `nearBandBps/10_000` of each
    ///         half-width counts as "near a band" — when spot is inside the
    ///         live range but within this distance of the nearest band the
    ///         economic gate is bypassed (we proactively re-center). Default
    ///         recommended post-upgrade: 2500 (25% of the half-width).
    ///         Bounded by `[100, 5000]` on every write.
    uint16  public nearBandBps;

    event PairConfigured(
        bytes32 indexed pairKey,
        address poolAddress,
        uint24 fee,
        uint16 lowerRangeBps,
        uint16 upperRangeBps,
        uint32 minRefreshInterval,
        uint32 minRebalanceInterval,
        uint256 seedAmount0,
        uint256 seedAmount1
    );
    event RangeBpsUpdated(bytes32 indexed pairKey, uint16 oldRangeBps, uint16 newRangeBps);
    event SlippageUpdated(bytes32 indexed pairKey, uint16 mintSlippageBps, uint16 closeSlippageBps);
    event PositionMinted(
        bytes32 indexed pairKey,
        uint256 indexed tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event PositionRebalanced(
        bytes32 indexed pairKey,
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        int24 newTickLower,
        int24 newTickUpper,
        uint128 newLiquidity
    );
    event PositionBurned(bytes32 indexed pairKey, uint256 indexed tokenId);
    event SnapshotRefreshed(
        bytes32 indexed pairKey,
        uint256 tokenId,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        bool inRange,
        uint64 updatedAt
    );
    event PausedUpdated(bool paused);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event SnapbackPairsUpdated(bytes32 pairA, bytes32 pairB);
    event SnapbackDefaultBpsUpdated(uint16 newBps);
    event SnapbackCooldownUpdated(uint32 newSeconds);
    event SnapbackExecuted(bytes32 indexed pairKey, address indexed caller, uint256 indexed newTokenId);
    event SnapbackSkippedUneconomic(bytes32 indexed pairKey, uint256 yieldMgd, uint256 costMgd);
    event SnapbackSkippedPaused();
    event SnapbackSkippedCooldown();
    event SnapbackSkippedTwap(bytes32 indexed pairKey);
    event SnapbackV4ConfigUpdated(address vgo, address vryo, uint16 nearBandBps);
    event KeeperRewardFailed(bytes reason);

    error InvalidAddress();
    error InvalidPool();
    error PairAlreadyActive();
    error PairNotConfigured();
    error NoActivePosition();
    error InvalidRangeWidth();
    error InvalidInterval();
    error InvalidSlippage();
    error ExecutionPaused();
    error RebalanceThrottled();
    error NotNPM();
    error UnexpectedNFT();
    error EmptyFunding();
    error SeedAlreadyConsumed();
    error InvalidNearBand();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Proxy initializer. Replaces the V1 (non-upgradeable) constructor
    ///         and is callable exactly once per proxy.
    function initialize(
        address admin_,
        address vrt_,
        address npm_,
        address factory_,
        address swapRouter_
    ) external initializer {
        if (admin_ == address(0)) revert InvalidAddress();
        if (vrt_ == address(0)) revert InvalidAddress();
        if (npm_ == address(0)) revert InvalidAddress();
        if (factory_ == address(0)) revert InvalidAddress();
        if (swapRouter_ == address(0)) revert InvalidAddress();

        vrt = IValinityReserveTreasury(vrt_);
        npm = INonfungiblePositionManager(npm_);
        factory = IUniswapV3Factory(factory_);
        swapRouter = ISwapRouter(swapRouter_);

        twapInterval = DEFAULT_TWAP_INTERVAL;
        maxTickDeviationBps = DEFAULT_MAX_TICK_DEVIATION_BPS;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _setRoleAdmin(ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
    }

    /// @notice UUPS upgrade authorization. Only `ADMIN_ROLE` may upgrade the
    ///         implementation behind this proxy.
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {}

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(npm)) revert NotNPM();
        revert UnexpectedNFT();
    }

    // admin --------------------------------------------------------------

    function configurePair(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint16 lowerRangeBps_,
        uint16 upperRangeBps_,
        uint32 minRefreshInterval_,
        uint32 minRebalanceInterval_,
        uint16 mintSlippageBps_,
        uint16 closeSlippageBps_,
        uint256 seedAmount0_,
        uint256 seedAmount1_,
        address managedReserve_,
        uint16 zapSlippageBps_
    ) external onlyRole(ADMIN_ROLE) {
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) revert InvalidAddress();

        bytes32 key = pairKeyOf(tokenA, tokenB);
        if (activeTokenId[key] != 0) revert PairAlreadyActive();
        _checkSlippage(mintSlippageBps_);
        _checkSlippage(closeSlippageBps_);
        _checkSlippage(zapSlippageBps_);
        if (minRebalanceInterval_ < ABSOLUTE_MIN_REBALANCE_INTERVAL) revert InvalidInterval();
        if (minRefreshInterval_ == 0 || minRefreshInterval_ >= minRebalanceInterval_) revert InvalidInterval();
        if (lowerRangeBps_ < MIN_RANGE_BPS || lowerRangeBps_ > MAX_RANGE_BPS) revert InvalidRangeWidth();
        if (upperRangeBps_ < MIN_RANGE_BPS || upperRangeBps_ > MAX_RANGE_BPS) revert InvalidRangeWidth();

        address pool = factory.getPool(tokenA, tokenB, fee);
        if (pool == address(0)) revert InvalidPool();

        IUniswapV3Pool p = IUniswapV3Pool(pool);
        address t0 = p.token0();
        address t1 = p.token1();
        int24 ts = p.tickSpacing();
        if (ts == 0) revert InvalidPool();

        // Validate managedReserve: either zero (both sides managed) or one of
        // the pair's tokens. needsZap is derived: any non-zero managedReserve
        // means VLM must keep counterparty out of VRT via zap swaps.
        bool needsZap_ = (managedReserve_ != address(0));
        if (needsZap_) {
            if (managedReserve_ != t0 && managedReserve_ != t1) revert InvalidAddress();
        }

        pairConfig[key] = PairConfig({
            pool: pool,
            fee: fee,
            tickSpacing: ts,
            lowerRangeBps: lowerRangeBps_,
            upperRangeBps: upperRangeBps_,
            token0: t0,
            minRefreshInterval: minRefreshInterval_,
            minRebalanceInterval: minRebalanceInterval_,
            mintSlippageBps: mintSlippageBps_,
            closeSlippageBps: closeSlippageBps_,
            token1: t1,
            seedAmount0: seedAmount0_,
            seedAmount1: seedAmount1_,
            managedReserve: managedReserve_,
            needsZap: needsZap_,
            zapSlippageBps: zapSlippageBps_
        });

        emit PairConfigured(
            key, pool, fee, lowerRangeBps_, upperRangeBps_,
            minRefreshInterval_, minRebalanceInterval_,
            seedAmount0_, seedAmount1_
        );
        emit SlippageUpdated(key, mintSlippageBps_, closeSlippageBps_);
    }

    /// @notice Symmetric range setter — updates both `lowerRangeBps` and
    ///         `upperRangeBps` to `newRangeBps`. Takes effect on the NEXT
    ///         mint/rebalance; existing position is not moved.
    /// @dev Admin-only in V4. The V3 KEEPER_ROLE branch and the role itself
    ///      have been removed along with the keeper-driven rebalance paths.
    function setRangeBps(bytes32 pairKey, uint16 newRangeBps) external onlyRole(ADMIN_ROLE) {
        _setRangeBpsUnchecked(pairKey, newRangeBps);
    }

    /// @dev Role-unchecked core. Callers MUST gate access externally.
    ///      Used by `snapbackHome` (permissionless-by-design — the snapback
    ///      cooldown + economic gate are the safety boundary, not a role).
    function _setRangeBpsUnchecked(bytes32 pairKey, uint16 newRangeBps) internal {
        PairConfig storage cfg = pairConfig[pairKey];
        if (cfg.pool == address(0)) revert PairNotConfigured();
        if (newRangeBps < MIN_RANGE_BPS || newRangeBps > MAX_RANGE_BPS) revert InvalidRangeWidth();

        uint16 oldRange = cfg.lowerRangeBps; // symmetric: lower == upper
        cfg.lowerRangeBps = newRangeBps;
        cfg.upperRangeBps = newRangeBps;

        emit RangeBpsUpdated(pairKey, oldRange, newRangeBps);
    }

    function _checkSlippage(uint16 bps) private pure {
        if (bps > ABSOLUTE_MAX_SLIPPAGE_BPS) revert InvalidSlippage();
    }

    function setSlippage(bytes32 pairKey, uint16 mintSlippageBps_, uint16 closeSlippageBps_)
        external
        onlyRole(ADMIN_ROLE)
    {
        PairConfig storage cfg = pairConfig[pairKey];
        if (cfg.pool == address(0)) revert PairNotConfigured();
        _checkSlippage(mintSlippageBps_);
        _checkSlippage(closeSlippageBps_);
        cfg.mintSlippageBps = mintSlippageBps_;
        cfg.closeSlippageBps = closeSlippageBps_;
        emit SlippageUpdated(pairKey, mintSlippageBps_, closeSlippageBps_);
    }

    function setPaused(bool p_) external onlyRole(ADMIN_ROLE) {
        paused = p_;
        emit PausedUpdated(p_);
    }

    function rescueTokens(address token, address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    // lifecycle ----------------------------------------------------------

    function mintPosition(bytes32 pairKey, bool useCurrentTick, int24 centerTick)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity)
    {
        if (paused) revert ExecutionPaused();
        PairConfig storage cfg = pairConfig[pairKey];
        if (cfg.pool == address(0)) revert PairNotConfigured();
        if (activeTokenId[pairKey] != 0) revert PairAlreadyActive();
        if (seedConsumed[pairKey]) revert SeedAlreadyConsumed();

        (uint256 got0, uint256 got1) = vrt.fundLiquidityManager(
            pairKey,
            cfg.seedAmount0,
            cfg.seedAmount1
        );
        if (got0 == 0 && got1 == 0) revert EmptyFunding();

        // Mark seed consumed BEFORE any external interaction with NPM. Even
        // if a downstream call somehow fails open (it cannot — nonReentrant +
        // explicit reverts — but defense-in-depth) the authorization is
        // already burned and a fresh `reauthorizeSeed` is required.
        seedConsumed[pairKey] = true;

        // Sandwich guard: TWAP-aligned for both centerTick selection (when
        // `useCurrentTick`) AND the upcoming zap swap (which always reads
        // live `slot0` regardless of how the range was selected). Asserting
        // unconditionally closes the `useCurrentTick=false + needsZap`
        // sandwich vector.
        _assertTwapAligned(cfg);

        (int24 tickLower, int24 tickUpper) = _computeTicks(cfg, useCurrentTick, centerTick);

        // Pre-mint balancing zap. For `needsZap` pairs (single-sided seed
        // from VRT) the closed-form helper computes the one-sided swap into
        // the configured range. Dual-managed pairs (e.g. WETH/WBTC) are
        // seeded in pre-balanced amounts, so just read raw balances.
        uint256 amt0;
        uint256 amt1;
        if (cfg.needsZap) {
            (amt0, amt1) = _zapForRebalance(cfg, tickLower, tickUpper);
        } else {
            amt0 = IERC20(cfg.token0).balanceOf(address(this));
            amt1 = IERC20(cfg.token1).balanceOf(address(this));
        }
        if (amt0 == 0 && amt1 == 0) revert EmptyFunding();

        uint256 used0;
        uint256 used1;
        (tokenId, liquidity, used0, used1) = _mint(cfg, tickLower, tickUpper, amt0, amt1);

        // Register the freshly-minted NFT with VRT BEFORE writing its snapshot.
        vrt.receiveV3Position(pairKey, tokenId);

        activeTokenId[pairKey] = tokenId;
        lastRebalanceAt[pairKey] = uint64(block.timestamp);

        _sweepManagedToVRT(cfg);

        _writeSnapshot(pairKey, cfg, tokenId, tickLower, tickUpper);

        emit PositionMinted(pairKey, tokenId, tickLower, tickUpper, liquidity, used0, used1);
    }

    // -------- Keeper-driven rebalance paths REMOVED in V4 ----------------
    // `rebalanceToCurrent(bytes32)` and `rebalanceToCurrentWithRange(bytes32,uint16)`
    // were removed: the system is now permissionless via `snapbackHome()`.
    // Use `adminRebalance` for emergencies. `KEEPER_ROLE` is also fully
    // removed (constant + setRoleAdmin) in V4 — any prior grants are inert
    // and can be revoked off-chain by the admin for cosmetic cleanup.

    function adminRebalance(bytes32 pairKey, bool useCurrentTick, int24 centerTick)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        returns (uint256 newTokenId)
    {
        return _rebalance(pairKey, useCurrentTick, centerTick, true);
    }

    // -------- Snapback-home (V3) ----------------------------------------

    /// @notice Admin: register the (up to two) pair keys eligible for
    ///         permissionless `snapbackHome()`. Set a slot to `bytes32(0)`
    ///         to disable that slot. Each non-zero slot MUST already be
    ///         configured via `configurePair`. Setting the same key in both
    ///         slots is rejected (would skew rotation).
    function setSnapbackPairs(bytes32 pairA_, bytes32 pairB_) external onlyRole(ADMIN_ROLE) {
        _snapbackPairA = pairA_;
        _snapbackPairB = pairB_;
        emit SnapbackPairsUpdated(pairA_, pairB_);
    }

    /// @notice Admin: snapback default half-width (bps) and cooldown (sec).
    ///         Pass `0` for either to skip updating that field. Bps bounded
    ///         by `[MIN_RANGE_BPS, MAX_RANGE_BPS]`; seconds by `[1h, 30d]`.
    function setSnapbackParams(uint16 newBps, uint32 newSeconds) external onlyRole(ADMIN_ROLE) {
        if (newBps != 0) {
            if (newBps < MIN_RANGE_BPS || newBps > MAX_RANGE_BPS) revert InvalidRangeWidth();
            _snapbackDefaultBps = newBps;
            emit SnapbackDefaultBpsUpdated(newBps);
        }
        if (newSeconds != 0) {
            if (newSeconds < 1 hours || newSeconds > 30 days) revert InvalidInterval();
            _snapbackCooldown = newSeconds;
            emit SnapbackCooldownUpdated(newSeconds);
        }
    }

    /// @notice View: current snapback configuration. Returns the two
    ///         registered pair keys (zeroes when unset), the default
    ///         symmetric half-width (bps), and the cooldown (seconds).
    function snapbackConfig()
        external
        view
        returns (bytes32 pairA, bytes32 pairB, uint16 defaultBps, uint32 cooldown)
    {
        return (_snapbackPairA, _snapbackPairB, _snapbackDefaultBps, _snapbackCooldown);
    }

    /// @notice Permissionless re-center with on-chain economic gate.
    /// @dev    V4 rules (silent-skip semantics — never reverts on the
    ///         "no-op" path, so VRYO's `try/catch` treats a skipped run as
    ///         a no-op and does not burn its allowance):
    ///           1. `paused` → revert.
    ///           2. Pick the cooldown-eligible registered pair with the
    ///              OLDEST `lastRebalanceAt`. None eligible → emit
    ///              `SnapbackSkippedCooldown` and return.
    ///           3. Run the TWAP-deviation guard on the chosen pair. If the
    ///              pool's spot has drifted from TWAP beyond
    ///              `maxTickDeviationBps` we revert via `_assertTwapAligned`
    ///              so the rebalance can never execute on a manipulated
    ///              pool (VRYO's `try/catch` absorbs this).
    ///           4. Eligibility = `!inRange || nearBand || (Y >= C)` where
    ///                 Y = position fees (token0+token1) normalized to the
    ///                     pair's managed reserve at the TWAP price,
    ///                 S = swap-leg sizing returned by
    ///                     `V3ZapMath.computeRebalanceSwap` at the NEW range
    ///                     center, expressed in managed-reserve units,
    ///                 costBps = poolFeeBps + zapSlippageBps,
    ///                 C = S * costBps / 10_000.
    ///              `nearBand` = spot is inside the range but within
    ///              `nearBandBps/10_000` of either band (proactive
    ///              re-center). Not eligible → emit
    ///              `SnapbackSkippedUneconomic` and return.
    ///           5. Reward path: when `msg.sender != vryo`, bracket the
    ///              rebalance with `vgo.beginReward()` / `vgo.payReward(...)`
    ///              so the caller is reimbursed for gas + flat bonus.
    ///              `payReward` is wrapped in `try/catch` so a paused VGO
    ///              never bricks the snapback. When `vgo` is unset both
    ///              calls are skipped.
    /// @return pairKey     The pair that was snapped back, or `bytes32(0)`
    ///                     when the call was silent-skipped.
    /// @return newTokenId  Token id of the new position, or `0` on skip.
    function snapbackHome()
        external
        nonReentrant
        returns (bytes32 pairKey, uint256 newTokenId)
    {
        // V4.1: Silent-skip on `paused` so VRYO's permissionless poke pays no
        // try/catch revert overhead during planned maintenance windows.
        if (paused) {
            emit SnapbackSkippedPaused();
            return (bytes32(0), 0);
        }

        // ---- 1. Cooldown filter: pick the oldest eligible pair ----
        uint32 cd = _snapbackCooldown;
        uint64 limit = uint64(block.timestamp - cd); // safe: cd ≤ 30d ≪ now
        bytes32 chosen;
        uint64  chosenLast = type(uint64).max;
        {
            bytes32 a = _snapbackPairA;
            if (a != bytes32(0) && activeTokenId[a] != 0) {
                uint64 la = lastRebalanceAt[a];
                if (la <= limit) { chosen = a; chosenLast = la; }
            }
            bytes32 b = _snapbackPairB;
            if (b != bytes32(0) && activeTokenId[b] != 0) {
                uint64 lb = lastRebalanceAt[b];
                if (lb <= limit && lb < chosenLast) { chosen = b; }
            }
        }
        if (chosen == bytes32(0)) {
            emit SnapbackSkippedCooldown();
            return (bytes32(0), 0);
        }

        // ---- 1b. TWAP-deviation pre-check (silent skip on fail) ----
        //         Without this precheck a misaligned pool would trip the same
        //         guard inside `_closePosition`, AFTER `_setRangeBpsUnchecked`
        //         storage writes and the start of `_rebalance` had already
        //         burned gas. Running the staticcall here keeps the rejected
        //         path O(2k gas) instead of O(80k+).
        try this.assertTwapAligned(chosen) {
            // aligned — proceed
        } catch {
            emit SnapbackSkippedTwap(chosen);
            return (bytes32(0), 0);
        }

        // ---- 2. Economic eligibility gate (TWAP-only math, no slot0 read) ----
        //         The slot0-vs-TWAP deviation guard is run inside
        //         `_closePosition` once the rebalance starts — no need to
        //         duplicate it here for the rejected (skip) path which never
        //         touches state.
        (bool allow, uint256 Y, uint256 C, , ) = _checkSnapbackEligible(chosen);
        if (!allow) {
            emit SnapbackSkippedUneconomic(chosen, Y, C);
            return (bytes32(0), 0);
        }

        // ---- 3. Open VGO reward bracket (skipped for VRYO / unset VGO) ----
        //         Best-effort: VGO misconfiguration (missing role on this
        //         contract, paused VGO, etc.) MUST NOT block a rebalance.
        //         If `beginReward` reverts we proceed without a bracket and
        //         `useVgo` is flipped off so the symmetric `payReward` call
        //         is skipped (the bracket never opened, paying would revert).
        IKeeperRewards _vgo = vgo;
        bool useVgo = (msg.sender != vryo) && (address(_vgo) != address(0));
        if (useVgo) {
            try _vgo.beginReward() {
                // bracket open
            } catch (bytes memory reason) {
                useVgo = false;
                emit KeeperRewardFailed(reason);
            }
        }

        // ---- 4. Execute rebalance (TWAP-deviation guard runs in _closePosition) ----
        uint16 dflt = _snapbackDefaultBps;
        _setRangeBpsUnchecked(chosen, dflt);
        newTokenId = _rebalance(chosen, true, 0, true);
        pairKey = chosen;
        emit SnapbackExecuted(chosen, msg.sender, newTokenId);

        // ---- 6. Pay reward (best-effort) ----
        if (useVgo) {
            try _vgo.payReward(msg.sender) {
                // paid — caller got gas refund + flat bonus
            } catch (bytes memory reason) {
                emit KeeperRewardFailed(reason);
            }
        }
    }

    /// @notice View: simulate the economic gate for a permissionless caller.
    /// @dev Does NOT run the cooldown filter, the TWAP-deviation guard, or
    ///      the `paused` check — pure preview of the yield-vs-cost decision
    ///      for the registered pair with the oldest `lastRebalanceAt` (the
    ///      one `snapbackHome()` would pick when cooldown is met). Returns
    ///      `pair == bytes32(0)` when no registered pair has an active
    ///      position.
    /// @return pair        Pair that would be chosen.
    /// @return eligible    `!inRange || nearBand || (yieldMgd >= costMgd)`.
    /// @return yieldMgd    Pending fees (token0+token1) in managed-reserve units.
    /// @return costMgd     Estimated swap cost in managed-reserve units.
    /// @return nearBand    Spot is inside-range but within `nearBandBps` of a band.
    /// @return inRange     Spot is inside `[tickLower, tickUpper]`.
    function previewSnapback()
        external
        view
        returns (
            bytes32 pair,
            bool eligible,
            uint256 yieldMgd,
            uint256 costMgd,
            bool nearBand,
            bool inRange
        )
    {
        bytes32 a = _snapbackPairA;
        bytes32 b = _snapbackPairB;
        uint64 lastA = (a != bytes32(0) && activeTokenId[a] != 0)
            ? lastRebalanceAt[a] : type(uint64).max;
        uint64 lastB = (b != bytes32(0) && activeTokenId[b] != 0)
            ? lastRebalanceAt[b] : type(uint64).max;
        if (lastA == type(uint64).max && lastB == type(uint64).max) {
            return (bytes32(0), false, 0, 0, false, false);
        }
        pair = (lastA <= lastB) ? a : b;
        (eligible, yieldMgd, costMgd, nearBand, inRange) = _checkSnapbackEligible(pair);
    }

    // -------- Snapback admin setter (V4) --------------------------------

    /// @notice Admin: batched V4 setter. Each field uses a sentinel to skip:
    ///         `newVgo == address(this)` → leave `vgo` unchanged,
    ///         `newVryo == address(this)` → leave `vryo` unchanged,
    ///         `newNearBandBps == 0`     → leave `nearBandBps` unchanged.
    ///         Pass `address(0)` for `newVgo` to actively DISABLE the
    ///         reward bracket; `nearBandBps` is otherwise bounded by
    ///         `[100, 5000]` (1% .. 50% of half-width).
    function setSnapbackV4(address newVgo, address newVryo, uint16 newNearBandBps)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (newVgo  != address(this)) { vgo  = IKeeperRewards(newVgo); }
        if (newVryo != address(this)) { vryo = newVryo; }
        if (newNearBandBps != 0) {
            if (newNearBandBps < 100 || newNearBandBps > 5000) revert InvalidNearBand();
            nearBandBps = newNearBandBps;
        }
        emit SnapbackV4ConfigUpdated(address(vgo), vryo, nearBandBps);
    }

    // -------- Eligibility math (V4) -------------------------------------

    /// @dev Thin wrapper around `V3SnapbackGate.check` (deployed as an
    ///      external library to keep VLM bytecode under 24 KiB). Marshals
    ///      pair config into the library's input struct and forwards.
    function _checkSnapbackEligible(bytes32 pairKey)
        internal
        view
        returns (bool allow, uint256 yieldMgd, uint256 costMgd, bool nearBand, bool inRange)
    {
        PairConfig storage cfg = pairConfig[pairKey];
        address mgd = cfg.managedReserve;
        return V3SnapbackGate.check(
            V3SnapbackGate.Inputs({
                npm:             address(npm),
                pool:            cfg.pool,
                tokenId:         activeTokenId[pairKey],
                managedIsT0:     (mgd == address(0)) || (mgd == cfg.token0),
                poolFee:         cfg.fee,
                zapSlippageBps:  cfg.zapSlippageBps,
                nearBandBps:     nearBandBps,
                twapInterval:    twapInterval
            })
        );
    }

    function burnPosition(bytes32 pairKey) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (paused) revert ExecutionPaused();
        PairConfig storage cfg = pairConfig[pairKey];
        if (cfg.pool == address(0)) revert PairNotConfigured();

        uint256 tokenId = activeTokenId[pairKey];
        if (tokenId == 0) revert NoActivePosition();

        // Full burn: convert any unmanaged counterparty (e.g. USDC on PU pair)
        // back into the managed reserve so the subsequent sweep returns only
        // managed assets to VRT.
        _closePosition(cfg, tokenId, true);
        activeTokenId[pairKey] = 0;

        uint64 nowTs = uint64(block.timestamp);
        // Clear all VRT position state (snapshot + activeTokenId + token pins).
        vrt.clearPositionSnapshot(pairKey);
        lastRefreshAt[pairKey] = nowTs;

        // Sweep any residual managed-reserve balance back to VRT. For
        // `needsZap` pairs counterparty (unmanaged) dust may remain on VLM and
        // is consumed by the next mint cycle.
        _sweepManagedToVRT(cfg);
        emit PositionBurned(pairKey, tokenId);
        emit SnapshotRefreshed(pairKey, 0, 0, 0, false, nowTs);
    }

    // snapshot -----------------------------------------------------------

    /// @notice Refreshes the canonical position snapshot stored in VRT.
    /// @dev Permissionless in V4. Idempotent on throttle: silent no-op when
    ///      called within `minRefreshInterval` of the prior refresh, so VRYO
    ///      (and anyone else) can call unconditionally before deploy /
    ///      recall. When an active position exists, runs the TWAP-deviation
    ///      guard so the canonical snapshot can never capture a manipulated
    ///      `sqrtPriceX96`.
    function refreshSnapshot(bytes32 pairKey) external nonReentrant {
        if (paused) revert ExecutionPaused();
        PairConfig storage cfg = pairConfig[pairKey];
        if (cfg.pool == address(0)) revert PairNotConfigured();

        uint64 last = lastRefreshAt[pairKey];
        if (last != 0 && block.timestamp < uint256(last) + cfg.minRefreshInterval) {
            // Idempotent: silent return so VRYO can call unconditionally.
            return;
        }

        uint256 tokenId = activeTokenId[pairKey];
        if (tokenId == 0) {
            uint64 nowTs = uint64(block.timestamp);
            vrt.clearPositionSnapshot(pairKey);
            lastRefreshAt[pairKey] = nowTs;
            emit SnapshotRefreshed(pairKey, 0, 0, 0, false, nowTs);
            return;
        }

        // Sandwich guard: never write a snapshot derived from a manipulated
        // spot price.
        _assertTwapAligned(cfg);

        (int24 tickLower, int24 tickUpper) = _activeTicks(tokenId);
        _writeSnapshot(pairKey, cfg, tokenId, tickLower, tickUpper);
    }

    // internal -----------------------------------------------------------

    function _rebalance(bytes32 pairKey, bool useCurrentTick, int24 centerTick, bool bypassCooldown)
        internal
        returns (uint256 newTokenId)
    {
        if (paused) revert ExecutionPaused();
        PairConfig storage cfg = pairConfig[pairKey];
        if (cfg.pool == address(0)) revert PairNotConfigured();

        uint256 oldTokenId = activeTokenId[pairKey];
        if (oldTokenId == 0) revert NoActivePosition();

        if (!bypassCooldown) {
            uint64 last = lastRebalanceAt[pairKey];
            if (last != 0 && block.timestamp < uint256(last) + cfg.minRebalanceInterval) {
                revert RebalanceThrottled();
            }
        }

        // In-place rebalance: close old NFT WITHOUT swapping the
        // counterparty back to the managed asset. The new range may
        // legitimately need both sides; `_zapForRebalance` below performs
        // exactly the one-directional swap needed to land at the new
        // range's ratio.
        _closePosition(cfg, oldTokenId, false);

        // BUG FIX (V2): in-place rebalance MUST NOT pull additional capital
        // from VRT. The closed position's value is already on this contract
        // (managed-reserve sweep happens via the close-side swap for needsZap
        // pairs; for dual-managed pairs the close already deposited both
        // legs onto VLM). Redeploy ONLY the close proceeds. To deploy fresh
        // capital from VRT use `mintPosition` (admin-only, bounded by
        // `cfg.seedAmount0/1`).
        //
        // Historical note: V1 called `vrt.fundLiquidityManager(pairKey,
        // type(uint256).max, type(uint256).max)` here, which drained the
        // entire pair-pinned VRT balance every cycle. That call has been
        // removed. See txs 0xdeb1a92... and 0x33bbbd31... for the on-chain
        // manifestation of the V1 bug.

        // Clear VRT's old position state so `receiveV3Position` can accept the new NFT.
        vrt.clearPositionSnapshot(pairKey);

        // TWAP-alignment guard already ran inside `_closePosition` (when
        // liquidity > 0) using the same `slot0` view. Re-asserting here
        // would cost a duplicate `slot0()` + `observe()` for no added
        // safety in the same atomic tx.

        (int24 tickLower, int24 tickUpper) = _computeTicks(cfg, useCurrentTick, centerTick);

        // Single-sided rebalance zap: swap ONLY the over-supplied side, by
        // exactly the excess amount. Never converts 100% (unless the new
        // range is fully out-of-range on one side at current price). Both
        // sides remain on VLM and feed the new mint.
        (uint256 amt0, uint256 amt1) = _zapForRebalance(cfg, tickLower, tickUpper);
        if (amt0 == 0 && amt1 == 0) revert EmptyFunding();

        uint128 newLiq;
        (newTokenId, newLiq, , ) = _mint(cfg, tickLower, tickUpper, amt0, amt1);

        // Register the new NFT with VRT BEFORE writing its snapshot.
        vrt.receiveV3Position(pairKey, newTokenId);

        activeTokenId[pairKey] = newTokenId;
        lastRebalanceAt[pairKey] = uint64(block.timestamp);

        // INVARIANT (rebalance): VLM must NOT send anything back to VRT here.
        // VRYO is the sole conduit for capital flowing between LP and VRT.
        // NPM consumes (amt0, amt1) up to the new range's ratio; sub-wei
        // rounding dust may remain on VLM and is consumed by the next
        // rebalance — it never leaves the LP system.

        _writeSnapshot(pairKey, cfg, newTokenId, tickLower, tickUpper);

        emit PositionRebalanced(pairKey, oldTokenId, newTokenId, tickLower, tickUpper, newLiq);
    }

    function _closePosition(PairConfig storage cfg, uint256 tokenId, bool swapCounterpartyOnNeedsZap) internal {
        // Single sandwich-deviation guard for the entire close path —
        // covers the decreaseLiquidity slippage min, any counterparty swap,
        // and the rebalance zap that follows in `_rebalance`. Cheaper than
        // re-asserting per-branch.
        _assertTwapAligned(cfg);
        (, , , , , int24 tL, int24 tU, uint128 liquidity, , , , ) = npm.positions(tokenId);

        if (liquidity > 0) {
            (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(cfg.pool).slot0();
            (uint256 expected0, uint256 expected1) = V3LiquidityMath.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(tL),
                TickMath.getSqrtRatioAtTick(tU),
                liquidity
            );
            uint256 denom = BPS_DENOMINATOR;
            uint256 numer = denom - cfg.closeSlippageBps;
            uint256 min0 = (expected0 * numer) / denom;
            uint256 min1 = (expected1 * numer) / denom;

            npm.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: min0,
                    amount1Min: min1,
                    deadline: block.timestamp
                })
            );
        }

        npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        npm.burn(tokenId);

        // For full burns on `needsZap` pairs (admin burnPosition path), the
        // counterparty (e.g. USDC) must be converted back into the managed
        // reserve so VRT only ever receives managed assets. For in-place
        // rebalance, the caller passes `false` because the new range may
        // legitimately need the counterparty side as well; the
        // `_zapForRebalance` step that follows handles the rebalance swap
        // in the correct direction with the exact amount.
        if (cfg.needsZap && swapCounterpartyOnNeedsZap) {
            _swapCounterpartyOut(cfg);
        }
    }

    function _mint(
        PairConfig storage cfg,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1) {
        if (amount0 > 0) IERC20(cfg.token0).forceApprove(address(npm), amount0);
        if (amount1 > 0) IERC20(cfg.token1).forceApprove(address(npm), amount1);

        (uint256 min0, uint256 min1) = _mintMins(cfg, tickLower, tickUpper, amount0, amount1);

        (tokenId, liquidity, used0, used1) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: cfg.token0,
                token1: cfg.token1,
                fee: cfg.fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: min0,
                amount1Min: min1,
                recipient: address(vrt),
                deadline: block.timestamp
            })
        );
        // Note: NPM consumes exactly `used0`/`used1` and reverts otherwise; any
        // residual allowance is overwritten on the next `forceApprove`. No
        // need to reset to 0 here.
    }

    function _mintMins(
        PairConfig storage cfg,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint256 min0, uint256 min1) {
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(cfg.pool).slot0();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);

        // Pre-compute the liquidity NPM will actually mint and the corresponding
        // expected (consumed) amounts. Applying slippage to the desired inputs
        // (the legacy approach) over-tightens the bound when the pool ratio
        // doesn't match the funding ratio, causing 'Price slippage check' reverts
        // even when execution is in fact within tolerance.
        uint128 liq = V3LiquidityMath.getLiquidityForAmounts(
            sqrtPriceX96, sqrtLower, sqrtUpper, amount0, amount1
        );
        (uint256 expected0, uint256 expected1) = V3LiquidityMath.getAmountsForLiquidity(
            sqrtPriceX96, sqrtLower, sqrtUpper, liq
        );

        uint256 denom = BPS_DENOMINATOR;
        uint256 numer = denom - cfg.mintSlippageBps;
        min0 = (expected0 * numer) / denom;
        min1 = (expected1 * numer) / denom;
    }

    function _writeSnapshot(
        bytes32 pairKey,
        PairConfig memory cfg,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 liquidity,
            uint256 fgi0Last,
            uint256 fgi1Last,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = npm.positions(tokenId);

        (uint160 sqrtPriceX96, int24 currentTick, , , , , ) = IUniswapV3Pool(cfg.pool).slot0();

        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);

        (uint256 principal0, uint256 principal1) = V3LiquidityMath.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtLower,
            sqrtUpper,
            liquidity
        );

        (uint256 feesOwed0, uint256 feesOwed1) = V3PositionValue.feesFromParams(
            cfg.pool,
            liquidity,
            tickLower,
            tickUpper,
            fgi0Last,
            fgi1Last,
            tokensOwed0,
            tokensOwed1
        );

        uint64 nowTs = uint64(block.timestamp);
        bool inRange = (currentTick >= tickLower) && (currentTick < tickUpper);

        PositionSnapshot memory snap = PositionSnapshot({
            tokenId: tokenId,
            token0: cfg.token0,
            token1: cfg.token1,
            poolAddress: cfg.pool,
            fee: cfg.fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            sqrtPriceX96: sqrtPriceX96,
            sqrtRatioLowerX96: sqrtLower,
            sqrtRatioUpperX96: sqrtUpper,
            principal0: principal0,
            principal1: principal1,
            feesOwed0: feesOwed0,
            feesOwed1: feesOwed1,
            inRange: inRange,
            updatedAt: nowTs
        });

        vrt.setPositionSnapshot(pairKey, snap);
        lastRefreshAt[pairKey] = nowTs;
        emit SnapshotRefreshed(pairKey, tokenId, sqrtPriceX96, liquidity, inRange, nowTs);
    }

    function _activeTicks(uint256 tokenId)
        internal
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        (, , , , , tickLower, tickUpper, , , , , ) = npm.positions(tokenId);
    }

    /// @notice Derive `[tickLower, tickUpper]` from the pair's asymmetric
    ///         `lowerRangeBps` / `upperRangeBps` centered on a given tick (or
    ///         the pool's live tick).
    /// @dev Converts ASYMMETRIC `−lowerRangeBps/10000` / `+upperRangeBps/10000`
    ///      price deltas into sqrt-price space, clamps to TickMath bounds, then
    ///      aligns to `tickSpacing`. Each side is computed independently.
    function _computeTicks(PairConfig storage cfg, bool useCurrentTick, int24 centerTick)
        internal
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        uint160 sqrtCenter;
        if (useCurrentTick) {
            (uint160 cur, , , , , , ) = IUniswapV3Pool(cfg.pool).slot0();
            sqrtCenter = cur;
        } else {
            sqrtCenter = TickMath.getSqrtRatioAtTick(centerTick);
        }

        uint256 lowerBps = cfg.lowerRangeBps;
        uint256 upperBps = cfg.upperRangeBps;
        // multipliers in Q96: sqrt((10000 ± bps) / 10000) * 2^96 — independent per side.
        // Bounds invariant (`MIN_RANGE_BPS ≤ bps ≤ MAX_RANGE_BPS`) is enforced on every
        // write path (`configurePair`, `_setRangeBpsUnchecked`), so no re-check here.
        uint256 mulUpperQ96 = Math.sqrt(((10_000 + upperBps) << 192) / 10_000);
        uint256 mulLowerQ96 = Math.sqrt(((10_000 - lowerBps) << 192) / 10_000);

        uint256 newUpper = Math.mulDiv(uint256(sqrtCenter), mulUpperQ96, 1 << 96);
        uint256 newLower = Math.mulDiv(uint256(sqrtCenter), mulLowerQ96, 1 << 96);

        // Clamp to valid TickMath range.
        uint256 maxSqrt = uint256(TickMath.MAX_SQRT_RATIO) - 1;
        uint256 minSqrt = uint256(TickMath.MIN_SQRT_RATIO);
        if (newUpper > maxSqrt) newUpper = maxSqrt;
        if (newLower < minSqrt) newLower = minSqrt;

        int24 rawLower = TickMath.getTickAtSqrtRatio(uint160(newLower));
        int24 rawUpper = TickMath.getTickAtSqrtRatio(uint160(newUpper));

        int24 ts = cfg.tickSpacing;
        tickLower = _floorToSpacing(rawLower, ts);
        tickUpper = _ceilToSpacing(rawUpper, ts);

        // VLM-M1: ceil/floor can push ticks one spacing past TickMath bounds.
        // Clamp back to the largest spacing-aligned tick within [MIN, MAX].
        int24 minAligned = _ceilToSpacing(TickMath.MIN_TICK, ts);
        int24 maxAligned = _floorToSpacing(TickMath.MAX_TICK, ts);
        if (tickLower < minAligned) tickLower = minAligned;
        if (tickUpper > maxAligned) tickUpper = maxAligned;

        if (tickLower >= tickUpper) {
            tickUpper = tickLower + ts;
            if (tickUpper > maxAligned) {
                tickUpper = maxAligned;
                tickLower = maxAligned - ts;
            }
        }
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed++;
        return compressed * spacing;
    }

    // ---------------------------------------------------------------- TWAP guard

    /// @notice Revert if the pool's spot tick has deviated from its TWAP by
    ///         more than `maxTickDeviationBps`. Delegates to `V3SnapbackGate`
    ///         (external library) to keep VLM under the 24 KiB deploy limit.
    ///         `maxTickDeviationBps == 0` disables the guard.
    function _assertTwapAligned(PairConfig storage cfg) internal view {
        V3SnapbackGate.assertTwapAligned(cfg.pool, twapInterval, maxTickDeviationBps);
    }

    /// @notice External TWAP-alignment check used by VRYO before deploy /
    ///         recall and by off-chain monitors. View-only; intentionally
    ///         unrestricted — read access to a deviation surface is harmless
    ///         and gating a `view` adds no safety.
    function assertTwapAligned(bytes32 pairKey) external view {
        PairConfig storage cfg = pairConfig[pairKey];
        if (cfg.pool == address(0)) revert PairNotConfigured();
        _assertTwapAligned(cfg);
    }

    function _sweepToVRT(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(address(vrt), bal);
    }

    /// @notice Sweep managed-reserve balances from VLM to VRT. For dual-managed
    ///         pairs both `token0` and `token1` are managed; for `needsZap`
    ///         pairs only the configured `managedReserve` is swept and any
    ///         counterparty (unmanaged) dust stays on VLM to be consumed by
    ///         the next mint cycle.
    function _sweepManagedToVRT(PairConfig storage cfg) internal {
        if (cfg.needsZap) {
            _sweepToVRT(cfg.managedReserve);
            return;
        }
        _sweepToVRT(cfg.token0);
        _sweepToVRT(cfg.token1);
    }

    // ---------------------------------------------------------------- ZAP

    /// @notice In-place rebalance zap. Looks at VLM's current `(bal0, bal1)`
    ///         (which is whatever the closed old NFT returned, no funding
    ///         pulled from VRT), determines which single side is
    ///         over-supplied for the NEW range, and swaps EXACTLY the
    ///         excess of that one side into the other. Never swaps 100%
    ///         unless the new range is wholly out-of-range at current price.
    /// @dev    Uses `V3ZapMath.computeRebalanceSwap` — closed-form, same
    ///         math as the deploy/recall path so accounting stays
    ///         consistent across the system.
    function _zapForRebalance(PairConfig storage cfg, int24 tickLower, int24 tickUpper)
        internal
        returns (uint256 newAmt0, uint256 newAmt1)
    {
        uint256 bal0 = IERC20(cfg.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(cfg.token1).balanceOf(address(this));

        (uint160 sqrtP, , , , , , ) = IUniswapV3Pool(cfg.pool).slot0();

        (bool zeroForOne, uint256 swapAmt) = V3ZapMath.computeRebalanceSwap(
            bal0, bal1, sqrtP,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper)
        );

        if (swapAmt == 0) return (bal0, bal1);
        // Dust-tolerance: skip swaps smaller than 1bp of the source-side
        // balance. V3 rounds fees UP, so a few-wei swap can incur an
        // effective fee far above `zapSlippageBps` and revert "Too little
        // received". The leftover imbalance is < 1bp of the LP and gets
        // consumed on the next rebalance. Divide-first form avoids any
        // multiplicative overflow risk on extreme-decimal tokens.
        if (swapAmt < (zeroForOne ? bal0 : bal1) / 10_000) return (bal0, bal1);

        _execSwap(
            zeroForOne ? cfg.token0 : cfg.token1,
            zeroForOne ? cfg.token1 : cfg.token0,
            cfg.fee,
            swapAmt,
            V3ZapMath.computeMinOut(swapAmt, zeroForOne, sqrtP, cfg.fee, cfg.zapSlippageBps)
        );

        newAmt0 = IERC20(cfg.token0).balanceOf(address(this));
        newAmt1 = IERC20(cfg.token1).balanceOf(address(this));
    }

    /// @notice Convert any counterparty balance held by VLM back into the
    ///         managed reserve. Called inside `_closePosition` for `needsZap`
    ///         pairs so VRT never receives unmanaged tokens.
    /// @dev TWAP-alignment is asserted at the top of `_closePosition` for
    ///      the entire close path; no need to re-assert here.
    function _swapCounterpartyOut(PairConfig storage cfg) internal {
        address managed = cfg.managedReserve;
        address counterparty = (managed == cfg.token0) ? cfg.token1 : cfg.token0;
        uint256 cpBal = IERC20(counterparty).balanceOf(address(this));
        if (cpBal == 0) return;

        (uint160 sqrtP, , , , , , ) = IUniswapV3Pool(cfg.pool).slot0();
        _execSwap(
            counterparty,
            managed,
            cfg.fee,
            cpBal,
            V3ZapMath.computeMinOut(cpBal, counterparty == cfg.token0, sqrtP, cfg.fee, cfg.zapSlippageBps)
        );
    }

    /// @dev Single shared swap dispatcher used by `_zapForRebalance` and
    ///      `_swapCounterpartyOut`. Consolidating the `ExactInputSingleParams`
    ///      construction here keeps deployed bytecode under the 24 KiB limit.
    function _execSwap(
        address tokenIn,
        address tokenOut,
        uint24 fee_,
        uint256 amountIn,
        uint256 minOut
    ) internal {
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               fee_,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          amountIn,
                amountOutMinimum:  minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Reserved storage to allow future versions to add new state
    ///      variables without shifting existing slots. Decrement on each
    ///      append. See OZ upgradeable docs §"Storage Gaps".
    ///      V2 appended `__deprecated_bandBounds` mapping → −1 slot.
    ///      V3 (snapback-home) appended `_snapbackPairA`, `_snapbackPairB`
    ///      and one packed slot for `_snapbackDefaultBps` + `_snapbackCooldown`
    ///      → −3 slots.
    ///      V4 (permissionless + economic gate) appended `vgo` (packed into
    ///      the leftover bytes of the V3 `_snapbackDefaultBps`/`_snapbackCooldown`
    ///      slot — 0 new slots) and a packed slot for `vryo` (20 bytes) +
    ///      `nearBandBps` (2 bytes) → −1 slot.
    uint256[34] private __gap;
}
