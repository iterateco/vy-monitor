// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// ═══════════════════════════════════════════════════════════════════════════
// INTERFACES
// ═══════════════════════════════════════════════════════════════════════════

interface IValinityDAX {
    function getNumPools() external view returns (uint256);
    /// @notice Sum of `reserveVY` across every DAX pool. Used by VSR to
    ///         weight the V_dax vs V_uni split on every deposit.
    function getTotalVYReserves() external view returns (uint256 total);
    function depositVYOnly(
        uint256 vyAmount,
        address recipient
    ) external returns (uint256 sharesMinted);
    function withdraw(
        uint256 sharesToBurn,
        address recipient
    ) external returns (uint256 vyOut);

    // V3 additions used by asset-staking paths
    function swapExactIn(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    function getPoolReserves(
        uint256 poolId
    ) external view returns (
        address asset,
        uint256 reserveVY,
        uint256 reserveAsset
    );

    function assetToPoolId(address asset) external view returns (uint256);
    function hasPool(address asset) external view returns (bool);
}

interface IValinityReserveYieldOfficer {
    /// @notice Heartbeat that rebalances VRT yield deployments to match
    ///         current staked VY. Restricted to STAKING_ROUTER_ROLE on VRYO,
    ///         so the StakingRouter address must be granted that role.
    function execute() external;
}

interface IYieldOfficer {
    function onDeposit(
        address user,
        uint8 stakeId,
        uint8 tierId,
        uint256 principalVY,
        uint64 startTime,
        uint64 endTime
    ) external;

    function onWithdraw(
        address user,
        uint8 stakeId
    ) external returns (uint256 grossPaid, uint256 userOut, uint256 feeOut);

    /// @notice Cover principal shortfall when Router has losses from IL/slippage
    /// @param user User affected (for tracking)
    /// @param stakeId Stake ID
    /// @param amountVY Amount of VY shortfall to cover
    function topUpPrincipal(
        address user,
        uint8 stakeId,
        uint256 amountVY
    ) external;

    /// @notice VYO hook: notify of a new asset stake. VYO computes its own
    ///         principalVy from the asset's pool, sets up yield accrual, and
    ///         may grant premium.
    function onAssetDeposit(
        address user,
        uint256 stakeId,
        address asset,
        uint256 principalAsset,
        uint8 tier,
        uint64 unlockTime
    ) external;

    /// @notice VYO hook: settle final yield and close the asset stake's
    ///         yield record. Called by VSR during `withdrawAssetStake`.
    function onAssetWithdraw(address user, uint256 stakeId) external;

    /// @notice Pull VY from VYT, swap to `asset` in its pool, transfer
    ///         `shortfall` of asset to `recipient`. Called by VSR's
    ///         `withdrawAssetStake` when LP burn under-delivers.
    function topUpAssetWithdrawal(
        address asset,
        uint256 shortfall,
        address recipient
    ) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    /// @notice Used by `withdrawAssetStake` to buy EXACTLY the asset needed
    ///         to cover principal, leaving the rest of the recovered VY for
    ///         the BuybackOfficer (protocol-level appreciation capture).
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
}

// ═══════════════════════════════════════════════════════════════════════════
// MAIN CONTRACT
// ═══════════════════════════════════════════════════════════════════════════

/**
 * @title ValinityStakingRouter
 * @notice Routes user VY deposits between DAX and Uniswap V2 pools with tier-based locking
 * @dev Supports up to 3 simultaneous stakes per user with individual tracking
 *
 * Key Features:
 * - 3 tiers with configurable durations (default: 30d, 60d, 90d)
 * - Up to 3 active stakes per user (stakeId: 0, 1, 2)
 * - Credit/index system for admin operations without affecting user ownership
 * - Integration with Yield Officer for yield tracking per stake
 * - 100% VY-in, 100% VY-out (no LP tokens for users)
 */
contract ValinityStakingRouter is UUPSUpgradeable, AccessControl, ReentrancyGuardTransient, Initializable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Granted to VARO only — gates `registerVDAO`.
    bytes32 public constant VARO_ROLE = keccak256("VARO_ROLE");

    uint8 public constant MAX_STAKES = 3;
    uint256 public constant MIN_STAKE = 100 * 1e18; // 100 VY minimum

    /// @notice Permanently locked share of each VY-stake's LP, in basis points.
    /// @dev V4: 1% of both VDAX and UNI-LP minted on a VY stake is retained
    ///      forever in this contract (uncredited). Builds protocol-owned
    ///      liquidity that grows monotonically with TVL. Asset stakes are
    ///      NOT subject to this lock.
    uint16 public constant LOCK_BPS = 100; // 1.00%

    // ═══════════════════════════════════════════════════════════════════════
    // CORE REFERENCES
    // ═══════════════════════════════════════════════════════════════════════

    IValinityDAX public dax;
    IERC20 public vdaxToken;
    IUniswapV2Pair public uniPair;
    IERC20 public uniLP;
    IERC20 public vyToken;
    IERC20 public usdcToken;
    IUniswapV2Router02 public uniRouter;

    /// @notice True if VY is token0 in the Uniswap pair, false if token1
    bool public vyIsToken0;

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE - TIER SYSTEM
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Duration in seconds for each tier
    /// @dev Configurable by admin, applies to new stakes only
    mapping(uint8 => uint32) public tierDurationSec;

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE - CREDIT/INDEX SYSTEM
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Global index for VDAX (starts at 1e18)
    /// @dev Updated by adminSyncIndexes() after admin operations
    uint256 public daxIndex;

    /// @notice Global index for UNI-LP (starts at 1e18)
    /// @dev Updated by adminSyncIndexes() after admin operations
    uint256 public uniIndex;

    /// @notice Total DAX credits across all stakes
    uint256 public totalDaxCredits;

    /// @notice Total UNI credits across all stakes
    uint256 public totalUniCredits;

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE - STAKE SYSTEM
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Individual stake data
     * @dev Each user can have up to 3 stakes (stakeId: 0, 1, 2)
     */
    struct Stake {
        bool active; // Is this stake slot active
        uint8 tierId; // Tier selected (1, 2, or 3)
        uint64 unlockTime; // Timestamp when stake can be withdrawn
        uint256 daxCredits; // Credits for VDAX position
        uint256 uniCredits; // Credits for UNI-LP position
        uint256 principalVY; // Original VY deposited (for protection)
    }

    /// @notice stakes[user][stakeId] => Stake data
    /// @dev stakeId must be 0, 1, or 2
    mapping(address => Stake[3]) public stakes;

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE - YIELD OFFICER
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Yield Officer contract for yield distribution
    /// @dev Can be updated by admin
    IYieldOfficer public yieldOfficer;

    /// @notice Buyback Officer address to receive excess VY (vyOut > principal)
    /// @dev Can be updated by admin
    address public buybackOfficer;

    /// @notice Total VY currently staked across all users
    uint256 public totalStakedVY;

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE - ADMIN CONTROLS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emergency pause for deposits
    bool public depositsPaused;

    /// @notice Emergency pause for withdrawals
    bool public withdrawalsPaused;

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE - V2 APPENDS (CRITICAL: append only, never reorder)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Variables added in the V2 upgrade. They MUST live at the end of the
    // existing storage layout (just before `__gap`) to remain compatible with
    // the deployed V1 proxy. Earlier drafts of this file inserted `vryo`
    // between `buybackOfficer` and `totalStakedVY`, which would have shifted
    // every subsequent slot — corrupting `totalStakedVY`, `depositsPaused`,
    // and `withdrawalsPaused` on upgrade. Do not move these declarations.

    /// @notice Reserve Yield Officer (VRYO). Pinged on every stake/unstake to
    ///         keep deployed reserves aligned with staked VY.
    /// @dev Optional. Heartbeat is wrapped in try/catch — failures never block
    ///      user deposits/withdrawals. Default zero-address is a safe no-op.
    IValinityReserveYieldOfficer public vryo;

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE - V3 APPENDS (asset staking — append only, never reorder)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // V3 adds asset staking alongside the existing VY-staking path. Asset
    // stakes use an unbounded `mapping(stakeId => AssetStake)` per user
    // (VY stakes remain capped at 3 via `Stake[3]`). USDC is routed through
    // the public Uniswap V2 VY/USDC pair; every other asset is routed through
    // the asset's DAX VY/asset pool.

