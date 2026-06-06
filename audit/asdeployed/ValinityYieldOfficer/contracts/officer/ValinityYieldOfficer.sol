// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IValinityToken {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IValinityYieldTreasury {
    function pullTokens(address recipient, uint256 amount) external returns (uint256 minted);
    function getBalance() external view returns (uint256);
    function getAvailableForYield() external view returns (uint256);
}

interface IValinityCapOfficer {
    function addToHighestLTVFCap(uint256 amount) external;
}

interface IStakingRouter {
    function totalStakedVY() external view returns (uint256);
}

interface IValinityReserveYieldOfficer {
    function execute() external;
}

/// @notice Read surface exposed by the Valinity Alliance Registration Officer.
///         VARO credits referrers by PULLING `totalYieldClaimedVY` (no push);
///         VYO in turn pulls VARO's protocol-wide outstanding referral debt so
///         it can earmark that VY out of the yield-distributable pool.
interface IValinityAllianceRegistrationOfficer {
    function outstandingReferralDebtVY() external view returns (uint256);
}

interface IValinityDAX {
    function swapExactIn(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    function getPoolReserves(
        uint256 poolId
    ) external view returns (address asset, uint256 reserveVY, uint256 reserveAsset);

    function assetToPoolId(address asset) external view returns (uint256);
}

interface IUniswapV2Pair {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

/**
 * @title ValinityYieldOfficer (V5)
 * @notice Yield bookkeeping + distribution for both VY stakes and asset stakes.
 *
 * @dev Master rate uses piecewise sqrt smoothing (no cliff):
 *        effective  = vsr.totalStakedVY() + totalAssetStakeVY              (Option B)
 *        freeVY     = vyt.getAvailableForYield() − totalPromisedYield
 *        usableFree = freeVY / 2          (count only 50% of free VY; other 50% = cushion)
 *        if usableFree ≥ effective  → rate = PREMIUM_MAX_BPS (9%)          (full stake covered)
 *        else                       → rate = sqrt(MAX² × usableFree / effective)
 *      Conservative coverage test: the cap binds only when usable free VY
 *      covers 100% of staked demand, i.e. freeVY ≥ 2 × effective.
 *      Rate locks at deposit, never changes for an active stake.
 *
 * Stake types & payout:
 * - VY stakes (up to 3 per user): yield earned & paid in VY.
 * - Asset stakes (unlimited): yield credited in asset units, paid in asset via
 *   VYT-sourced VY swapped through Uniswap V2 (USDC) or DAX (every other
 *   registered asset, including V-DAOs).
 *
 * Reservation model (asset stakes only):
 * - Deposit adds 2 × (principalVY + maxYieldVY) to totalPromisedYield — the 2×
 *   buffer absorbs ≤50% pool drift.
 * - Each claim decrements by the claim's gross VY-equivalent.
 * - Withdraw releases any unused buffer back to freeVY.
 *
 * Payout split (every yield event, both stake types):
 * - 90% to user (asset for asset stakes, VY for VY stakes)
 * - 5% to feeRecipient (VBBO) as VY
 * - 5% retained in VYT (ecosystem fee, never pulled)
 * - 95% pulled VY booked into VCO's highest LTV-F cap
 *
 * Premium tier: first 1,000 addresses staking ≥ 7,000 VY-equivalent in Tier 3
 * get permanent 9% premium. Granted AFTER the rate snapshot so the triggering
 * stake locks at base tier rate; future stakes get premium.
 *
 * VARO referral integration (V5): every yield claim records
 * `totalYieldClaimedVY[user] += grossVY` (VARO PULLS this to credit referrers —
 * no push). Asset yield is recorded in VY-equivalent at claim-time pool spot so
 * VARO sees a uniform unit. Each claim then syncs VARO's protocol-wide
 * `outstandingReferralDebtVY()` into the reservation basket (`totalPromisedYield`):
 * debt grew → reserve the delta, debt shrank → release it. The debt read is
 * wrapped in try/catch (no-op when VARO unset).
 *
 * Principal protection:
 * - `topUpPrincipal` (VY stakes): covers IL/slippage shortfall on VY-stake withdraw.
 * - `topUpAssetWithdrawal` (asset stakes): pulls VY, swaps to asset, delivers
 *   to VSR when LP burn + VSR's own swap can't cover principal.
 *
 * All deposit/withdraw/topUp entries are `onlyRouter`. User claims use msg.sender.
 * VARO/VRYO interactions wrapped in try/catch — a paused or misconfigured peer
 * never blocks a user claim.
 */
contract ValinityYieldOfficer is UUPSUpgradeable, AccessControl, ReentrancyGuardTransient, Initializable {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

    uint8 public constant MAX_STAKES = 3;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant ECOSYSTEM_FEE_BPS = 500; // 5% kept in ecosystem (not pulled)

    // Dynamic yield tier caps (basis points on principal for full stake duration)
    uint16 public constant PREMIUM_MAX_BPS = 900;  // 9.00% — premium tier 3 / master rate cap
    uint16 public constant TIER3_MAX_BPS = 750;     // 7.50%
    uint16 public constant TIER2_MAX_BPS = 417;     // 4.17%
    uint16 public constant TIER1_MAX_BPS = 170;     // 1.70%

    // Premium system
    uint16 public constant MAX_PREMIUM_HOLDERS = 1000;
    uint256 public constant PREMIUM_MIN_STAKE = 7_000 * 10 ** 18;

    /// @notice Fraction of free VY counted toward the master-rate coverage test
    ///         (in basis points). FREE_VY_USABLE_BPS = 5000 → only 50% of free
    ///         VY is usable; the other 50% is a permanent cushion. The cap binds
    ///         only when usable free VY covers 100% of total staked demand.
    uint16 public constant FREE_VY_USABLE_BPS = 5_000;

    // ============================================
    // CORE REFERENCES
    // ============================================

    IValinityToken public vyToken;
    IValinityYieldTreasury public vyt;
    IValinityCapOfficer public capOfficer;

    // ============================================
    // STATE VARIABLES (packed for gas efficiency)
    // ============================================

    /// @notice Fee in basis points sent to feeRecipient (default 500 = 5%)
    uint16 public feeBps;

    /// @notice Claims paused flag (emergency mechanism)
    bool public claimsPaused;

    /// @notice Address receiving fees
    address public feeRecipient;

    /// @notice Current router address (for tracking/revocation)
    address public router;

    /// @custom:deprecated Fixed yield mapping replaced by dynamic calculation. Slot preserved for UUPS.
    mapping(uint8 => uint16) private __deprecated_tierYieldBps;

    /**
     * @notice Stake structure tracking yield per user per stakeId
     * @dev Packed for gas efficiency: bool + uint8 + uint16 + 3x uint64 = 1 slot
     */
    struct Stake {
        bool active;
        uint8 tierId;
        uint16 yieldBpsSnapshot;
        uint64 startTime;
        uint64 endTime;
        uint64 lastAccrued;
        uint256 principalVY;
        uint256 pendingGross;
        uint256 grossPaidTotal;
        uint256 maxGross;
    }

    /// @notice stakes[user][stakeId] => Stake info
    mapping(address => mapping(uint8 => Stake)) public stakes;

    // ============================================
    // DYNAMIC YIELD STATE (new in V2)
    // ============================================

    /// @notice Total yield committed to existing stakes but not yet paid out
    uint256 public totalPromisedYield;

    /// @notice Number of premium holders registered
    uint16 public premiumCount;

    /// @notice Permanent premium status per address
    mapping(address => bool) public isPremium;

    /// @notice Staking router reference for reading totalStakedVY
    IStakingRouter public stakingRouter;

    // ============================================
    // V3 STORAGE (appended; never reorder above this line)
    // ============================================

    /// @notice Reserve Yield Officer (VRYO). Pinged on every claimYield to
    ///         keep VRT yield deployments aligned. Optional: when unset,
    ///         the heartbeat is skipped. Wrapped in try/catch so a misconfigured
    ///         or paused VRYO can never block user claims.
    IValinityReserveYieldOfficer public vryo;

    // ============================================
    // V4 STORAGE (asset staking — append only, never reorder)
    // ============================================
    //
    // V4 mirrors the VSR V3 asset-staking path. VSR owns LP custody; VYO owns
    // ALL yield bookkeeping for asset stakes (rate calc, accrual, VYT pulls,
    // VY→asset swaps, shortfall top-ups). USDC routes through Uniswap V2;
    // every other asset routes through the asset's DAX VY/asset pool.

    /// @notice Asset-stake yield record. Mirrors the VSR stake by (user, stakeId).
    ///         Asset-denominated fields are in the deposit asset's native units;
    ///         `reservedVY` and `principalVYAtDeposit` are in VY at the deposit
    ///         pool spot (used for VYT reservation accounting + master-rate
    ///         threshold tracking). Spot drift is accepted by design.
    struct AssetYieldStake {
        bool active;
        bool isUniLP;               // true iff asset == USDC
        uint8 tier;
        uint16 yieldBpsSnapshot;
        uint64 startTime;
        uint64 endTime;
        uint64 lastClaimTime;
        address asset;
        uint256 principalAsset;
        uint256 maxYieldAsset;
        uint256 yieldPaidAsset;
        uint256 reservedVY;             // unused portion of VY reservation
        uint256 principalVYAtDeposit;   // snapshot at deposit (for totalAssetStakeVY release)
    }

    /// @notice user => stakeId => AssetYieldStake
    mapping(address => mapping(uint256 => AssetYieldStake)) public assetYieldStakes;

    /// @notice Valinity DAX (for non-USDC asset swaps).
    IValinityDAX public dax;

    /// @notice Uniswap V2 router (for VY/USDC swaps).
    IUniswapV2Router02 public uniRouter;

    /// @notice Uniswap V2 VY/USDC pair (for quoting).
    IUniswapV2Pair public uniPair;

    /// @notice USDC token (the only Uniswap-routed asset).
    IERC20 public usdcToken;

    /// @notice True if VY is token0 in the Uniswap pair.
    bool public vyIsToken0;

    /// @notice Sum of asset-stake principal expressed in VY at deposit-spot.
    ///         Feeds the master-rate threshold via Option B:
    ///         `effectiveTotalStaked = vsr.totalStakedVY() + totalAssetStakeVY`.
    ///         Updated on `onAssetDeposit` (+=) and `onAssetWithdraw` (-=).
    uint256 public totalAssetStakeVY;

    // ============================================
    // V5 STORAGE (VARO referral integration — append only)
    // ============================================
    //
    // V5 integrates the Valinity Alliance Registration Officer. VARO credits
    // referrers by PULLING `totalYieldClaimedVY` (no push from VYO). In return
    // VYO pulls VARO's protocol-wide outstanding referral debt on every claim
    // and earmarks it inside `totalPromisedYield` so it is never re-distributed
    // as yield. `referralReservedVY` is the portion of that basket currently
    // attributed to referral debt, used to compute the reserve/release delta.

    /// @notice Valinity Alliance Registration Officer (referral accounting).
    ///         When `address(0)`, the reserve sync is a no-op. The debt read is
    ///         wrapped in try/catch so a misconfigured or paused VARO can never
    ///         block user yield claims.
    address public varo;

    /// @notice Cumulative yield (VY-denominated) claimed per user across all
    ///         stake types. For VY stakes this equals the gross yield in VY;
    ///         for asset stakes it equals the gross yield's VY-equivalent at
    ///         the time of each claim. Monotonically increasing. VARO PULLS this
    ///         to credit referrers.
    mapping(address => uint256) public totalYieldClaimedVY;

    /// @notice VY currently earmarked inside `totalPromisedYield` for VARO's
    ///         outstanding referral debt. Synced to `outstandingReferralDebtVY()`
    ///         on every claim; the difference is reserved (debt grew) or released
    ///         (debt shrank) against `totalPromisedYield`.
    uint256 public referralReservedVY;

    // ============================================
    // EVENTS
    // ============================================

    event StakeOpened(
        address indexed user,
        uint8 indexed stakeId,
        uint8 tierId,
        uint256 principalVY,
        uint64 startTime,
        uint64 endTime,
        uint16 yieldBps
    );

    event YieldPaid(
        address indexed user,
        uint8 indexed stakeId,
        uint256 gross,
        uint256 userOut,
        uint256 feeOut,
        bool stakeClosed
    );

    event PrincipalTopUp(address indexed user, uint8 indexed stakeId, uint256 amountVY);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeBpsUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event ClaimsPausedUpdated(bool paused);
    event PremiumGranted(address indexed user, uint16 premiumCount);
    event VryoUpdated(address indexed oldVryo, address indexed newVryo);
    event VryoHeartbeatFailed(bytes reason);

    // ── V4 asset-stake events ─────────────────────────────────────────────
    event AssetStakeOpened(
        address indexed user,
        uint256 indexed stakeId,
        address indexed asset,
        uint256 principalAsset,
        uint8 tier,
        uint16 yieldBps,
        uint256 maxYieldAsset
    );
    event AssetYieldPaid(
        address indexed user,
        uint256 indexed stakeId,
        address indexed asset,
        uint256 assetOut,
        uint256 vyPulled,
        bool stakeClosed
    );
    event AssetTopUp(address indexed asset, uint256 shortfall, uint256 vyPulled, address recipient);
    event DaxUpdated(address indexed newDax);
    event UniRouterUpdated(address indexed newRouter);

    // ── V5 VARO referral integration ──────────────────────────────────────
    event VaroUpdated(address indexed oldVaro, address indexed newVaro);
    event VaroReserveSyncFailed(bytes reason);
    event YieldClaimedVY(address indexed user, uint256 grossVY, uint256 cumulativeVY);
    event ReferralReserveSynced(uint256 oldReservedVY, uint256 newReservedVY);

    // ============================================
    // ERRORS
    // ============================================

    error InvalidStakeId();
    error StakeNotActive();
    error StakeAlreadyActive();
    error InvalidTier();
    error OnlyRouter();
    error ClaimsPaused();
    error InvalidAddress();
    error InvalidFeeBps();
    error InsufficientYield();
    error TransferFailed();
    error ZeroAmount();
    error InvalidTimeRange();
    error PoolTooShallow();
    error InvalidAmount();

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyRouter() {
        if (!hasRole(ROUTER_ROLE, msg.sender)) revert OnlyRouter();
        _;
    }

    modifier whenClaimsNotPaused() {
        if (claimsPaused) revert ClaimsPaused();
        _;
    }

    // ============================================
    // CONSTRUCTOR & INITIALIZER
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _vyToken,
        address _vyt,
        address _capOfficer,
        address _feeRecipient,
        address _admin
    ) public initializer {
        if (_vyToken == address(0) || _vyt == address(0) || _capOfficer == address(0) ||
            _feeRecipient == address(0) || _admin == address(0)) revert InvalidAddress();

        vyToken = IValinityToken(_vyToken);
        vyt = IValinityYieldTreasury(_vyt);
        capOfficer = IValinityCapOfficer(_capOfficer);
        feeRecipient = _feeRecipient;
        feeBps = 500;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(ROUTER_ROLE, ADMIN_ROLE);
    }

    // ============================================
    // ROUTER HOOKS
    // ============================================

    /**
     * @notice Called by Router when user deposits into a stake
     * @dev Yield rate is dynamically calculated at stake time based on VYT balance
     */
    function onDeposit(
        address user,
        uint8 stakeId,
        uint8 tierId,
        uint256 principalVY,
        uint64 startTime,
        uint64 endTime
    ) external onlyRouter nonReentrant {
        if (stakeId >= MAX_STAKES) revert InvalidStakeId();
        if (stakes[user][stakeId].active) revert StakeAlreadyActive();
        if (tierId < 1 || tierId > 3) revert InvalidTier();
        if (principalVY == 0) revert ZeroAmount();
        if (endTime <= startTime) revert InvalidTimeRange();

        // Calculate rate BEFORE granting premium so the triggering stake uses regular tier rate
        uint16 yieldBps = _calculateRate(tierId, isPremium[user]);

        // Premium check: first 1,000 addresses staking >= 7,000 VY in tier 3
        if (tierId == 3 && principalVY >= PREMIUM_MIN_STAKE && !isPremium[user] && premiumCount < MAX_PREMIUM_HOLDERS) {
            isPremium[user] = true;
            ++premiumCount;
            emit PremiumGranted(user, premiumCount);
        }
        uint256 maxGross = (principalVY * yieldBps) / BPS_DENOMINATOR;

        stakes[user][stakeId] = Stake({
            active: true,
            tierId: tierId,
            yieldBpsSnapshot: yieldBps,
            startTime: startTime,
            endTime: endTime,
            lastAccrued: startTime,
            principalVY: principalVY,
            pendingGross: 0,
            grossPaidTotal: 0,
            maxGross: maxGross
        });

        totalPromisedYield += maxGross;

        emit StakeOpened(user, stakeId, tierId, principalVY, startTime, endTime, yieldBps);
    }