    /// @notice Asset stake record. VSR holds only the LP-custody facts —
    ///         all yield bookkeeping lives in VYO (via onAssetDeposit hook).
    struct AssetStake {
        bool active;
        bool isUniLP;               // true iff asset == USDC (Uniswap V2 path)
        address asset;
        uint64 unlockTime;          // packed: 1+1+20+8 = 30 bytes, fits one slot
        uint256 principalAsset;
        uint256 lpAmount;           // VDAX or UNI-LP held against this stake
    }

    /// @notice Per-asset registry configuration.
    struct AssetConfig {
        bool supported;
        bool isVDAO;                // true for VARO-registered V-DAO tokens
        uint256 minStake;           // in asset's native units; V-DAOs default to 0
    }

    /// @notice user => stakeId => AssetStake
    mapping(address => mapping(uint256 => AssetStake)) public assetStakes;

    /// @notice user => next stake ID to assign (monotonically increasing)
    mapping(address => uint256) public nextAssetStakeId;

    /// @notice asset => config. supported=false until registered.
    mapping(address => AssetConfig) public assetConfig;

    /// @notice Enumerable list of supported assets (off-chain helper).
    address[] public supportedAssets;

    /// @notice Running totals (asset-native units) — telemetry only.
    mapping(address => uint256) public totalPrincipalByAsset;

    /// @notice Number of currently-active asset stakes (telemetry).
    uint256 public totalAssetStakesActive;

    /// @notice WETH token, used to wrap native ETH from `depositETHStake`
    ///         and to unwrap back to ETH at withdrawal.
    IWETH public weth;

    /// @notice ValinityAcquisitionOfficer — gated by `VARO_ROLE`.
    address public varo;

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE - V4 APPENDS (permanent ecosystem LP lock — append only)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // V4 introduces a permanent 1% LP lock on every VY stake. The locked LP
    // is NOT credited to any user — it sits in this contract's balance and
    // accumulates monotonically forever. `_syncIndexes` and `adminExtract`
    // MUST subtract these from their balance basis so the lock doesn't leak
    // back to users or get extracted by admin.

    /// @notice Cumulative VDAX-LP locked permanently across all VY stakes.
    uint256 public lockedVdaxLP;

    /// @notice Cumulative UNI-LP locked permanently across all VY stakes.
    uint256 public lockedUniLP;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Deposit(
        address indexed user,
        uint8 stakeId,
        uint256 vyAmount,
        uint8 tierId,
        uint256 vdaxMinted,
        uint256 uniMinted,
        uint256 daxCreditsAdd,
        uint256 uniCreditsAdd
    );

    event Withdraw(
        address indexed user,
        uint8 stakeId,
        uint8 tierId,
        uint256 vdaxBurn,
        uint256 uniBurn,
        uint256 principalPaid, // Always == principalVY deposited
        uint256 yieldPaid // Yield paid separately by YieldOfficer
    );

    /// @notice Emitted when vyOut < principal (YieldOfficer covers shortfall)
    event PrincipalShortfall(
        address indexed user,
        uint8 stakeId,
        uint256 shortfall
    );

    /// @notice Emitted when vyOut > principal (excess goes to BuybackOfficer)
    event PrincipalExcess(address indexed user, uint8 stakeId, uint256 excess);

    event AdminPause(bool depositsPaused, bool withdrawalsPaused);

    event AdminExtract(uint16 bps, uint256 vdaxOut, uint256 uniOut);

    event AdminSync(uint256 daxIndex, uint256 uniIndex);

    event TierDurationUpdated(
        uint8 indexed tierId,
        uint32 oldDuration,
        uint32 newDuration
    );

    event YieldOfficerUpdated(
        address indexed oldOfficer,
        address indexed newOfficer
    );

    event BuybackOfficerUpdated(
        address indexed oldOfficer,
        address indexed newOfficer
    );

    event VryoUpdated(
        address indexed oldVryo,
        address indexed newVryo
    );

    /// @notice Emitted when the VRYO heartbeat reverts. Stake/unstake still
    ///         succeeds; an off-chain monitor should react to this event.
    event VryoHeartbeatFailed(bytes reason);

    /// @notice Emitted when zap leftovers are sent to BuybackOfficer
    event ZapLeftoverSent(uint256 usdcSwapped, uint256 vyTotal);

    // ── V3 asset-stake events ─────────────────────────────────────────────

    event AssetStakeDeposited(
        address indexed user,
        uint256 indexed stakeId,
        address indexed asset,
        uint256 principalAsset,
        uint8 tier,
        uint256 lpAmount,
        bool isUniLP
    );

    /// @dev `principalPaid` is the stake's principal (in asset units).
    ///      `assetPaid` is the asset units the user actually received.
    ///      `vyPaid` is the VY units the user received (non-zero only on the
    ///      shallow-pool path: asset + VY together cover principal value).
    ///      Yield is paid by VYO directly to the user — track via VYO events.
    event AssetStakeWithdrawn(
        address indexed user,
        uint256 indexed stakeId,
        address indexed asset,
        uint256 principalPaid,
        uint256 assetPaid,
        uint256 vyPaid
    );

    event AssetAdded(address indexed asset, uint256 minStake);
    event AssetRemoved(address indexed asset);
    event AssetMinStakeUpdated(address indexed asset, uint256 newMin);
    event VDAORegistered(address indexed asset);
    event VaroUpdated(address indexed oldVaro, address indexed newVaro);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error InvalidStakeId();
    error InvalidTierId();
    error BelowMinStake();
    error MaxStakesReached();
    error StakeNotActive();
    error StakeStillLocked();
    error DepositsPaused();
    error WithdrawalsPaused();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error NoBalance();
    error SlippageExceeded();
    error PrincipalProtectionFailed();
    error VYTokenMismatch();

    // ── V3 asset-stake errors ─────────────────────────────────────────────
    error AssetNotSupported();
    error AssetAlreadySupported();
    error YieldOfficerRequired();
    error ETHTransferFailed();
    error UseDepositETHStake();

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice ETH receiver — accepts ETH ONLY as the unwrap callback from
    ///         the canonical WETH contract. Direct ETH transfers from any
    ///         other source revert so funds are never accidentally locked.
    ///         Users stake/withdraw ETH via `depositETHStake` / `withdrawAssetStake`.
    receive() external payable {
        if (msg.sender != address(weth)) revert InvalidAddress();
    }