    /**
     * @notice Called by Router when user withdraws stake
     */
    function onWithdraw(
        address user,
        uint8 stakeId
    ) external onlyRouter nonReentrant returns (uint256 grossPaid, uint256 userOut, uint256 feeOut) {
        Stake storage stake = stakes[user][stakeId];
        if (!stake.active) revert StakeNotActive();

        _accrue(stake);
        (grossPaid, userOut, feeOut) = _settleYield(stake, user);

        // Remove remaining unpaid promise
        uint256 remainingPromise = stake.maxGross - stake.grossPaidTotal;
        if (remainingPromise > 0) {
            if (totalPromisedYield >= remainingPromise) {
                totalPromisedYield -= remainingPromise;
            } else {
                totalPromisedYield = 0;
            }
        }

        stake.active = false;

        emit YieldPaid(user, stakeId, grossPaid, userOut, feeOut, true);
    }

    /**
     * @notice Cover principal shortfall when Router has IL/slippage losses
     */
    function topUpPrincipal(
        address user,
        uint8 stakeId,
        uint256 amountVY
    ) external onlyRouter nonReentrant {
        if (amountVY == 0) revert ZeroAmount();
        if (stakeId >= MAX_STAKES) revert InvalidStakeId();
        // Note: active check removed — topUpPrincipal is called by the Router
        // AFTER onWithdraw() has already set stake.active = false.
        // The Router's withdrawStake guarantees this is only called during
        // a valid withdrawal flow (onlyRouter + stakeId bounds check suffice).

        vyt.pullTokens(address(this), amountVY);
        _safeTransfer(msg.sender, amountVY);
        capOfficer.addToHighestLTVFCap(amountVY);

        emit PrincipalTopUp(user, stakeId, amountVY);
    }

    // ============================================
    // USER FUNCTIONS
    // ============================================