    /**
     * @notice Initialize the Staking Router
     * @param daxAddress Address of ValinityDAX
     * @param vdaxAddress Address of VDAX token
     * @param vyAddress Address of VY token (verified against pair)
     * @param uniPairAddress Address of Uniswap V2 VY/USDC pair
     * @param uniRouterAddress Address of Uniswap V2 Router
     * @param adminAddress Address to receive admin role
     */
    function initialize(
        address daxAddress,
        address vdaxAddress,
        address vyAddress,
        address uniPairAddress,
        address uniRouterAddress,
        address adminAddress
    ) public initializer {
        if (daxAddress == address(0)) revert InvalidAddress();
        if (vdaxAddress == address(0)) revert InvalidAddress();
        if (vyAddress == address(0)) revert InvalidAddress();
        if (uniPairAddress == address(0)) revert InvalidAddress();
        if (uniRouterAddress == address(0)) revert InvalidAddress();
        if (adminAddress == address(0)) revert InvalidAddress();

        dax = IValinityDAX(daxAddress);
        vdaxToken = IERC20(vdaxAddress);
        uniPair = IUniswapV2Pair(uniPairAddress);
        uniLP = IERC20(uniPairAddress);
        uniRouter = IUniswapV2Router02(uniRouterAddress);

        // Determine token order in pair and set VY/USDC accordingly
        address token0 = uniPair.token0();
        address token1 = uniPair.token1();
        
        if (token0 == vyAddress) {
            vyToken = IERC20(token0);
            usdcToken = IERC20(token1);
            vyIsToken0 = true;
        } else if (token1 == vyAddress) {
            vyToken = IERC20(token1);
            usdcToken = IERC20(token0);
            vyIsToken0 = false;
        } else {
            revert VYTokenMismatch();
        }

        // Initialize indexes
        daxIndex = 1e18;
        uniIndex = 1e18;

        // Set default tier durations
        tierDurationSec[1] = 30 days;
        tierDurationSec[2] = 60 days;
        tierDurationSec[3] = 90 days;

        // Grant admin role
        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INITIALIZER - V3 (asset staking)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice One-shot V3 initializer — wires in WETH and seeds the asset
     *         registry. Called once per proxy after the V3 upgrade.
     * @dev Uses reinitializer(3). Caller must hold `ADMIN_ROLE`. The
     *      reinitializer modifier restricts this to a single successful call.
     *
     *      `varoAddress` MAY be `address(0)` at init time — VARO is allowed
     *      to be deployed after VSR is upgraded. Call `setVaro(...)` once VARO
     *      exists to grant `VARO_ROLE` and enable `registerVDAO`.
     */
    function initializeV3(
        address wethAddress,
        address varoAddress,
        address[] calldata initialAssets,
        uint256[] calldata initialMinStakes
    ) external reinitializer(3) onlyRole(ADMIN_ROLE) {
        if (wethAddress == address(0)) revert InvalidAddress();
        if (initialAssets.length != initialMinStakes.length) revert InvalidAmount();

        weth = IWETH(wethAddress);

        // VARO is optional at init — wire it later via setVaro when deployed.
        if (varoAddress != address(0)) {
            varo = varoAddress;
            _grantRole(VARO_ROLE, varoAddress);
            emit VaroUpdated(address(0), varoAddress);
        }

        for (uint256 i; i < initialAssets.length;) {
            _addAsset(initialAssets[i], initialMinStakes[i], false);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Shared internal helper for asset registration.
     * @dev Called by `initializeV3`, `addAsset`, and `registerVDAO`.
     *      Approves the asset to DAX for swap routing (skipped for USDC since
     *      USDC routes through Uniswap V2, not DAX).
     */
    function _addAsset(address asset, uint256 minStake, bool isVDAO) internal {
        if (asset == address(0)) revert InvalidAddress();
        if (assetConfig[asset].supported) revert AssetAlreadySupported();

        assetConfig[asset] = AssetConfig({
            supported: true,
            isVDAO: isVDAO,
            minStake: minStake
        });
        supportedAssets.push(asset);

        if (asset != address(usdcToken)) {
            IERC20(asset).forceApprove(address(dax), type(uint256).max);
        }

        if (isVDAO) {
            emit VDAORegistered(asset);
        } else {
            emit AssetAdded(asset, minStake);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS - V3 ASSET REGISTRY
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Add a non-VDAO asset to the staking registry.
     * @dev VDAO assets must come through `registerVDAO` (callable by VARO only).
     */
    function addAsset(address asset, uint256 minStake) external onlyRole(ADMIN_ROLE) {
        _addAsset(asset, minStake, false);
    }

    /**
     * @notice Mark an asset as unsupported. Existing stakes still work; no new
     *         stakes accepted. We do NOT remove from `supportedAssets[]` to
     *         preserve enumeration history; off-chain consumers filter by the
     *         `supported` flag.
     */
    function removeAsset(address asset) external onlyRole(ADMIN_ROLE) {
        if (!assetConfig[asset].supported) revert AssetNotSupported();
        assetConfig[asset].supported = false;
        emit AssetRemoved(asset);
    }

    /**
     * @notice Update the minimum stake amount for an asset.
     */
    function setMinStake(address asset, uint256 minStake) external onlyRole(ADMIN_ROLE) {
        if (!assetConfig[asset].supported) revert AssetNotSupported();
        assetConfig[asset].minStake = minStake;
        emit AssetMinStakeUpdated(asset, minStake);
    }

    /**
     * @notice Register a V-DAO token. Callable only by VARO inside its tier-3
     *         launch flow. Reverts on duplicate so the launch tx rolls back
     *         (V-DAO must exist in both DAX and VSR atomically, or neither).
     */
    function registerVDAO(address asset) external onlyRole(VARO_ROLE) {
        _addAsset(asset, 0, true);
    }

    /**
     * @notice Update the VARO address. Revokes `VARO_ROLE` from the old
     *         address and grants it to the new one.
     */
    function setVaro(address newVaro) external onlyRole(ADMIN_ROLE) {
        if (newVaro == address(0)) revert InvalidAddress();
        address oldVaro = varo;
        if (oldVaro == newVaro) return;
        if (oldVaro != address(0)) {
            _revokeRole(VARO_ROLE, oldVaro);
        }
        varo = newVaro;
        _grantRole(VARO_ROLE, newVaro);
        emit VaroUpdated(oldVaro, newVaro);
    }

    // setVyt/setVco/setWeth removed in v6 to save bytecode. These addresses
    // are wired in initializeV3 and updateable only via UUPS upgrade.

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier validTier(uint8 tierId) {
        if (tierId < 1 || tierId > 3) revert InvalidTierId();
        _;
    }

    modifier whenDepositsNotPaused() {
        if (depositsPaused) revert DepositsPaused();
        _;
    }

    modifier whenWithdrawalsNotPaused() {
        if (withdrawalsPaused) revert WithdrawalsPaused();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS - STAKE QUERIES
    // ═══════════════════════════════════════════════════════════════════════

    // V3.1: stake-query view helpers removed to recover bytecode for the
    // VY-insufficient → topUp fix (always 100% asset when pool is fine).
    // Frontends should iterate the 3 stake slots via the public auto-getter:
    //   stakes(user, 0..2) returns (active, tierId, unlockTime, daxCredits,
    //                                uniCredits, principalVY)
    // and derive: vdaxClaim = daxCredits * daxIndex() / 1e18; same for uni.
    // The withdraw guarantee is unchanged — user always receives principalVY.

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS - V3 ASSET STAKE QUERIES
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Return the full supported-asset list (off-chain enumeration).
     * @dev `assetStakes(user, stakeId)`, `nextAssetStakeId(user)`,
     *      `assetConfig(asset)`, and `supportedAssets(i)` are auto-getters.
     *      Yield queries (`pendingAssetYield`, accrual, time-remaining) live
     *      on VYO since it owns all yield bookkeeping.
     */
    function getSupportedAssets() external view returns (address[] memory) {
        return supportedAssets;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS - CREDIT/INDEX SYSTEM
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Convert LP tokens to credits
     * @param lpAmount Amount of LP tokens
     * @param index Current index (1e18 = 1:1)
     * @return credits Amount of credits
     */
    function _lpToCredits(
        uint256 lpAmount,
        uint256 index
    ) internal pure returns (uint256 credits) {
        return Math.mulDiv(lpAmount, 1e18, index);
    }

    /**
     * @notice Convert credits to LP tokens
     * @param credits Amount of credits
     * @param index Current index (1e18 = 1:1)
     * @return lpAmount Amount of LP tokens
     */
    function _creditsToLP(
        uint256 credits,
        uint256 index
    ) internal pure returns (uint256 lpAmount) {
        return Math.mulDiv(credits, index, 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS - TIER CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Set duration for a tier
     * @param tierId Tier ID (1, 2, or 3)
     * @param durationSec Duration in seconds
     */
    function setTierDuration(
        uint8 tierId,
        uint32 durationSec
    ) external onlyRole(ADMIN_ROLE) validTier(tierId) {
        if (durationSec < 30 days || durationSec > 365 days)
            revert InvalidDuration();

        uint32 oldDuration = tierDurationSec[tierId];
        tierDurationSec[tierId] = durationSec;

        emit TierDurationUpdated(tierId, oldDuration, durationSec);
    }

    /**
     * @notice Set Yield Officer contract address
     * @param yieldOfficerAddress Address of the Yield Officer
     */
    function setYieldOfficer(
        address yieldOfficerAddress
    ) external onlyRole(ADMIN_ROLE) {
        if (yieldOfficerAddress == address(0)) revert InvalidAddress();

        address oldOfficer = address(yieldOfficer);
        yieldOfficer = IYieldOfficer(yieldOfficerAddress);

        emit YieldOfficerUpdated(oldOfficer, yieldOfficerAddress);
    }

    /**
     * @notice Set Buyback Officer address (receives excess VY when vyOut > principal)
     * @param buybackOfficerAddress Address of the Buyback Officer
     */
    function setBuybackOfficer(
        address buybackOfficerAddress
    ) external onlyRole(ADMIN_ROLE) {
        if (buybackOfficerAddress == address(0)) revert InvalidAddress();

        address oldOfficer = buybackOfficer;
        buybackOfficer = buybackOfficerAddress;

        emit BuybackOfficerUpdated(oldOfficer, buybackOfficerAddress);
    }

    /**
     * @notice Set the Reserve Yield Officer (VRYO) heartbeat target.
     * @dev Pass `address(0)` to disable the heartbeat. The router address must
     *      hold `STAKING_ROUTER_ROLE` on the new VRYO; otherwise heartbeats
     *      will revert internally and only emit `VryoHeartbeatFailed`.
     * @param vryoAddress Address of the Reserve Yield Officer (or zero to disable)
     */
    function setVryo(address vryoAddress) external onlyRole(ADMIN_ROLE) {
        address oldVryo = address(vryo);
        vryo = IValinityReserveYieldOfficer(vryoAddress);
        emit VryoUpdated(oldVryo, vryoAddress);
    }

    /**
     * @notice Ping VRYO to realign yield deployments with current staked VY.
     * @dev Wrapped in try/catch so a misconfigured or paused VRYO can never
     *      block user stake/unstake. No-op when VRYO is unset.
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

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS - POOL CALCULATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate allocation of VY between DAX and the Uniswap V2 pair.
     * @dev V3: weighted by each venue's current VY reserve, NOT equal-per-pool.
     *      DAX pools now hold different VY/asset ratios, so equal weighting
     *      would over-allocate to small pools. VSR sends `V_dax` to DAX as a
     *      lump sum; DAX internally distributes proportionally across its
     *      pools based on each pool's `reserveVY` (see ValinityDAX.depositVYOnly).
     *
     *      Cold-start fallback: if both venues read zero VY reserves, fall
     *      back to the original equal-per-pool split to avoid divide-by-zero
     *      and still produce sensible allocation on a fresh deployment.
     * @param V Total VY amount to deposit
     * @return V_dax Amount allocated to DAX
     * @return V_uni Amount allocated to Uniswap
     */
    function _calculateAllocation(
        uint256 V
    ) internal view returns (uint256 V_dax, uint256 V_uni) {
        (uint112 r0, uint112 r1, ) = uniPair.getReserves();
        uint256 rUniVY = vyIsToken0 ? uint256(r0) : uint256(r1);
        uint256 rDaxVY = dax.getTotalVYReserves();
        uint256 totalVY = rUniVY + rDaxVY;

        if (totalVY == 0) {
            // Cold-start: equal weight across (DAX pools + Uniswap)
            uint256 totalPositions = dax.getNumPools() + 1;
            V_uni = V / totalPositions;
            V_dax = V - V_uni;
            return (V_dax, V_uni);
        }

        V_uni = Math.mulDiv(V, rUniVY, totalVY);
        V_dax = V - V_uni;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS - POOL CALCULATIONS
    // ═══════════════════════════════════════════════════════════════════════
    // Note: `estimateUniLPFromZap` (V2 frontend quote helper) was removed in
    // V3 to recover ~2KB of bytecode for the appreciation-capture withdraw
    // path. Frontends should compute zap previews off-chain using `uniPair`
    // reserves + `uniPair.totalSupply()` + the formula in `_zapIntoUniswap`.

    /**
     * @notice Calculate optimal swap amount for Uniswap V2 zap
     * @dev Formula: swap = (sqrt(rVY*rVY*1997*1997 + 3988000*B*rVY) - 1997*rVY) / 1994
     * @param B Amount of VY to zap into pool
     * @param rVY Reserve of VY in the pool
     * @return swapAmount Optimal amount of VY to swap to USDC
     */
    function _calculateOptimalSwap(
        uint256 B,
        uint256 rVY
    ) internal pure returns (uint256 swapAmount) {
        // Quadratic solution for optimal Uniswap V2 single-sided zap (0.3% fee)
        // s = (sqrt(3988009·r² + 3988000·r·B) − 1997·r) / 1994
        // Safe from overflow for reserves up to ~1.7e17 tokens (170 quadrillion)
        uint256 a = rVY * rVY * 3988009;
        uint256 b = 3988000 * B * rVY;
        uint256 sqrtResult = Math.sqrt(a + b);
        uint256 rScaled = 1997 * rVY;

        if (sqrtResult <= rScaled) {
            return B / 2;
        }

        swapAmount = (sqrtResult - rScaled) / 1994;

        // Safety cap: swap cannot exceed input
        if (swapAmount > B) {
            swapAmount = B / 2;
        }
    }

    /**
     * @notice Execute Uniswap V2 zap: swap VY → USDC, then add liquidity
     * @param V_uni Amount of VY to zap
     * @return uniMinted Amount of UNI-LP tokens received
     */
    function _zapIntoUniswap(
        uint256 V_uni
    ) internal returns (uint256 uniMinted) {
        // Get current reserves (order depends on token sort)
        (uint112 reserve0, uint112 reserve1, ) = uniPair.getReserves();
        uint256 rVY = vyIsToken0 ? uint256(reserve0) : uint256(reserve1);

        // Calculate optimal swap amount
        uint256 swapAmount = _calculateOptimalSwap(V_uni, rVY);

        // Guard against degenerate swap amounts (e.g., near-empty pool)
        if (swapAmount < 1e12) {
            swapAmount = V_uni / 2;
        }

        // Step 1: Swap VY → USDC
        address[] memory path = new address[](2);
        path[0] = address(vyToken);
        path[1] = address(usdcToken);

        uint256[] memory amounts = uniRouter.swapExactTokensForTokens(
            swapAmount,
            0, // Accept any amount (slippage handled at deposit level)
            path,
            address(this),
            block.timestamp + 300 // 5 min deadline
        );

        uint256 usdcOut = amounts[1];

        // Step 2: Add liquidity with remaining VY + received USDC
        uint256 vyAdd = V_uni - swapAmount;

        uint256 uniBefore = uniLP.balanceOf(address(this));

        uniRouter.addLiquidity(
            address(vyToken),
            address(usdcToken),
            vyAdd,
            usdcOut,
            0, // Accept any amount
            0, // Accept any amount
            address(this),
            block.timestamp + 300
        );

        uniMinted = uniLP.balanceOf(address(this)) - uniBefore;

        // Step 3: Sweep any leftover USDC/VY to BuybackOfficer
        // Router should hold 0 raw VY/USDC between operations — anything here is leftover
        if (buybackOfficer != address(0)) {
            uint256 leftoverUSDC = usdcToken.balanceOf(address(this));
            if (leftoverUSDC > 1000) { // > 0.001 USDC — skip dust to avoid swap revert
                address[] memory revPath = new address[](2);
                revPath[0] = address(usdcToken);
                revPath[1] = address(vyToken);

                uniRouter.swapExactTokensForTokens(
                    leftoverUSDC,
                    0,
                    revPath,
                    address(this),
                    block.timestamp + 300
                );
            }

            uint256 leftoverVY = vyToken.balanceOf(address(this));
            if (leftoverVY > 0) {
                vyToken.safeTransfer(buybackOfficer, leftoverVY);
                emit ZapLeftoverSent(leftoverUSDC, leftoverVY);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS - V3 ASSET STAKING
    // ═══════════════════════════════════════════════════════════════════════

    // _getPoolReservesForAsset, _swapVYToAsset, _pullAndSellForAsset moved
    // to VYO. VSR no longer touches VYT or VCO — VYO does, via topUpAssetWithdrawal.

    /**
     * @notice USDC → UNI-LP via the Uniswap V2 VY/USDC pool.
     * @dev Half-swap USDC→VY then addLiquidity. Leftover VY/USDC dust is
     *      swept to BuybackOfficer (mirrors `_zapIntoUniswap`). Assumes
     *      VSR holds 0 raw VY/USDC between ops — the leftover sweep would
     *      otherwise pull in unrelated balances.
     */
    function _zapUSDCIntoUniswap(
        uint256 usdcAmount
    ) internal returns (uint256 uniMinted) {
        (uint112 r0, uint112 r1, ) = uniPair.getReserves();
        uint256 rUSDC = vyIsToken0 ? uint256(r1) : uint256(r0);

        uint256 swapAmount = _calculateOptimalSwap(usdcAmount, rUSDC);
        if (swapAmount < 1e3 || swapAmount >= usdcAmount) {
            swapAmount = usdcAmount / 2;
        }

        address[] memory path = new address[](2);
        path[0] = address(usdcToken);
        path[1] = address(vyToken);
        uint256[] memory amounts = uniRouter.swapExactTokensForTokens(
            swapAmount, 0, path, address(this), block.timestamp + 300
        );

        uint256 uniBefore = uniLP.balanceOf(address(this));
        uniRouter.addLiquidity(
            address(vyToken),
            address(usdcToken),
            amounts[1],
            usdcAmount - swapAmount,
            0, 0,
            address(this),
            block.timestamp + 300
        );
        uniMinted = uniLP.balanceOf(address(this)) - uniBefore;

        // Sweep dust to BuybackOfficer (any VY/USDC left from imperfect
        // optimal-swap or addLiquidity ratio rounding).
        if (buybackOfficer != address(0)) {
            uint256 leftoverUSDC = usdcToken.balanceOf(address(this));
            if (leftoverUSDC > 1000) {
                address[] memory revPath = new address[](2);
                revPath[0] = address(usdcToken);
                revPath[1] = address(vyToken);
                uniRouter.swapExactTokensForTokens(
                    leftoverUSDC, 0, revPath, address(this), block.timestamp + 300
                );
            }
            uint256 leftoverVY = vyToken.balanceOf(address(this));
            if (leftoverVY > 0) {
                vyToken.safeTransfer(buybackOfficer, leftoverVY);
                emit ZapLeftoverSent(leftoverUSDC, leftoverVY);
            }
        }
    }

    // _settleAssetYield moved to VYO (settled via onAssetWithdraw + claimAssetYield).

    // ═══════════════════════════════════════════════════════════════════════
    // PUBLIC FUNCTIONS - DEPOSIT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit VY into a staking position
     * @dev Creates a new stake in the first available slot (0, 1, or 2)
     * @param tierId Tier selection (1=30d, 2=60d, 3=90d by default)
     * @param V Amount of VY to stake
     * @param minVdaxOut Minimum VDAX tokens expected (slippage protection)
     * @param minUniLPOut Minimum UNI-LP tokens expected (slippage protection)
     * @return stakeId The stake slot used (0, 1, or 2)
     */
    function depositStake(
        uint8 tierId,
        uint256 V,
        uint256 minVdaxOut,
        uint256 minUniLPOut
    )
        external
        nonReentrant
        whenDepositsNotPaused
        validTier(tierId)
        returns (uint8 stakeId)
    {
        // Validate minimum stake
        if (V < MIN_STAKE) revert BelowMinStake();

        // Allocation determines the per-leg amounts and which slippage gates
        // are active.
        (uint256 V_dax, uint256 V_uni) = _calculateAllocation(V);
        // V_uni leg routes through the PUBLIC Uniswap V2 pair → caller MUST
        // supply a non-zero floor or they can be sandwiched freely.
        // V_dax leg routes through the whitelisted VDAX → caller may pass 0;
        // no MEV path exists. (See feedback-vdax-is-private in memory.)
        if (V_uni > 0 && minUniLPOut == 0) revert SlippageExceeded();

        // Find available stake slot
        stakeId = MAX_STAKES; // Flag for "not found"
        for (uint8 i = 0; i < MAX_STAKES;) {
            if (!stakes[msg.sender][i].active) {
                stakeId = i;
                break;
            }
            unchecked { ++i; }
        }
        if (stakeId >= MAX_STAKES) revert MaxStakesReached();

        // Transfer VY from user
        vyToken.safeTransferFrom(msg.sender, address(this), V);

        // DAX leg: deposit VY-only
        uint256 vdaxMinted;
        uint256 daxCreditsAdd;

        if (V_dax > 0) {
            // Deposit VY into DAX (infinite approval set via adminSetApprovals)
            vdaxMinted = dax.depositVYOnly(V_dax, address(this));

            // Slippage check for VDAX (against the GROSS minted amount,
            // before the ecosystem lock — caller sees the pool's true mint).
            if (vdaxMinted < minVdaxOut) revert SlippageExceeded();

            // V4 PERMANENT LP LOCK: retain LOCK_BPS (1%) of minted VDAX in
            // this contract forever. Uncredited. `_syncIndexes` and
            // `adminExtract` must subtract `lockedVdaxLP` from the balance
            // basis so the lock never leaks back to users or admin.
            uint256 vdaxLock = (vdaxMinted * LOCK_BPS) / 10000;
            lockedVdaxLP += vdaxLock;
            vdaxMinted -= vdaxLock; // only the 99% remainder is credited

            // Convert (post-lock) VDAX to credits
            daxCreditsAdd = _lpToCredits(vdaxMinted, daxIndex);
        }

        // Uniswap leg: zap VY into liquidity
        uint256 uniMinted;
        uint256 uniCreditsAdd;

        if (V_uni > 0) {
            // Execute Uniswap zap
            uniMinted = _zapIntoUniswap(V_uni);

            // Slippage check for UNI-LP (against the GROSS amount, like VDAX).
            if (uniMinted < minUniLPOut) revert SlippageExceeded();

            // V4 PERMANENT LP LOCK: retain LOCK_BPS (1%) of UNI-LP forever.
            uint256 uniLock = (uniMinted * LOCK_BPS) / 10000;
            lockedUniLP += uniLock;
            uniMinted -= uniLock; // only the 99% remainder is credited

            // Convert (post-lock) UNI-LP to credits
            uniCreditsAdd = _lpToCredits(uniMinted, uniIndex);
        }

        // Create stake record and notify Yield Officer
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + tierDurationSec[tierId]);

        // Create stake record (cache storage pointer — single mapping lookup)
        Stake storage stake = stakes[msg.sender][stakeId];
        stake.active = true;
        stake.tierId = tierId;
        stake.unlockTime = endTime;
        stake.daxCredits = daxCreditsAdd;
        stake.uniCredits = uniCreditsAdd;
        stake.principalVY = V;

        // Update global totals
        totalDaxCredits += daxCreditsAdd;
        totalUniCredits += uniCreditsAdd;
        totalStakedVY += V;

        // Integrate with Yield Officer
        if (address(yieldOfficer) != address(0)) {
            yieldOfficer.onDeposit(
                msg.sender,
                stakeId,
                tierId,
                V,
                startTime,
                endTime
            );
        }

        // Ping VRYO so deployed reserves track the new staked VY total.
        // Failure-tolerant: stake must always succeed even if VRYO reverts.
        _pingVRYO();

        // Emit deposit event
        emit Deposit(
            msg.sender,
            stakeId,
            V,
            tierId,
            vdaxMinted,
            uniMinted,
            daxCreditsAdd,
            uniCreditsAdd
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PUBLIC FUNCTIONS - V3 ASSET DEPOSIT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Stake any supported asset (non-VY). Receives yield in the same
     *         asset, paid linearly per-second over the tier duration.
     * @dev USDC routes through Uniswap V2 (UNI-LP held); all other assets
     *      route through DAX (VDAX held). LP is burned at withdrawal.
     * @param asset Asset to stake. Must be registered via `addAsset` or `registerVDAO`.
     * @param amount Amount of asset to stake (asset's native units).
     * @param tier 1, 2, or 3 — determines lock duration and yield rate.
     * @param minLPOut Slippage protection on LP minted.
     * @return stakeId The newly-assigned stake ID for this user.
     */
    function depositAssetStake(
        address asset,
        uint256 amount,
        uint8 tier,
        uint256 minLPOut
    )
        external
        nonReentrant
        whenDepositsNotPaused
        validTier(tier)
        returns (uint256 stakeId)
    {
        // WETH is internal-only — users stake ETH via depositETHStake.
        if (asset == address(weth)) revert UseDepositETHStake();

        AssetConfig memory cfg = assetConfig[asset];
        if (!cfg.supported) revert AssetNotSupported();
        if (amount < cfg.minStake || amount == 0) revert BelowMinStake();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        return _createAssetStake(msg.sender, asset, amount, tier, minLPOut);
    }

    /**
     * @notice Stake native ETH (wrapped to WETH internally).
     * @dev `weth` must be a registered asset. Equivalent to wrapping ETH
     *      yourself and calling `depositAssetStake(weth, amount, tier, minLPOut)`.
     */
    function depositETHStake(
        uint8 tier,
        uint256 minLPOut
    )
        external
        payable
        nonReentrant
        whenDepositsNotPaused
        validTier(tier)
        returns (uint256 stakeId)
    {
        address wethAddr = address(weth);
        AssetConfig memory cfg = assetConfig[wethAddr];
        if (!cfg.supported) revert AssetNotSupported();
        if (msg.value < cfg.minStake || msg.value == 0) revert BelowMinStake();

        weth.deposit{value: msg.value}();
        return _createAssetStake(msg.sender, wethAddr, msg.value, tier, minLPOut);
    }

    /**
     * @notice Shared core stake-creation logic. Assumes asset is already in
     *         this contract's balance.
     */
    function _createAssetStake(
        address user,
        address asset,
        uint256 amount,
        uint8 tier,
        uint256 minLPOut
    ) internal returns (uint256 stakeId) {
        // Convert asset → LP per route
        uint256 lpAmount;
        bool isUniLP;
        if (asset == address(usdcToken)) {
            lpAmount = _zapUSDCIntoUniswap(amount);
            isUniLP = true;
        } else {
            uint256 vyOut = dax.swapExactIn(
                dax.assetToPoolId(asset), asset, amount, 0, address(this)
            );
            lpAmount = dax.depositVYOnly(vyOut, address(this));
        }
        if (lpAmount < minLPOut) revert SlippageExceeded();

        stakeId = nextAssetStakeId[user]++;
        uint64 unlockTime = uint64(block.timestamp + tierDurationSec[tier]);

        assetStakes[user][stakeId] = AssetStake({
            active: true,
            isUniLP: isUniLP,
            asset: asset,
            unlockTime: unlockTime,
            principalAsset: amount,
            lpAmount: lpAmount
        });

        totalPrincipalByAsset[asset] += amount;
        unchecked { ++totalAssetStakesActive; }

        // VYO owns all yield bookkeeping for asset stakes — hard-required.
        // Without it the stake would accrue no yield and have no withdrawal
        // top-up coverage, which is unrecoverable for that stake.
        IYieldOfficer yo = yieldOfficer;
        if (address(yo) == address(0)) revert YieldOfficerRequired();
        yo.onAssetDeposit(user, stakeId, asset, amount, tier, unlockTime);

        _pingVRYO();
        emit AssetStakeDeposited(user, stakeId, asset, amount, tier, lpAmount, isUniLP);
    }

    // claimAssetYield moved to VYO. Users call VYO directly for yield claims.

    // ═══════════════════════════════════════════════════════════════════════
    // PUBLIC FUNCTIONS - WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw a specific stake position with explicit slippage protection.
     * @dev Redeems VDAX and UNI-LP, swaps all assets to VY, pays user. The
     *      router (and YieldOfficer's top-up reserve) is sandwich-protected
     *      via `minVyOut`: if the gross VY recovered from LP redemptions is
     *      below this threshold the call reverts BEFORE YieldOfficer is asked
     *      to cover the shortfall.
     * @param stakeId Stake ID to withdraw (0, 1, or 2)
     * @param minVyOut Minimum gross VY recovered from LP redemptions (slippage floor)
     * @return vyOut Total VY paid to user (always equals principalVY)
     */
    function withdrawStake(
        uint8 stakeId,
        uint256 minVyOut
    )
        external
        nonReentrant
        whenWithdrawalsNotPaused
        returns (uint256 vyOut)
    {
        // Validate stakeId
        if (stakeId >= MAX_STAKES) revert InvalidStakeId();

        // Get stake reference
        Stake storage stake = stakes[msg.sender][stakeId];

        // Validate stake is active
        if (!stake.active) revert StakeNotActive();

        // Validate unlock time has passed
        if (block.timestamp < stake.unlockTime) revert StakeStillLocked();

        // Get credits and principal from this specific stake
        uint256 daxCreditsBurn = stake.daxCredits;
        uint256 uniCreditsBurn = stake.uniCredits;
        uint8 tierIdLocal = stake.tierId;
        uint256 principalVY = stake.principalVY; // Store principal for protection check

        // Validate has balance
        if (daxCreditsBurn == 0 && uniCreditsBurn == 0) revert NoBalance();

        // CRITICAL: Clear stake FIRST to prevent reentrancy
        stake.daxCredits = 0;
        stake.uniCredits = 0;
        stake.active = false;
        stake.tierId = 0;
        stake.unlockTime = 0;
        stake.principalVY = 0;

        // Update global totals — invariant-safe: each decrement matches
        // a prior increment of the same stake's contribution.
        unchecked {
            totalDaxCredits -= daxCreditsBurn;
            totalUniCredits -= uniCreditsBurn;
            totalStakedVY  -= principalVY;
        }

        // Convert credits to LP tokens
        uint256 vdaxBurn = _creditsToLP(daxCreditsBurn, daxIndex);
        uint256 uniBurn = _creditsToLP(uniCreditsBurn, uniIndex);

        // Process redemptions, swaps, and principal protection
        uint256 yieldReceived;
        (vyOut, yieldReceived) = _processWithdrawal(
            vdaxBurn,
            uniBurn,
            stakeId,
            principalVY,
            minVyOut
        );

        // Ping VRYO so deployed reserves track the reduced staked VY total.
        // Failure-tolerant: unstake must always succeed even if VRYO reverts.
        _pingVRYO();

        // Emit withdraw event
        emit Withdraw(
            msg.sender,
            stakeId,
            tierIdLocal,
            vdaxBurn,
            uniBurn,
            vyOut,
            yieldReceived
        );
    }

    /**
     * @notice Internal function to process withdrawal redemptions and swaps
     * @param vdaxBurn Amount of VDAX to burn
     * @param uniBurn Amount of UNI-LP to burn
     * @param stakeId Original stake ID for YieldOfficer callback
     * @param principalVY Original deposit amount for protection check
     * @return vyOut Total VY to return to user
     * @return yieldReceived Yield received from YieldOfficer
     */
    function _processWithdrawal(
        uint256 vdaxBurn,
        uint256 uniBurn,
        uint8 stakeId,
        uint256 principalVY,
        uint256 minVyOut
    ) private returns (uint256 vyOut, uint256 yieldReceived) {
        // Track VY balance before redemptions
        uint256 vyBefore = vyToken.balanceOf(address(this));

        // Redeem VDAX from DAX, convert all to VY
        if (vdaxBurn > 0) {
            // Withdraw from DAX (infinite approval set via adminSetApprovals)
            dax.withdraw(vdaxBurn, address(this));
        }

        // Redeem UNI-LP from Uniswap
        uint256 usdcReceived;

        if (uniBurn > 0) {
            // Remove liquidity (infinite approval set via adminSetApprovals)
            (, uint256 usdcFromUni) = uniRouter
                .removeLiquidity(
                    address(vyToken),
                    address(usdcToken),
                    uniBurn,
                    0, // Accept any amount
                    0, // Accept any amount
                    address(this),
                    block.timestamp + 300 // 5 min deadline
                );

            usdcReceived = usdcFromUni;
        }

        // Swap USDC to VY via Uniswap
        if (usdcReceived > 0) {
            address[] memory path = new address[](2);
            path[0] = address(usdcToken);
            path[1] = address(vyToken);

            uniRouter.swapExactTokensForTokens(
                usdcReceived,
                0, // Accept any amount
                path,
                address(this),
                block.timestamp + 300
            );
        }

        // Calculate total VY accumulated from LP redemptions
        vyOut = vyToken.balanceOf(address(this)) - vyBefore;

        // S1: enforce caller-supplied slippage floor BEFORE invoking
        // YieldOfficer.topUpPrincipal. Without this an attacker can sandwich
        // the LP redemptions and force YieldOfficer to cover the gap, draining
        // the system's principal-protection reserve at no cost to themselves.
        if (vyOut < minVyOut) revert SlippageExceeded();

        // ===== STEP 1: LIQUIDATE YIELD (SEPARATE FROM PRINCIPAL) =====
        // Cache the storage read once — used in step 1 (try) and step 2 (topUp).
        IYieldOfficer yo = yieldOfficer;
        if (address(yo) != address(0)) {
            try yo.onWithdraw(msg.sender, stakeId) returns (
                uint256 /* grossPaid */,
                uint256 userOut,
                uint256 /* feeOut */
            ) {
                // Yield paid directly to user by YieldOfficer; tracked here
                // only for event emission.
                yieldReceived = userOut;
            } catch {
                // YO failure must not block withdrawals
            }
        }

        // ===== STEP 2: PRINCIPAL SETTLEMENT (3 CASES) =====
        // Invariant: user ALWAYS receives EXACTLY principalVY.

        if (vyOut < principalVY) {
            // CASE 1: LOSS — YieldOfficer MUST cover shortfall
            uint256 shortfall = principalVY - vyOut;
            if (address(yo) == address(0)) revert PrincipalProtectionFailed();

            // Reverts if topUp fails — principal protection is guaranteed.
            yo.topUpPrincipal(msg.sender, stakeId, shortfall);

            // Recompute vyOut after top-up
            vyOut = vyToken.balanceOf(address(this)) - vyBefore;

            emit PrincipalShortfall(msg.sender, stakeId, shortfall);
        } else if (vyOut > principalVY) {
            // CASE 2: GAIN - Excess goes to BuybackOfficer
            uint256 excess = vyOut - principalVY;

            if (buybackOfficer != address(0)) {
                vyToken.safeTransfer(buybackOfficer, excess);
            }
            // If no buybackOfficer, excess stays in contract (admin can rescue)

            emit PrincipalExcess(msg.sender, stakeId, excess);
        }
        // CASE 3: vyOut == principalVY - Perfect match, no action needed

        // ===== STEP 3: PAY EXACTLY PRINCIPAL TO USER =====
        // User receives EXACTLY their principal (not more, not less)
        if (principalVY > 0) {
            vyToken.safeTransfer(msg.sender, principalVY);
        }

        // Return principalVY as vyOut (what user actually receives as principal)
        vyOut = principalVY;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PUBLIC FUNCTIONS - V3 ASSET WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw a matured asset stake.
     * @dev Invariant: total VALUE delivered to user == `principalAsset` (at
     *      the staked pool's current spot price). Two delivery modes:
     *
     *      A) HAPPY PATH — pool is deep enough to swap VY for the full
     *         missing asset via exact-out. User receives `principalAsset`
     *         entirely in the staked asset. Leftover VY → BBO.
     *
     *      B) MIXED PAYOUT — pool too thin OR LP-recovered VY insufficient
     *         for the exact-out swap. We do NOT dump VY into the shallow
     *         pool. Instead:
     *           - User gets all `assetFromBurn` we already have.
     *           - User gets `vyForGap` VY representing the remaining value
     *             at the pool's current spot (vyForGap = ceil(gap*rVY/rAsset)).
     *           - If our `vyAvail < vyForGap`, VYO `topUpAssetWithdrawal`
     *             covers the residual value as asset; user gets all `vyAvail`
     *             plus the topped-up asset.
     *         User can immediately swap the VY elsewhere for the staked asset
     *         (or anything else) — liquidity is never stuck.
     *
     *      Sequence: VYO yield settle → burn LP → try exact-out → branch
     *      to A or B → pay (asset+VY) → sweep any residual surplus → VRYO ping.
     *
     * @param stakeId Stake to withdraw.
     * @param minAssetFromLP Sandwich floor on asset gathered from LP burn +
     *                       any swap. Relevant only for USDC (Uni V2). Pass
     *                       `principalAsset` to require strict happy path
     *                       (revert into mixed payout); pass 0 to accept mixed.
     */
    function withdrawAssetStake(
        uint256 stakeId,
        uint256 minAssetFromLP
    )
        external
        nonReentrant
        whenWithdrawalsNotPaused
        returns (uint256 principalPaid)
    {
        AssetStake storage s = assetStakes[msg.sender][stakeId];
        if (!s.active) revert StakeNotActive();
        if (block.timestamp < s.unlockTime) revert StakeStillLocked();

        IYieldOfficer yo = yieldOfficer;
        if (address(yo) == address(0)) revert YieldOfficerRequired();

        address asset = s.asset;
        uint256 principalAsset = s.principalAsset;
        uint256 lpAmount = s.lpAmount;
        bool isUniLP = s.isUniLP;

        // CEI: clear stake before external calls
        s.active = false;
        s.lpAmount = 0;
        s.principalAsset = 0;
        unchecked {
            totalPrincipalByAsset[asset] -= principalAsset;
            --totalAssetStakesActive;
        }

        // VYO settles yield (paid directly to user by VYO)
        yo.onAssetWithdraw(msg.sender, stakeId);

        // Baselines for delta-accounting
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        uint256 vyBefore    = vyToken.balanceOf(address(this));

        // Burn LP
        if (isUniLP) {
            uniRouter.removeLiquidity(
                address(vyToken), address(usdcToken),
                lpAmount, 0, 0, address(this), block.timestamp + 300
            );
        } else {
            dax.withdraw(lpAmount, address(this));
        }
        // (Note: `_swapVYForExactAsset` and the zaps each compute their own
        //  deadline locally — single-use, no reuse benefit from hoisting.)

        uint256 vyAvail       = vyToken.balanceOf(address(this)) - vyBefore;
        uint256 assetFromBurn = IERC20(asset).balanceOf(address(this)) - assetBefore;

        // Try exact-out swap for the missing asset. Returns a tri-state so we
        // can distinguish "pool actually too thin" (→ mixed payout) from
        // "our VY balance was short" (→ topUp + 100% asset).
        SwapResult result = SwapResult.PoolTooThin; // default if we don't even try
        if (assetFromBurn < principalAsset) {
            uint256 need;
            unchecked { need = principalAsset - assetFromBurn; }
            result = _swapVYForExactAsset(asset, isUniLP, need, vyAvail);
        }

        uint256 assetAvail = IERC20(asset).balanceOf(address(this)) - assetBefore;
        if (assetAvail < minAssetFromLP) revert SlippageExceeded();

        uint256 assetToUser;
        uint256 vyToUser;

        if (assetAvail >= principalAsset) {
            // HAPPY PATH — pool delivered everything we need
            assetToUser = principalAsset;
        } else if (result == SwapResult.VyInsufficient) {
            // Pool was deep enough — VSR just didn't have enough VY of its
            // own. We already dumped all VY in at exact-in; ask VYO to top
            // up the residual asset gap so user STILL gets 100% asset.
            uint256 topUp;
            unchecked { topUp = principalAsset - assetAvail; }
            yo.topUpAssetWithdrawal(asset, topUp, address(this));
            uint256 newAvail = IERC20(asset).balanceOf(address(this)) - assetBefore;
            if (newAvail < principalAsset) revert SlippageExceeded();
            assetToUser = principalAsset;
        } else {
            // MIXED PAYOUT — pool truly too thin to absorb the swap.
            // Pay all asset we have + VY priced at the pool's spot to cover
            // the remaining principal value. If VY can't cover, VYO closes
            // the residual gap (then it's still mixed — user gets some VY too).
            uint256 rVY;
            uint256 rAsset;
            if (isUniLP) {
                (uint112 r0, uint112 r1, ) = uniPair.getReserves();
                rVY    = vyIsToken0 ? uint256(r0) : uint256(r1);
                rAsset = vyIsToken0 ? uint256(r1) : uint256(r0);
            } else {
                (, rVY, rAsset) = dax.getPoolReserves(dax.assetToPoolId(asset));
            }
            uint256 gap;
            unchecked { gap = principalAsset - assetAvail; }

            // VY equivalent to `gap` asset at current pool spot. If either
            // reserve is zero the pool is degenerate; force VYO topUp branch.
            uint256 vyForGap = (rAsset > 0 && rVY > 0)
                ? Math.mulDiv(gap, rVY, rAsset, Math.Rounding.Ceil)
                : type(uint256).max;

            if (vyForGap <= vyAvail) {
                assetToUser = assetAvail;
                vyToUser    = vyForGap;
            } else {
                uint256 vyValue = rVY > 0
                    ? Math.mulDiv(vyAvail, rAsset, rVY)
                    : 0;
                uint256 topUp;
                unchecked { topUp = gap - vyValue; }
                yo.topUpAssetWithdrawal(asset, topUp, address(this));
                uint256 newAvail = IERC20(asset).balanceOf(address(this)) - assetBefore;
                if (newAvail < assetAvail + topUp) revert SlippageExceeded();
                assetToUser = assetAvail + topUp;
                vyToUser    = vyAvail;
            }
        }

        // Pay user — asset leg (cache weth address: read once instead of twice)
        if (assetToUser > 0) {
            IWETH wethCached = weth;
            if (asset == address(wethCached)) {
                wethCached.withdraw(assetToUser);
                (bool ok, ) = msg.sender.call{value: assetToUser}("");
                if (!ok) revert ETHTransferFailed();
            } else {
                IERC20(asset).safeTransfer(msg.sender, assetToUser);
            }
        }
        // Pay user — VY leg (only on mixed payout)
        if (vyToUser > 0) {
            vyToken.safeTransfer(msg.sender, vyToUser);
        }

        // Sweep any residual surplus to BBO (asset over-delivery, leftover VY)
        address bbo = buybackOfficer;
        if (bbo != address(0)) {
            uint256 assetSurplus = IERC20(asset).balanceOf(address(this)) - assetBefore;
            if (assetSurplus > 0) IERC20(asset).safeTransfer(bbo, assetSurplus);
            uint256 vySurplus = vyToken.balanceOf(address(this)) - vyBefore;
            if (vySurplus > 0) vyToken.safeTransfer(bbo, vySurplus);
        }

        _pingVRYO();
        principalPaid = principalAsset;
        emit AssetStakeWithdrawn(
            msg.sender, stakeId, asset, principalAsset, assetToUser, vyToUser
        );
    }

    /// @notice Outcomes of an attempted exact-out swap in the staked asset's pool.
    enum SwapResult {
        Succeeded,       // exact-out delivered `need` asset, user gets 100% asset
        VyInsufficient,  // pool deep enough, but VSR's VY < required input → topUp asset to close gap
        PoolTooThin      // pool cannot deliver `need` at any price → mixed payout (asset + VY)
    }

    /**
     * @notice Swap VY for EXACTLY `need` asset, capped at `vyAvail` VY input.
     * @dev Returns a status the caller uses to decide between three exits:
     *      - Succeeded     → happy path, full asset payout
     *      - VyInsufficient → dump all VY exact-in (using deep pool we have);
     *                         caller asks VYO to top up the asset gap → 100% asset
     *      - PoolTooThin   → no swap; caller does mixed payout (asset + raw VY)
     *
     *      Uni V2: pre-flight reserve check, then `swapTokensForExactTokens`.
     *      DAX (zero fee): `in = ceil(rVY * need / (rAsset - need))`, then
     *      `swapExactIn` with that input and `need` as the floor.
     */
    function _swapVYForExactAsset(
        address asset,
        bool isUniLP,
        uint256 need,
        uint256 vyAvail
    ) internal returns (SwapResult) {
        if (isUniLP) {
            (uint112 r0, uint112 r1, ) = uniPair.getReserves();
            uint256 rIn  = vyIsToken0 ? uint256(r0) : uint256(r1);
            uint256 rOut = vyIsToken0 ? uint256(r1) : uint256(r0);

            if (rOut <= need) return SwapResult.PoolTooThin;

            address[] memory path = new address[](2);
            path[0] = address(vyToken);
            path[1] = address(usdcToken);
            uint256 deadline = block.timestamp + 300;

            // V2 fee-adjusted exact-in: floor(rIn*out*1000 / ((rOut-out)*997)) + 1.
            uint256 vyNeeded = Math.mulDiv(
                rIn * 1000, need, (rOut - need) * 997
            ) + 1;
            if (vyNeeded <= vyAvail) {
                uniRouter.swapTokensForExactTokens(need, vyAvail, path, address(this), deadline);
                return SwapResult.Succeeded;
            }
            // Pool fine but VSR-VY short — dump all VY in, caller tops up.
            if (vyAvail > 0) {
                uniRouter.swapExactTokensForTokens(vyAvail, 0, path, address(this), deadline);
            }
            return SwapResult.VyInsufficient;
        } else {
            uint256 poolId = dax.assetToPoolId(asset);
            (, uint256 rVY, uint256 rAsset) = dax.getPoolReserves(poolId);

            if (rAsset <= need) return SwapResult.PoolTooThin;

            uint256 vyNeeded = Math.mulDiv(
                rVY, need, rAsset - need, Math.Rounding.Ceil
            );
            if (vyNeeded <= vyAvail) {
                dax.swapExactIn(
                    poolId, address(vyToken), vyNeeded, need, address(this)
                );
                return SwapResult.Succeeded;
            }
            if (vyAvail > 0) {
                dax.swapExactIn(
                    poolId, address(vyToken), vyAvail, 0, address(this)
                );
            }
            return SwapResult.VyInsufficient;
        }
    }


    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS - APPROVALS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Set infinite approvals for trusted protocol contracts (DAX, UniswapRouter)
     * @dev Must be called once after deployment/upgrade. Saves ~77k gas per deposit
     *      and ~72k gas per withdrawal by eliminating per-tx approve calls.
     *      Safe because this contract is the spender and targets are immutable protocol contracts.
     */
    function adminSetApprovals() external onlyRole(ADMIN_ROLE) {
        vyToken.forceApprove(address(dax), type(uint256).max);
        vyToken.forceApprove(address(uniRouter), type(uint256).max);
        usdcToken.forceApprove(address(uniRouter), type(uint256).max);
        vdaxToken.forceApprove(address(dax), type(uint256).max);
        uniLP.forceApprove(address(uniRouter), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS - PAUSE & EMERGENCY
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Pause or unpause deposits and/or withdrawals
     * @param _depositsPaused Whether to pause deposits
     * @param _withdrawalsPaused Whether to pause withdrawals
     */
    function adminPause(
        bool _depositsPaused,
        bool _withdrawalsPaused
    ) external onlyRole(ADMIN_ROLE) {
        depositsPaused = _depositsPaused;
        withdrawalsPaused = _withdrawalsPaused;

        emit AdminPause(_depositsPaused, _withdrawalsPaused);
    }

    /**
     * @notice Extract a percentage of LP tokens for rebalancing
     * @dev Automatically syncs indexes after extraction (atomic operation).
     *      V4: subtracts `lockedVdaxLP` / `lockedUniLP` from the extractable
     *      basis — the permanent ecosystem lock CANNOT be extracted by admin.
     * @param bps Basis points to extract (e.g., 1000 = 10%) of distributable LP
     * @param to Address to receive extracted LP tokens
     */
    function adminExtract(
        uint16 bps,
        address to
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (bps == 0 || bps > 10000) revert InvalidAmount();

        // Extract is computed against the DISTRIBUTABLE balance (balance minus
        // the permanent ecosystem lock). The lock stays untouchable.
        uint256 vdaxBalance = vdaxToken.balanceOf(address(this));
        uint256 uniBalance = uniLP.balanceOf(address(this));
        uint256 distVdax = vdaxBalance > lockedVdaxLP ? vdaxBalance - lockedVdaxLP : 0;
        uint256 distUni  = uniBalance  > lockedUniLP  ? uniBalance  - lockedUniLP  : 0;

        uint256 vdaxOut = (distVdax * bps) / 10000;
        uint256 uniOut = (distUni * bps) / 10000;

        // Transfer LP tokens to recipient
        if (vdaxOut > 0) {
            vdaxToken.safeTransfer(to, vdaxOut);
        }
        if (uniOut > 0) {
            uniLP.safeTransfer(to, uniOut);
        }

        emit AdminExtract(bps, vdaxOut, uniOut);

        // Automatically sync indexes after extraction
        _syncIndexes();
    }

    /**
     * @notice Synchronize indexes based on current LP balances
     * @dev Called automatically by adminExtract. Can also be called manually
     *      for edge cases (e.g., LP tokens deposited directly to contract)
     */
    function adminSyncIndexes() external onlyRole(ADMIN_ROLE) {
        _syncIndexes();
    }

    /**
     * @notice Internal function to sync indexes
     * @dev Only updates indexes when both credits and DISTRIBUTABLE balance
     *      are non-zero. V4: subtracts the permanent ecosystem lock from each
     *      balance so the lock is invisible to user credits — otherwise the
     *      first sync after a deposit would silently distribute the locked
     *      LP back to existing users via an inflated index.
     */
    function _syncIndexes() private {
        // Subtract permanent locks: only the DISTRIBUTABLE portion backs credits.
        uint256 vdaxBalance = vdaxToken.balanceOf(address(this));
        uint256 uniBalance  = uniLP.balanceOf(address(this));
        uint256 distVdax = vdaxBalance > lockedVdaxLP ? vdaxBalance - lockedVdaxLP : 0;
        uint256 distUni  = uniBalance  > lockedUniLP  ? uniBalance  - lockedUniLP  : 0;

        if (totalDaxCredits > 0 && distVdax > 0) {
            daxIndex = Math.mulDiv(distVdax, 1e18, totalDaxCredits);
        }
        if (totalUniCredits > 0 && distUni > 0) {
            uniIndex = Math.mulDiv(distUni, 1e18, totalUniCredits);
        }

        emit AdminSync(daxIndex, uniIndex);
    }

    /**
     * @notice Rescue tokens sent to contract by mistake
     * @dev Cannot rescue VDAX or UNI-LP (protected user funds)
     * @param token Address of token to rescue
     * @param to Address to receive tokens
     * @param amount Amount to rescue
     */
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        // Prevent rescuing user LP tokens
        if (token == address(vdaxToken)) revert InvalidAddress();
        if (token == address(uniLP)) revert InvalidAddress();

        // Allow rescuing other tokens (including VY, USDC, or other assets)
        IERC20(token).safeTransfer(to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // UUPS UPGRADE AUTHORIZATION
    // ═══════════════════════════════════════════════════════════════════════

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE GAP
    // ═══════════════════════════════════════════════════════════════════════

    // V2: `vryo` packed into existing slot — no gap consumed.
    // V3: asset-staking storage consumed 8 slots (assetStakes, nextAssetStakeId,
    //     assetConfig, supportedAssets, totalPrincipalByAsset,
    //     totalAssetStakesActive, weth, varo). Gap 39 → 31.
    // V4: ecosystem LP lock consumed 2 slots (lockedVdaxLP, lockedUniLP).
    //     Gap 31 → 29.
    uint256[29] private __gap;
}