    /**
     * @notice User claims accumulated yield for a stake
     * @dev Yield accrues per-second from startTime/lastClaim to now (capped at endTime)
     *      - Pulls 95% from VYT (90% user + 5% fee)
     *      - 5% ecosystem fee stays in VYT (not pulled)
     *      - Pulled amount added to Cap Officer highest LTVF
     *      - Stake remains active after claim
     * @param stakeId Stake ID (0, 1, or 2)
     */
    function claimYield(uint8 stakeId) external nonReentrant whenClaimsNotPaused {
        Stake storage stake = stakes[msg.sender][stakeId];
        if (!stake.active) revert StakeNotActive();

        _accrue(stake);
        if (stake.pendingGross == 0) revert InsufficientYield();

        (uint256 gross, uint256 userOut, uint256 fee) = _settleYield(stake, msg.sender);

        emit YieldPaid(msg.sender, stakeId, gross, userOut, fee, false);

        _pingVRYO();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get pending yield for a stake (simulates accrual)
     */
    function pendingYield(address user, uint8 stakeId) external view returns (uint256) {
        Stake memory stake = stakes[user][stakeId];
        if (!stake.active) return 0;

        uint64 accrueUntil = _clampTime(stake.endTime);
        if (accrueUntil <= stake.lastAccrued) return stake.pendingGross;

        uint256 newYield = _calcYield(stake, accrueUntil - stake.lastAccrued);
        return stake.pendingGross + newYield;
    }

    /**
     * @notice Get stake information
     */
    function getStake(address user, uint8 stakeId) external view returns (Stake memory) {
        return stakes[user][stakeId];
    }

    /**
     * @notice Get all active stake IDs for a user
     */
    function getActiveStakes(address user) external view returns (uint8[] memory) {
        uint8 count;
        for (uint8 i; i < MAX_STAKES; ++i) {
            if (stakes[user][i].active) ++count;
        }

        uint8[] memory ids = new uint8[](count);
        uint8 idx;
        for (uint8 i; i < MAX_STAKES; ++i) {
            if (stakes[user][i].active) ids[idx++] = i;
        }
        return ids;
    }

    /**
     * @notice Get estimated total yield if held to completion
     */
    function getEstimatedTotalYield(address user, uint8 stakeId) external view returns (uint256) {
        return stakes[user][stakeId].maxGross;
    }

    /**
     * @notice Get current dynamic yield rate for a tier
     * @dev Reads VYT available balance, subtracts promised yield, divides by 2,
     *      then divides by total staked VY. Caps at tier max.
     * @param tierId Tier (1, 2, or 3)
     * @param isPremiumUser Whether the user has premium status
     * @return yieldBps The yield in basis points that would be locked in if staking now
     */
    function getCurrentRate(uint8 tierId, bool isPremiumUser) external view returns (uint16 yieldBps) {
        return _calculateRate(tierId, isPremiumUser);
    }

    /**
     * @notice Get all current rates for display purposes
     * @return premiumT3 Premium tier 3 rate in bps
     * @return normalT3 Normal tier 3 rate in bps
     * @return normalT2 Normal tier 2 rate in bps
     * @return normalT1 Normal tier 1 rate in bps
     * @return masterRate The uncapped master rate in bps
     */
    function getAllCurrentRates() external view returns (
        uint16 premiumT3,
        uint16 normalT3,
        uint16 normalT2,
        uint16 normalT1,
        uint256 masterRate
    ) {
        masterRate = _getMasterRate();
        // master ≤ PREMIUM_MAX_BPS by construction; tier products stay ≤ their caps.
        premiumT3 = uint16(masterRate);
        normalT3  = uint16(masterRate * TIER3_MAX_BPS / PREMIUM_MAX_BPS);
        normalT2  = uint16(masterRate * TIER2_MAX_BPS / PREMIUM_MAX_BPS);
        normalT1  = uint16(masterRate * TIER1_MAX_BPS / PREMIUM_MAX_BPS);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    function setFeeRecipient(address newRecipient) external onlyRole(ADMIN_ROLE) {
        if (newRecipient == address(0)) revert InvalidAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function setFeeBps(uint16 newFeeBps) external onlyRole(ADMIN_ROLE) {
        if (newFeeBps > 500) revert InvalidFeeBps(); // Max 5% to keep user at 90%
        emit FeeBpsUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setRouter(address newRouter) external onlyRole(ADMIN_ROLE) {
        if (newRouter == address(0)) revert InvalidAddress();
        
        address oldRouter = router;
        if (oldRouter != address(0)) {
            _revokeRole(ROUTER_ROLE, oldRouter);
        }
        
        _grantRole(ROUTER_ROLE, newRouter);
        router = newRouter;
        stakingRouter = IStakingRouter(newRouter);
        
        emit RouterUpdated(oldRouter, newRouter);
    }

    function pauseClaims(bool paused) external onlyRole(ADMIN_ROLE) {
        claimsPaused = paused;
        emit ClaimsPausedUpdated(paused);
    }

    /**
     * @notice Set the Reserve Yield Officer (VRYO) heartbeat target.
     * @dev Pass `address(0)` to disable the heartbeat. The VYO address must
     *      hold the appropriate caller role on the new VRYO; otherwise the
     *      heartbeat will revert internally and only emit `VryoHeartbeatFailed`.
     * @param vryoAddress Address of the Reserve Yield Officer (or zero to disable)
     */
    function setVryo(address vryoAddress) external onlyRole(ADMIN_ROLE) {
        address oldVryo = address(vryo);
        if (vryoAddress == oldVryo) return;
        vryo = IValinityReserveYieldOfficer(vryoAddress);
        emit VryoUpdated(oldVryo, vryoAddress);
    }

    /**
     * @notice Set the Valinity Alliance Registration Officer (VARO).
     * @dev Pass `address(0)` to disable the referral reserve sync. VARO credits
     *      referrers by pulling `totalYieldClaimedVY`; VYO pulls VARO's
     *      `outstandingReferralDebtVY()` on every claim and reserves it. The read
     *      is wrapped in try/catch internally — a misconfigured or paused VARO
     *      can never block a user claim.
     * @param newVaro Address of the Alliance Registration Officer (or zero to disable)
     */
    function setVaro(address newVaro) external onlyRole(ADMIN_ROLE) {
        address oldVaro = varo;
        if (newVaro == oldVaro) return;
        varo = newVaro;
        emit VaroUpdated(oldVaro, newVaro);
    }

    /**
     * @notice Admin one-shot: re-read VARO's outstanding referral debt and fold
     *         the change into the reservation basket immediately.
     * @dev Same logic that runs on every claim (`_syncReferralReserve`). Use it
     *      right after wiring VARO so any pre-existing debt is reserved up front
     *      instead of landing on whoever claims first. Safe to call repeatedly —
     *      a no-op once the reservation already matches VARO's debt.
     */
    function syncReferralReserve() external onlyRole(ADMIN_ROLE) {
        _syncReferralReserve();
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Accrue yield up to current time or endTime
     */
    function _accrue(Stake storage stake) internal {
        uint64 accrueUntil = _clampTime(stake.endTime);
        if (accrueUntil <= stake.lastAccrued) return;

        stake.pendingGross += _calcYield(stake, accrueUntil - stake.lastAccrued);
        stake.lastAccrued = accrueUntil;
    }

    /**
     * @notice Settle pending yield: pull funds, transfer, update state
     */
    function _settleYield(
        Stake storage stake,
        address user
    ) internal returns (uint256 gross, uint256 userOut, uint256 feeOut) {
        gross = stake.pendingGross;
        if (gross == 0) return (0, 0, 0);

        // Clamp to remaining allowance
        uint256 remaining = stake.maxGross - stake.grossPaidTotal;
        if (gross > remaining) gross = remaining;

        // Handle edge case where clamping reduces to zero
        if (gross == 0) {
            stake.pendingGross = 0;
            return (0, 0, 0);
        }

        stake.pendingGross = 0;
        stake.grossPaidTotal += gross;

        // Reduce promised yield tracker
        if (totalPromisedYield >= gross) {
            totalPromisedYield -= gross;
        } else {
            totalPromisedYield = 0;
        }

        // Calculate split: 90% user, 5% fee, 5% ecosystem (not pulled)
        uint256 ecosystemFee = (gross * ECOSYSTEM_FEE_BPS) / BPS_DENOMINATOR;
        feeOut = (gross * feeBps) / BPS_DENOMINATOR;
        userOut = gross - ecosystemFee - feeOut;

        // Pull only what we distribute (95%)
        uint256 pullAmount = userOut + feeOut;
        if (pullAmount > 0) {
            vyt.pullTokens(address(this), pullAmount);
            _safeTransfer(user, userOut);
            if (feeOut > 0) _safeTransfer(feeRecipient, feeOut);
            capOfficer.addToHighestLTVFCap(pullAmount);
        }

        // Track gross VY for VARO referral crediting (no-op if VARO unset)
        _trackAndNotifyClaim(user, gross);
    }

    /**
     * @notice Calculate yield for elapsed time
     */
    function _calcYield(Stake memory stake, uint256 elapsed) internal pure returns (uint256) {
        uint256 totalDuration = stake.endTime - stake.startTime;
        // principal * yieldBps * elapsed / (BPS * totalDuration)
        return (stake.principalVY * stake.yieldBpsSnapshot * elapsed) / (BPS_DENOMINATOR * totalDuration);
    }

    /**
     * @notice Clamp timestamp to endTime
     */
    function _clampTime(uint64 endTime) internal view returns (uint64) {
        uint64 now_ = uint64(block.timestamp);
        return now_ < endTime ? now_ : endTime;
    }

    /**
     * @notice Safe transfer with revert on failure
     */
    function _safeTransfer(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!vyToken.transfer(to, amount)) revert TransferFailed();
    }

    /**
     * @notice Calculate the master rate using piecewise sqrt smoothing.
     * @dev Formula:
     *        effective  = vsr.totalStakedVY() + totalAssetStakeVY          (Option B)
     *        freeVY     = vyt.getAvailableForYield() − totalPromisedYield  (reservation)
     *        usableFree = freeVY × FREE_VY_USABLE_BPS / BPS_DENOMINATOR    (50%; rest = cushion)
     *
     *        if usableFree ≥ effective:  rate = PREMIUM_MAX_BPS             (cap)
     *        else:                       rate = sqrt(PREMIUM_MAX_BPS² × usableFree / effective)
     *
     *      Conservative coverage: 9% holds only while half of free VY covers
     *      100% of total demand (freeVY ≥ 2 × effective); below that the rate
     *      eases smoothly toward 0. No cliff.
     *
     *      `totalPromisedYield` (legacy name) now tracks the unified reservation:
     *        - VY-stake yield commitments (1× max yield)
     *        - Asset-stake reservations (2× principalVY + 2× maxYieldVY)
     *
     * @return Master rate in basis points (≤ PREMIUM_MAX_BPS).
     */
    function _getMasterRate() internal view returns (uint256) {
        uint256 effective = stakingRouter.totalStakedVY() + totalAssetStakeVY;
        if (effective == 0) return PREMIUM_MAX_BPS; // Max rate when no demand

        uint256 available = vyt.getAvailableForYield();
        if (available <= totalPromisedYield) return 0;

        uint256 freeVY;
        unchecked { freeVY = available - totalPromisedYield; }

        // Count only 50% of free VY toward coverage; the other 50% is a
        // permanent cushion. effective > 0 here (guarded above), so it is a
        // safe divisor.
        uint256 usableFree = (freeVY * FREE_VY_USABLE_BPS) / BPS_DENOMINATOR;

        // Cap binds while usable free VY covers the full stake (usableFree ≥ effective)
        if (usableFree >= effective) {
            return PREMIUM_MAX_BPS;
        }

        // Below full coverage: rate = MAX × sqrt(usableFree / effective)
        // Compute as sqrt(MAX² × usableFree / effective) to keep math integer-safe.
        uint256 rateSquared = (uint256(PREMIUM_MAX_BPS) * uint256(PREMIUM_MAX_BPS) * usableFree) / effective;
        uint256 rate = Math.sqrt(rateSquared);
        return rate > PREMIUM_MAX_BPS ? PREMIUM_MAX_BPS : rate;
    }

    /**
     * @notice Calculate dynamic yield rate for a tier at current moment.
     * @dev `_getMasterRate` is guaranteed ≤ PREMIUM_MAX_BPS, and each tier's
     *      arithmetic `master * TIER_X / PREMIUM_MAX_BPS` is bounded above by
     *      `TIER_X` by construction — so no per-tier cap clamp is needed.
     *      All values fit in uint16 (max 65,535 ≫ 900).
     */
    function _calculateRate(uint8 tierId, bool isPremiumUser) internal view returns (uint16 yieldBps) {
        uint256 masterRate = _getMasterRate();

        if (tierId == 3 && isPremiumUser) {
            return uint16(masterRate);
        } else if (tierId == 3) {
            return uint16(masterRate * TIER3_MAX_BPS / PREMIUM_MAX_BPS);
        } else if (tierId == 2) {
            return uint16(masterRate * TIER2_MAX_BPS / PREMIUM_MAX_BPS);
        } else {
            return uint16(masterRate * TIER1_MAX_BPS / PREMIUM_MAX_BPS);
        }
    }

    // ============================================
    // V4 — ASSET STAKING (mirrors VSR V3)
    // ============================================

    /**
     * @notice One-shot V4 initializer — wires DAX, Uniswap V2 router and pair,
     *         and USDC token. Caller must already hold ADMIN_ROLE.
     * @dev Uses reinitializer(4). Idempotent re-call is impossible by design.
     */
    function initializeV4(
        address daxAddress,
        address uniRouterAddress,
        address uniPairAddress,
        address usdcAddress,
        bool _vyIsToken0
    ) external reinitializer(4) onlyRole(ADMIN_ROLE) {
        if (daxAddress == address(0) || uniRouterAddress == address(0) ||
            uniPairAddress == address(0) || usdcAddress == address(0)) revert InvalidAddress();

        dax = IValinityDAX(daxAddress);
        uniRouter = IUniswapV2Router02(uniRouterAddress);
        uniPair = IUniswapV2Pair(uniPairAddress);
        usdcToken = IERC20(usdcAddress);
        vyIsToken0 = _vyIsToken0;

        // MAX-approve VY to DAX and to Uniswap V2 router so swaps skip per-call approve cost.
        IERC20(address(vyToken)).forceApprove(daxAddress, type(uint256).max);
        IERC20(address(vyToken)).forceApprove(uniRouterAddress, type(uint256).max);

        emit DaxUpdated(daxAddress);
        emit UniRouterUpdated(uniRouterAddress);
    }

    /**
     * @notice VSR hook on a new asset stake. Records yield bookkeeping, sets
     *         the rate, and grants premium if thresholds are met.
     */
    function onAssetDeposit(
        address user,
        uint256 stakeId,
        address asset,
        uint256 principalAsset,
        uint8 tier,
        uint64 unlockTime
    ) external onlyRouter nonReentrant {
        if (assetYieldStakes[user][stakeId].active) revert StakeAlreadyActive();
        if (tier < 1 || tier > 3) revert InvalidTier();
        if (principalAsset == 0) revert ZeroAmount();
        if (unlockTime <= block.timestamp) revert InvalidTimeRange();

        bool _isUni = asset == address(usdcToken);

        // Rate locked at deposit, BEFORE premium grant — triggering stake uses
        // current tier rate, premium only kicks in for subsequent stakes.
        uint16 yieldBps = _calculateRate(tier, isPremium[user]);

        uint256 maxYield = (principalAsset * yieldBps) / BPS_DENOMINATOR;

        // Fetch pool reserves ONCE and compute both principal-VY and maxYield-VY
        // from the same snapshot (saves a duplicate external pool read).
        uint256 principalVY;
        uint256 maxYieldVY;
        {
            uint256 rVY;
            uint256 rA;
            if (_isUni) {
                (uint112 r0, uint112 r1, ) = uniPair.getReserves();
                rVY = vyIsToken0 ? uint256(r0) : uint256(r1);
                rA  = vyIsToken0 ? uint256(r1) : uint256(r0);
            } else {
                (, rVY, rA) = dax.getPoolReserves(dax.assetToPoolId(asset));
            }
            if (rA != 0) {
                principalVY = (principalAsset * rVY) / rA;
                maxYieldVY  = (maxYield * rVY) / rA;
            }
        }

        // Premium grant: tier 3 + ≥ 7000 VY (pool-spot equivalent).
        if (tier == 3 && !isPremium[user] && premiumCount < MAX_PREMIUM_HOLDERS) {
            if (principalVY >= PREMIUM_MIN_STAKE) {
                isPremium[user] = true;
                ++premiumCount;
                emit PremiumGranted(user, premiumCount);
            }
        }

        // 2× safety buffer on the entire asset-stake exposure (principal + yield).
        uint256 reservedVY_ = 2 * (principalVY + maxYieldVY);

        uint64 startTime = uint64(block.timestamp);

        assetYieldStakes[user][stakeId] = AssetYieldStake({
            active: true,
            isUniLP: _isUni,
            tier: tier,
            yieldBpsSnapshot: yieldBps,
            startTime: startTime,
            endTime: unlockTime,
            lastClaimTime: startTime,
            asset: asset,
            principalAsset: principalAsset,
            maxYieldAsset: maxYield,
            yieldPaidAsset: 0,
            reservedVY: reservedVY_,
            principalVYAtDeposit: principalVY
        });

        // Update global trackers
        totalPromisedYield += reservedVY_;
        totalAssetStakeVY += principalVY;

        emit AssetStakeOpened(user, stakeId, asset, principalAsset, tier, yieldBps, maxYield);
    }

    /**
     * @notice User claims accrued yield for an asset stake.
     * @dev Distribution: 90% to user in asset, 5% to feeRecipient as VY,
     *      5% kept in VYT (ecosystem fee, not pulled). 95% pulled VY is
     *      booked into VCO's highest-LTV-F cap. Reservation is decremented
     *      by the gross VY-equivalent of this claim (matches VY-stake pattern).
     */
    function claimAssetYield(uint256 stakeId) external nonReentrant whenClaimsNotPaused {
        AssetYieldStake storage s = assetYieldStakes[msg.sender][stakeId];
        if (!s.active) revert StakeNotActive();

        uint256 accrued = _accrueAsset(s);
        if (accrued == 0) revert InsufficientYield();

        uint256 grossVY = _pullAndSellForYield(s.asset, accrued, msg.sender);

        s.yieldPaidAsset += accrued;
        s.lastClaimTime = _clampTime(s.endTime);

        // Decrement reservation by the gross VY value of this claim
        _decrementAssetReservation(s, grossVY);

        emit AssetYieldPaid(msg.sender, stakeId, s.asset, accrued, grossVY, false);
        _pingVRYO();
    }

    /**
     * @notice VSR hook on withdraw: settle final yield (90/5/5 split, same as
     *         claim) then close the stake's yield record. Releases the entire
     *         remaining VY reservation and decrements the threshold tracker.
     * @dev VSR calls this BEFORE any topUp. The full reservation release here
     *      gives `topUpAssetWithdrawal` headroom in freeVY for the principal
     *      backstop pull.
     */
    function onAssetWithdraw(address user, uint256 stakeId) external onlyRouter nonReentrant {
        AssetYieldStake storage s = assetYieldStakes[user][stakeId];
        if (!s.active) revert StakeNotActive();

        uint256 accrued = _accrueAsset(s);
        uint256 grossVY;
        if (accrued > 0) {
            grossVY = _pullAndSellForYield(s.asset, accrued, user);
            s.yieldPaidAsset += accrued;
            _decrementAssetReservation(s, grossVY);
        }

        // Close the stake
        s.active = false;
        s.lastClaimTime = _clampTime(s.endTime);

        // Release remaining reservation (unused yield buffer + 2× principal buffer)
        uint256 remaining = s.reservedVY;
        if (remaining > 0) {
            if (totalPromisedYield >= remaining) {
                unchecked { totalPromisedYield -= remaining; }
            } else {
                totalPromisedYield = 0;
            }
            s.reservedVY = 0;
        }

        // Release threshold contribution
        uint256 principalContribution = s.principalVYAtDeposit;
        if (principalContribution > 0) {
            if (totalAssetStakeVY >= principalContribution) {
                unchecked { totalAssetStakeVY -= principalContribution; }
            } else {
                totalAssetStakeVY = 0;
            }
            s.principalVYAtDeposit = 0;
        }

        emit AssetYieldPaid(user, stakeId, s.asset, accrued, grossVY, true);
    }

    /**
     * @notice VSR hook to cover principal shortfall at withdraw: pull VY from
     *         VYT, swap to `asset`, deliver `shortfall` of asset to `recipient`.
     * @dev Called by VSR AFTER `onAssetWithdraw` has already released the
     *      stake's full reservation. The released amount expanded `freeVY` to
     *      cover this pull. No reservation decrement needed here — the VY drain
     *      is reflected via `vyt.getAvailableForYield()` on the next read.
     */
    function topUpAssetWithdrawal(
        address asset,
        uint256 shortfall,
        address recipient
    ) external onlyRouter nonReentrant {
        if (shortfall == 0) revert ZeroAmount();
        uint256 vyPulled = _pullAndSellForAsset(asset, shortfall, recipient);
        emit AssetTopUp(asset, shortfall, vyPulled, recipient);
    }

    /**
     * @notice View pending asset yield (simulates accrual).
     */
    function pendingAssetYield(address user, uint256 stakeId) external view returns (uint256) {
        AssetYieldStake memory s = assetYieldStakes[user][stakeId];
        if (!s.active) return 0;

        uint64 accrueUntil = _clampTime(s.endTime);
        if (accrueUntil <= s.lastClaimTime) return 0;
        uint256 totalDuration = s.endTime - s.startTime;
        uint256 elapsed;
        unchecked { elapsed = accrueUntil - s.lastClaimTime; }
        return (s.maxYieldAsset * elapsed) / totalDuration;
    }

    /**
     * @notice Read an asset-yield stake record.
     */
    function getAssetYieldStake(address user, uint256 stakeId) external view returns (AssetYieldStake memory) {
        return assetYieldStakes[user][stakeId];
    }

    // ─── Internal helpers ────────────────────────────────────────────────

    /**
     * @notice Accrue per-second linear yield up to now (capped at endTime).
     * @return accrued Asset units of yield earned since lastClaimTime.
     */
    function _accrueAsset(AssetYieldStake storage s) internal view returns (uint256 accrued) {
        uint64 accrueUntil = _clampTime(s.endTime);
        if (accrueUntil <= s.lastClaimTime) return 0;
        uint256 totalDuration = s.endTime - s.startTime;
        uint256 elapsed;
        unchecked { elapsed = accrueUntil - s.lastClaimTime; }
        accrued = (s.maxYieldAsset * elapsed) / totalDuration;
        // Cap at unpaid remainder
        uint256 remainder = s.maxYieldAsset - s.yieldPaidAsset;
        if (accrued > remainder) accrued = remainder;
    }

    /**
     * @notice Pull enough VY from VYT to deliver `targetAsset` of `asset`,
     *         swap VY → asset (Uniswap V2 for USDC, DAX otherwise), and book
     *         the pulled VY in VCO's highest-LTV-F cap.
     * @return vyPulled Amount of VY pulled from VYT.
     */
    function _pullAndSellForAsset(
        address asset,
        uint256 targetAsset,
        address recipient
    ) internal returns (uint256 vyPulled) {
        uint256 vyNeeded = _quoteVyForAsset(asset, targetAsset);
        if (vyNeeded == 0) revert PoolTooShallow();

        vyt.pullTokens(address(this), vyNeeded);
        vyPulled = vyNeeded;

        if (asset == address(usdcToken)) {
            address[] memory path = new address[](2);
            path[0] = address(vyToken);
            path[1] = address(usdcToken);
            uint[] memory amounts = uniRouter.swapExactTokensForTokens(
                vyNeeded, targetAsset, path, recipient, block.timestamp + 300
            );
            if (amounts[1] < targetAsset) revert PoolTooShallow();
        } else {
            uint256 received = dax.swapExactIn(
                dax.assetToPoolId(asset), address(vyToken), vyNeeded, targetAsset, recipient
            );
            if (received < targetAsset) revert PoolTooShallow();
        }

        capOfficer.addToHighestLTVFCap(vyNeeded);
    }

    /**
     * @notice Quote VY needed to receive exactly `amountOut` of `asset` from
     *         the appropriate pool. Adds a small safety buffer.
     * @dev Uniswap V2 path uses the 0.30% fee inverse; DAX path is feeless
     *      (constant-product). Returns 0 if the pool can't deliver.
     */
    function _quoteVyForAsset(address asset, uint256 amountOut) internal view returns (uint256) {
        if (asset == address(usdcToken)) {
            (uint112 r0, uint112 r1, ) = uniPair.getReserves();
            uint256 rVY = vyIsToken0 ? uint256(r0) : uint256(r1);
            uint256 rA  = vyIsToken0 ? uint256(r1) : uint256(r0);
            if (rA <= amountOut) return 0;
            // Uniswap V2 inverse with 0.3% fee:
            //   in = (rIn * out * 1000) / ((rOut - out) * 997) + 1
            uint256 num = rVY * amountOut * 1000;
            uint256 den = (rA - amountOut) * 997;
            return (num / den) + 1;
        } else {
            uint256 poolId = dax.assetToPoolId(asset);
            (, uint256 rVY, uint256 rA) = dax.getPoolReserves(poolId);
            if (rA <= amountOut) return 0;
            // DAX constant product, feeless:
            //   in = (rIn * out) / (rOut - out) + 1
            return ((rVY * amountOut) / (rA - amountOut)) + 1;
        }
    }

    /**
     * @notice VY-equivalent of `amountAsset` at the appropriate pool's current
     *         spot. Used for reservation, threshold tracking, premium gating,
     *         and yield-claim accounting.
     */
    function _quoteAssetToVY(address asset, uint256 amountAsset) internal view returns (uint256) {
        if (amountAsset == 0) return 0;
        if (asset == address(usdcToken)) {
            (uint112 r0, uint112 r1, ) = uniPair.getReserves();
            uint256 rVY = vyIsToken0 ? uint256(r0) : uint256(r1);
            uint256 rA  = vyIsToken0 ? uint256(r1) : uint256(r0);
            if (rA == 0) return 0;
            return (amountAsset * rVY) / rA;
        } else {
            uint256 poolId = dax.assetToPoolId(asset);
            (, uint256 rVY, uint256 rA) = dax.getPoolReserves(poolId);
            if (rA == 0) return 0;
            return (amountAsset * rVY) / rA;
        }
    }

    /**
     * @notice Yield-claim swap path with 90/5/5 fee split.
     *         - 90% of gross (in VY) is swapped to asset → user
     *         - 5% of gross (in VY) is transferred raw to feeRecipient
     *         - 5% of gross stays in VYT (ecosystem fee, never pulled)
     *         - The 95% pulled VY is booked into VCO's highest-LTV-F cap.
     * @return grossVY VY-equivalent of `accruedAsset` at current spot.
     */
    function _pullAndSellForYield(
        address asset,
        uint256 accruedAsset,
        address user
    ) internal returns (uint256 grossVY) {
        grossVY = _quoteAssetToVY(asset, accruedAsset);
        if (grossVY == 0) revert PoolTooShallow();

        // Split in VY units
        uint256 ecosystemKept = (grossVY * ECOSYSTEM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 feeVY = (grossVY * feeBps) / BPS_DENOMINATOR;
        uint256 userTargetVY = grossVY - ecosystemKept - feeVY;
        uint256 pullVY = userTargetVY + feeVY; // 95% of gross

        if (pullVY == 0) return grossVY;

        vyt.pullTokens(address(this), pullVY);

        // 5% fee leg: send as VY directly to feeRecipient (VBBO)
        if (feeVY > 0) _safeTransfer(feeRecipient, feeVY);

        // 90% user leg: swap VY for asset, send directly to user
        if (userTargetVY > 0) {
            if (asset == address(usdcToken)) {
                address[] memory path = new address[](2);
                path[0] = address(vyToken);
                path[1] = address(usdcToken);
                uniRouter.swapExactTokensForTokens(
                    userTargetVY, 0, path, user, block.timestamp + 300
                );
            } else {
                dax.swapExactIn(
                    dax.assetToPoolId(asset), address(vyToken), userTargetVY, 0, user
                );
            }
        }

        capOfficer.addToHighestLTVFCap(pullVY);

        // Track gross VY-equivalent for VARO referral crediting (no-op if VARO unset)
        _trackAndNotifyClaim(user, grossVY);
    }

    /**
     * @notice Decrement an asset stake's reservation (and the global tracker)
     *         by `vyAmount`. Clamps at 0 so pool-drift over-pull never reverts.
     */
    function _decrementAssetReservation(AssetYieldStake storage s, uint256 vyAmount) internal {
        uint256 dec = vyAmount > s.reservedVY ? s.reservedVY : vyAmount;
        if (dec == 0) return;
        unchecked { s.reservedVY -= dec; }
        if (totalPromisedYield >= dec) {
            unchecked { totalPromisedYield -= dec; }
        } else {
            totalPromisedYield = 0;
        }
    }

    // ============================================
    // UUPS UPGRADE
    // ============================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @notice Ping VRYO to realign yield deployments after a user claim.
     * @dev Wrapped in try/catch so a misconfigured or paused VRYO can never
     *      block user claims. No-op when VRYO is unset.
     */
    function _pingVRYO() internal {
        IValinityReserveYieldOfficer v = vryo;
        if (address(v) == address(0)) return;
        try v.execute() {
            // Heartbeat succeeded; VRYO emits its own Executed event.
        } catch (bytes memory reason) {
            emit VryoHeartbeatFailed(reason);
        }
    }

    /**
     * @notice Record a user's gross yield claim (in VY) and resync VARO debt.
     * @dev Updates `totalYieldClaimedVY[user]` (VARO PULLS this to credit the
     *      referrer — no push), then folds VARO's latest protocol-wide referral
     *      debt into the reservation basket. No-op on zero.
     */
    function _trackAndNotifyClaim(address user, uint256 vyAmount) internal {
        if (vyAmount == 0) return;
        uint256 cumulative;
        unchecked {
            cumulative = totalYieldClaimedVY[user] + vyAmount;
            totalYieldClaimedVY[user] = cumulative;
        }
        emit YieldClaimedVY(user, vyAmount, cumulative);

        _syncReferralReserve();
    }

    /**
     * @notice Re-read VARO's protocol-wide outstanding referral debt and fold
     *         the change into `totalPromisedYield` (the reservation basket).
     * @dev Debt grew since last sync → reserve the difference; debt shrank →
     *      release it (floored at zero). `referralReservedVY` tracks the amount
     *      currently earmarked. No-op when VARO is unset. The external view is
     *      wrapped in try/catch so a paused or reverting VARO never blocks a
     *      user claim — the reservation simply holds at its last value.
     */
    function _syncReferralReserve() internal {
        address v = varo;
        if (v == address(0)) return;

        uint256 owed;
        try IValinityAllianceRegistrationOfficer(v).outstandingReferralDebtVY() returns (uint256 d) {
            owed = d;
        } catch (bytes memory reason) {
            emit VaroReserveSyncFailed(reason);
            return;
        }

        uint256 prev = referralReservedVY;
        if (owed == prev) return;

        if (owed > prev) {
            unchecked { totalPromisedYield += owed - prev; }
        } else {
            uint256 release = prev - owed;
            if (totalPromisedYield >= release) {
                unchecked { totalPromisedYield -= release; }
            } else {
                totalPromisedYield = 0;
            }
        }
        referralReservedVY = owed;
        emit ReferralReserveSynced(prev, owed);
    }

    // V4 (asset staking) storage = 6 slots:
    //   assetYieldStakes (1) + dax (1) + uniRouter (1) + uniPair (1)
    //   + usdcToken+vyIsToken0 packed (1) + totalAssetStakeVY (1).
    // V5 (VARO integration) storage = 3 slots:
    //   varo (1) + totalYieldClaimedVY mapping (1) + referralReservedVY (1).
    //   (Struct extensions to AssetYieldStake do NOT consume gap slots —
    //   structs in mappings live in their own hashed slots.)
    // Gap reduced 37 → 27.
    uint256[27] private __gap;
}
