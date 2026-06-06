// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {VAROReferralSettleLib} from "./VAROReferralSettleLib.sol";
interface IWETH9 {
    function deposit() external payable;
}

interface IValinityVDAOFactory {
    /// @dev The factory DERIVES the final name/symbol from the base inputs +
    ///      parent/layer, enforces + reserves FCFS uniqueness, and bakes its OWN
    ///      `veo`/`mainDax` into the immutable token — VARO supplies neither the
    ///      derived strings nor any permanent wiring. Returns the derived strings
    ///      so VARO can record/emit them.
    function launch(
        string  calldata baseName,
        string  calldata baseSymbol,
        uint256 totalSupply_,
        address creator_,
        bytes32 logoCID_,
        address parent_,
        uint8   layer_
    ) external returns (address vdao, string memory name_, string memory symbol_);

    /// @dev Derives the final layer name/symbol (string concat lives here, off
    ///      VARO). Returns inputs verbatim for a base launch (parent==0/layer<=1).
    function previewNames(
        string  calldata baseName,
        string  calldata baseSymbol,
        address parent,
        uint8   layer
    ) external view returns (string memory name_, string memory symbol_);

    /// @dev Reserve a name/symbol for an externally-deployed V-DAO (VGC bootstrap),
    ///      keeping the factory the single uniqueness authority.
    function reserveName(string calldata name_, string calldata symbol_) external;
}

/// @notice Minimal view into the VDAO DAX (sibling AMM that holds every V-DAO's
///         non-VY "second leg"). VARO seeds pools at launch (POOL_CREATOR_ROLE)
///         and tops them up permissionlessly via {donate} at claim/partner time.
interface IValinityVDAODAX {
    function addPool(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) external returns (uint256 poolId);

    function donate(uint256 poolId, address token, uint256 amount) external;
}


interface IValinityVSR {
    /// @dev Callable only by VARO (holder of `VARO_ROLE` on VSR). Adds the
    ///      newly-launched V-DAO to VSR's stakeable asset registry so users
    ///      can deposit it for staking rewards.
    function registerVDAO(address asset) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// External minimal interfaces
// ─────────────────────────────────────────────────────────────────────────────

interface IVYT {
    function pullTokens(address recipient, uint256 amount) external returns (uint256 minted);
}

interface IVCO {
    function addToHighestLTVFCap(uint256 amount) external;
}

interface IVEO {
    function cumulativeUserFeeVY(address user) external view returns (uint256);
    function register(address trader) external;
    function registerVDAO(address vdao, address creator, uint256 daxPoolId, address pairAsset) external;
}

interface IVLO {
    function cumulativeInterestPaidVY(address borrower) external view returns (uint256);
}

interface IVYO {
    function totalYieldClaimedVY(address user) external view returns (uint256);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IValinityDAX {
    function swapExactIn(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    function addPool(
        address asset,
        uint256 vySeed,
        uint256 assetSeed
    ) external returns (uint256 poolId);

    function assetToPoolId(address asset) external view returns (uint256);

    /// @dev Pools are re-indexed on removal, so pool ids are NOT stable. Always
    ///      resolve live via assetToPoolId; `hasPool` disambiguates the valid
    ///      pool-id-0 case from "asset not listed" (both read 0 from assetToPoolId).
    function hasPool(address asset) external view returns (bool);

    function getPoolReserves(uint256 poolId)
        external view returns (address asset, uint256 reserveVY, uint256 reserveAsset);
}

interface ICCTPTokenMessenger {
    function depositForBurn(
        uint256 amount,
        uint32  destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);
}

interface IReferrerBuilderFactory {
    function predictBuilder(address referrer) external view returns (address);
}

interface IKeeperRewards {
    function beginReward() external;
    function payReward(address keeper) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// ValinityAllianceRegistrationOfficer (VARO)
// ─────────────────────────────────────────────────────────────────────────────
//
// Replaces the planned VRO. Four-tier paid access ladder; each tier executes
// its action atomically with payment. VARO never holds VY between txs.
//
//   T1  $0.50  Register on VEO            USDC→VY V2 buyback (or ETH→VY VDAX)
//                                          → VBBO. Binds caller to referrer.
//   T2  $10    Activate as a referrer     USDC→VY V2 or ETH→VY VDAX → VBBO.
//                                          Caller's bound referees start
//                                          accruing credits at 50% bps.
//   T3  $110   HL builder subscription    $100 USDC CCTP → predicted V_R on
//                                          HyperEVM; $10 → VY → VBBO.
//   T4  $2000  Launch a V-DAO             Pay in USDC/WBTC/ETH/PAXG.
//                                          BASE/LAYER launch: 45% supply + VY
//                                          → main-VDAX VY/V-DAO leg; 45% supply
//                                          + the second token → VDAO DAX leg
//                                          (asset for base; bought parent V-DAO
//                                          for a layer); 10% V-DAO → creator.
//                                          bps jump to 95% across all sources.
//                                          Auto-bundles T3 if below T3 (+$100).
//
//   PARTNER       Affiliate of a V-DAO     USDC only. A partner is a normal
//                 (no token)               T2/T3 buyer bound to a V-DAO instead
//                                          of the house, given the T4 payout
//                                          treatment. Two modes:
//                                            withBuilder=false → $10 (T2): VY →
//                                              VBBO, no builder. Gate < T2.
//                                            withBuilder=true  → $110 (T3): $100
//                                              CCTP → builder, $10 → VBBO.
//                                              Gate < T3.
//                                          Either → terminal T4 bound to target;
//                                          95% bps; at CLAIM their VY buys the
//                                          target → 50% to them + 50% donated to
//                                          its DAX leg. A no-builder partner can
//                                          later `fundMyBuilder` ($100) for perps.
//
// USD-denominated tier prices. USDC payments are 1:1. Non-USDC payments are
// sized via `_usdcToAsset`, which composes two instantaneous spot reads:
//   asset/VY on VDAX (private, sandwich-resistant) × VY/USDC on V2.
// No TWAP. Callers pass slippage bounds to cap V2-leg drift.
//
// Universal credit model: every fee source reports VY-denominated amounts to
// VARO. VARO computes `bps[tier][source] * delta` and credits
// `pendingVY[referrer]`. PULL sources (VEO, VLO, VYO) advance per-(referee,
// source) checkpoints; PUSH source (VPO HL builder via
// `notifyReferrerPerpCredit`) calls the notify entry with the delta directly.
//
// VPO integration (single contract, one entry):
//   HL builder fees from a T3+ referrer's invitee trades accumulate on the
//   referrer's HyperEVM Valinity Builder, drain back to L1 through the perp
//   pipeline, end up at VPO L1 as VY. VPO L1 then calls
//   `notifyReferrerPerpCredit(referrer, vyAmount)`; VARO credits the referrer
//   at the bps for their tier. T4 referrers' credit routes through their
//   V-DAO at claim time (see payout split below).
//
// Claim is two explicit user-facing functions with an auto-paginated UX:
//   - `settleMine()`  — walks up to MAX_SETTLE_PER_CALL invitees per call;
//                       sets `hasSettled` only once the full subtree is
//                       covered. Whales loop this until done.
//   - `claimMine()`   — gated by `hasSettled`; pays out `pendingVY`. T4
//                       referrers' VY buys the V-DAO they point at on the VDAX,
//                       then splits: standard = 50% to them + 50% donated to its
//                       VDAO DAX leg; VGC = 100% donated. T2/T3 receive plain VY.
// Frontend reads: `hasSettled(addr)` to gate the Claim button,
//                  `rewardsSummary(addr)` for available/claimed/total.
// ─────────────────────────────────────────────────────────────────────────────

contract ValinityAllianceRegistrationOfficer is
    UUPSUpgradeable,
    AccessControl,
    ReentrancyGuardTransient,
    Initializable
{
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // ROLES & CONSTANTS
    // ─────────────────────────────────────────────────────────────────────────

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Granted by admin to trusted revenue contracts that PUSH invitee
    ///         revenue into VARO via {notifyInviteeRevenue}. The pusher reports
    ///         an INVITEE + amount; VARO credits that invitee's inviter
    ///         (`referredBy`) — same direction as the PULL sources, just pushed.
    bytes32 public constant REVENUE_PUSHER_ROLE = keccak256("REVENUE_PUSHER_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;

    // Hard caps per source for forward-only bps setters. Protocol always
    // retains at least 1% on every fee source — referrals can never zero
    // out the buyback / treasury cut. (Launch values stay 95/95/95/9; the caps
    // give headroom to raise via setBpsVDAO/setBpsStandard without an upgrade.)
    uint256 public constant MAX_BPS_VYO    = 990;    // 9.9% on yield
    uint256 public constant MAX_BPS_OTHER  = 9_900;  // 99% on trading / interest / perps

    // Source IDs (uint8). Indexed into per-(referee, source) checkpoints.
    uint8 public constant SRC_VEO_TRADING   = 1;
    uint8 public constant SRC_VLO_INTEREST  = 2;
    uint8 public constant SRC_VPO_HL_BLDR   = 4; // push, per-referrer (no checkpoint)
    uint8 public constant SRC_VYO_YIELD     = 5; // PULL: yield claimed on VYO (live — bind snapshots it, settle/sweep credit it)
    uint8 public constant SRC_REVENUE       = 6; // PUSH: generic invitee revenue (referredBy lookup); credited at the "other" 50/95 rate

    /// @notice Max invitees that one `settleMine` call walks. Frontends loop
    ///         `settleMine` until `hasSettled[user]` becomes true.
    uint256 public constant MAX_SETTLE_PER_CALL = 300;

    /// @notice Minimum referees a single `sweep` call must process — unless the
    ///         call completes the current lap. Bounds keeper-reward farming via
    ///         many tiny batches; mid-lap dust calls below this revert.
    uint256 public constant MIN_SWEEP_BATCH = 50;

    /// @notice Cooldown between keeper sweep laps: one full lap per 24h.
    ///         A constant (not admin-tunable) to fit under EIP-170.
    uint256 public constant DEFAULT_SWEEP_COOLDOWN = 24 hours;

    uint256 public constant T4_VDAO_TO_DAX_POOL_BPS   = 4_500; // 0.45·S → VY leg on main VDAX
    uint256 public constant T4_VDAO_TO_SECOND_LEG_BPS = 4_500; // 0.45·S → second leg on the VDAO DAX
    uint256 public constant T4_VDAO_TO_CREATOR_BPS    = 1_000; // 0.10·S → creator

    // Pair-asset choices for T4 V-DAO launch.
    uint8 public constant ASSET_USDC = 1;
    uint8 public constant ASSET_WBTC = 2;
    uint8 public constant ASSET_ETH  = 3; // resolves to WETH internally
    uint8 public constant ASSET_PAXG = 4;

    // ─────────────────────────────────────────────────────────────────────────
    // STORAGE
    // ─────────────────────────────────────────────────────────────────────────

    // Core protocol references.
    IERC20  public vy;
    IERC20  public usdc;
    IVYT    public vyt;
    IVCO    public vco;
    address public vyo;             // VYO — PULL source for SRC_VYO_YIELD
    IVEO    public veo;
    IVLO    public vlo;
    address public vpo;             // VPO L1 — sole caller of notifyReferrerPerpCredit
    address public vbbo;            // Buyback Officer — final sink for all VY buybacks
    IValinityDAX public vdax;
    IUniswapV2Pair public vyUsdcV2Pool;
    IUniswapV2Router02 public uniV2Router; // V2 router for USDC↔VY swap legs
    IReferrerBuilderFactory public hlFactory; // HL referrer-builder factory (predictBuilder only)
    ICCTPTokenMessenger public cctp;
    uint32  public cctpHLDomain;            // CCTP destination domain id for HyperEVM
    bool    public vyIsToken0;              // V2 VY/USDC pair orientation — packs with cctp slot
    bool    public paused;                  // global circuit breaker — also packs with cctp slot
    uint256 public cctpActivationUSDC;      // USDC bridged on T3 (default 100e6)
    IValinityVDAOFactory public vdaoFactory; // Tier 4 V-DAO deployer
    IValinityVSR public vsr;                 // V-DAO staking registry
    IValinityVDAODAX public vdaoDax;         // sibling AMM holding every V-DAO's second (non-VY) leg

    /// @notice Default referrer for direct-traffic users (T1 with referrer=0).
    /// @dev    REQUIRED non-zero at init. Intended to be the T4 V-DAO creator
    ///         (the VGC Treasury). All direct-traffic referees bind to this
    ///         address, so their fees credit it at the V-DAO bps table and
    ///         route through its V-DAO at claim time.
    address public house;

    // ─── Reserve-asset registry (USDC/WBTC/ETH/PAXG) ─────────────────────────
    // Used by:
    //   1. ETH path of T1/T2 (WETH only)
    //   2. T4 V-DAO launch (caller picks one of the four to pair against)
    // Only the asset ADDRESS is stored — VDAX <asset>/VY pool ids are NOT cached
    // (the DAX re-indexes pools on removal, so VARO resolves them live via
    // `_daxPoolId` on every read/swap, like the other officers).
    address public weth;
    address public wbtc;
    address public paxg;

    // Tier bps — STANDARD (applies to T2/T3 referrers).
    uint16 public vyoYieldBps;
    uint16 public veoTradingBps;
    uint16 public vloInterestBps;
    uint16 public vpoHLBuilderBps;

    // Tier bps — V-DAO (applies to T4 referrers; default 9500 = 95%).
    // Credits accrue at the higher rate from the moment a referrer reaches T4
    // and route through their V-DAO at claim time.
    uint16 public vyoYieldBpsVDAO;
    uint16 public veoTradingBpsVDAO;
    uint16 public vloInterestBpsVDAO;
    uint16 public vpoHLBuilderBpsVDAO;

    // Tier prices (USDC raw units, 1e6). USD-denominated; non-USDC payments
    // are sized via `_usdcToAsset` from VDAX <asset>/VY × V2 VY/USDC spot.
    uint256 public tier1Usdc;
    uint256 public tier2Usdc;
    uint256 public tier3Usdc; // includes the T3 CCTP carve
    uint256 public tier4Usdc; // V-DAO launch price (paid in chosen asset)

    // Tier registry.
    mapping(address => uint8) public tier;

    // Referral graph.
    mapping(address => address) public referredBy;
    mapping(address => address[]) private _referees;

    // Per-(referee, sourceId) cumulative checkpoint.
    mapping(address => mapping(uint8 => uint256)) public checkpoints;

    // Per-referrer accounting.
    mapping(address => uint256) public pendingVY;
    mapping(address => uint256) public totalClaimedByReferrer;

    // Auto-pagination state. `settleCursor[user]` is the next invitee index
    // to settle; `hasSettled[user]` is true only when the cursor has walked
    // the caller's entire subtree. `claimMine` requires `hasSettled` and
    // clears it on payout, so each claim cycle is settle-fully → claim.
    mapping(address => uint256) public settleCursor;
    mapping(address => bool)    public hasSettled;

    // Set when a referrer transitions from T<2 → T>=2 (first time they become
    // eligible to earn credits). On their next `settleMine`, each referee's
    // checkpoint is advanced to "now" WITHOUT crediting — enforcing the
    // "earn forward from upgrade, not back from bind" invariant. Cleared on
    // full subtree walk completion.
    mapping(address => bool) public needsCheckpointReset;

    // Globals.
    uint256 public globalCreditedVY;
    uint256 public globalClaimedVY;

    // T4 V-DAO launch state.
    // Name/symbol uniqueness is NOT tracked here — the factory is the single
    // authority (its `nameTaken`/`symbolTaken` + `reserveName`); VARO only
    // forwards the base inputs to `vdaoFactory.launch`.
    mapping(address => address) public vdao;                   // creator/partner => V-DAO token (own token, or the target for partners)

    /// @notice Reverse registry: true for every token VARO has launched. Gates
    ///         nested-layer parents and partner targets (can't build on / partner
    ///         a non-V-DAO). Set at base/nested launch and bootstrap.
    mapping(address => bool) public isLaunchedVDAO;
    /// @notice Layer depth of a V-DAO. 1 = base; a layer built on it = parent+1.
    mapping(address => uint8) public vdaoLayer;
    /// @notice V-DAO => its pool id on the VDAO DAX (the second leg). Used at
    ///         claim/partner time to `donate` into the right pool in O(1).
    ///         Internal (read it off the VDAO DAX via getPoolIdByPair if needed).
    mapping(address => uint256) internal vdaoDaxSecondPoolId;
    // Partners (fee-sharing affiliates of an existing V-DAO, no token of their
    // own) are not flagged in storage — they're a full T4 with `vdao[partner]`
    // pointing at the target, and the `PartnerRegistered` event indexes them.
    // `vdao[partner]` being set makes the registration terminal (no `launchVDAO`).

    /// @notice V-DAOs flagged to donate 100% of claim payouts to their V2
    ///         pool (no creator cut). Only set by `bootstrapVGCVDAO` for
    ///         VGC-VDAO. Standard `launchVDAO` V-DAOs leave this false →
    ///         50% to creator, 50% donated to the pool.
    mapping(address => bool) public vdaoDonateAll;


    /// @notice One-shot latch for `bootstrapVGCVDAO` — flips true on first
    ///         use and the function reverts forever after. Only VGC-VDAO is
    ///         intended to use this path; every other V-DAO must go through
    ///         the paid `launchVDAO` flow.
    bool public vdaoBootstrapped;

    /// @notice The ONLY address allowed to call `bootstrapVGCVDAO`. Set
    ///         once by admin via `setVgcDeployer`. Distinct from
    ///         `vgcRecipient` — deployer only triggers the tx; recipient is
    ///         picked separately by admin.
    address public vgcDeployer;

    /// @notice The address that receives every role + every payout from the
    ///         bootstrap. Set once by admin via `setVgcRecipient`. The
    ///         deployer cannot override this — admin chooses where value
    ///         actually lands.
    address public vgcRecipient;

    // ─── Keeper-driven global settlement sweep (storage V2, appended) ────────
    // Appended after all prior storage to preserve the UUPS layout. `sweep`
    // walks `_allReferees` in cursor-paginated batches, running the same
    // per-referee crediting as `settleMine`, so `outstandingReferralDebtVY()`
    // tracks true protocol-wide liability instead of lagging on individual
    // referrers' settle timing.

    /// @notice Every bound referee, in bind order. Pushed once per referee in
    ///         `_bindReferrer` (binding is one-shot, so there are no duplicates).
    address[] private _allReferees;

    /// @notice Next index into `_allReferees` for the keeper sweep. 0 = a fresh
    ///         lap is due (gated by DEFAULT_SWEEP_COOLDOWN). Surfaced via the
    ///         `SweepProgressed` event rather than a getter (bytecode budget).
    uint256 internal sweepCursor;

    /// @notice Timestamp the last full sweep lap completed. Next lap may start
    ///         at `lastLapCompletedAt + DEFAULT_SWEEP_COOLDOWN`.
    uint256 internal lastLapCompletedAt;

    /// @notice Gas Officer (VGO) — reimburses the keeper's gas + flat tip on
    ///         each `sweep` via the `beginReward`/`payReward` bracket. Set via
    ///         `setVgo`; the chosen value is emitted in `AddressUpdated`.
    address internal vgo;

    /// @notice True for every address whose HyperEVM builder has been funded
    ///         (a $100 CCTP carve fired for it). Set by: any T3 purchase, any
    ///         T4 launch (both auto-fund the builder when the caller is < T3),
    ///         the `withBuilder` partner path, and `fundMyBuilder`. Read by
    ///         `fundMyBuilder` to block double-funding. A T2-level partner
    ///         ($10, no perp trading) leaves this false until they later call
    ///         `fundMyBuilder`.
    mapping(address => bool) public hasBuilder;

    /// @dev UUPS storage gap. 39 → 34 (keeper-sweep block) → 31 (+4 added:
    ///      `vdaoDax`/`isLaunchedVDAO`/`vdaoLayer`/`vdaoDaxSecondPoolId`, −1
    ///      `vdaoPairAsset`) → 34 (−3 freed: `daxPoolWethVy`/`WbtcVy`/`PaxgVy`,
    ///      now resolved live) → 35 (−1 freed: `vdaoDaxPoolRegistered`,
    ///      consolidated into `isLaunchedVDAO`) → 37 (−2 freed:
    ///      `nameTaken`/`symbolTaken`, moved to the factory) → 36 (−1 added:
    ///      `hasBuilder`).
    uint256[36] private __gap;

    // ─────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────────

    event ReferralRegistered(address indexed referree, address indexed referrer);
    event TierPurchased(address indexed buyer, uint8 indexed newTier, uint256 usdcPriceUsed, uint256 amountPaid);
    event TierPriceSet(uint8 indexed tier, uint256 newUsdcPrice);
    event BpsSet(bytes32 indexed key, uint16 newBps);
    event AddressUpdated(bytes32 indexed key, address newAddr);
    event Credited(address indexed referrer, address indexed referree, uint8 indexed sourceId, uint256 vyDelta, uint256 vyCredited);
    event Claimed(address indexed referrer, uint256 vyAmount);
    event VDAODonated(address indexed vdao, address indexed vdaoDax, uint256 amount);
    event PausedSet(bool paused);
    event VDAOLaunched(address indexed creator, address indexed vdao, uint256 supply, uint256 assetPaid);
    event PartnerRegistered(address indexed partner, address indexed targetVdao, uint256 assetPaid);
    event CCTPBridged(address indexed referrer, address indexed predictedVR, uint256 usdcAmount, uint64 cctpNonce);
    event ReserveAssetSet(uint8 indexed assetId, address indexed asset);
    event SweepProgressed(uint256 toCursor, bool lapCompleted);

    // ─────────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────────

    error InvalidAddress();
    error InvalidTier();
    error PausedErr();
    error NotRegistered();
    error AlreadyRegistered();
    error SelfReferral();
    error BandViolation();
    error InvalidBps();
    error InvalidConfig();
    error AlreadyLaunched();
    error NoPending();
    error RefundFailed();
    error MustSettleFirst();
    error AlreadyBootstrapped();
    error NotVgcDeployer();
    error DeployerAlreadySet();
    error RecipientAlreadySet();
    error RecipientNotSet();
    error SweepCooldownActive();
    error SweepBatchTooSmall();
    error NoReferees();

    // ─────────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert PausedErr();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INITIALIZER
    // ─────────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    struct InitArgs {
        address admin;
        address vy;
        address usdc;
        address vyt;
        address vco;
        address veo;
        address vlo;
        address vyo;
        address vbbo;
        address vdax;
        address vsr;
        address vdaoDax;
        address vyUsdcV2Pool;
        address uniV2Router;
        address house;
    }

    function initialize(InitArgs calldata a) external initializer {
        if (
            a.admin == address(0) || a.vy == address(0) || a.usdc == address(0) ||
            a.vyt == address(0) || a.vco == address(0) || a.veo == address(0) ||
            a.vlo == address(0) || a.vyo == address(0) || a.vbbo == address(0) ||
            a.vdax == address(0) || a.vsr == address(0) || a.vdaoDax == address(0) ||
            a.vyUsdcV2Pool == address(0) || a.uniV2Router == address(0) ||
            a.house == address(0)
        ) revert InvalidAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, a.admin);
        _grantRole(ADMIN_ROLE, a.admin);

        vy            = IERC20(a.vy);
        usdc          = IERC20(a.usdc);
        vyt           = IVYT(a.vyt);
        vco           = IVCO(a.vco);
        veo           = IVEO(a.veo);
        vlo           = IVLO(a.vlo);
        vyo           = a.vyo;
        vbbo          = a.vbbo;
        vdax          = IValinityDAX(a.vdax);
        vsr           = IValinityVSR(a.vsr);
        vdaoDax       = IValinityVDAODAX(a.vdaoDax);
        vyUsdcV2Pool  = IUniswapV2Pair(a.vyUsdcV2Pool);
        uniV2Router   = IUniswapV2Router02(a.uniV2Router);
        house         = a.house;

        // Cache pair orientation so spot reads don't pay a token0() SLOAD.
        vyIsToken0 = (IUniswapV2Pair(a.vyUsdcV2Pool).token0() == a.vy);

        vyoYieldBps        = 500;    // 5%
        veoTradingBps      = 5_000;  // 50%
        vloInterestBps     = 5_000;
        vpoHLBuilderBps    = 5_000;
        vyoYieldBpsVDAO     = 900;    // 9%   (within MAX_BPS_VYO=9.5% cap)
        veoTradingBpsVDAO   = 9_500;  // 95%
        vloInterestBpsVDAO  = 9_500;  // 95%
        vpoHLBuilderBpsVDAO = 9_500;  // 95%

        // USD-denominated tier prices (USDC raw, 1e6).
        tier1Usdc =     500_000;     // $0.50
        tier2Usdc =  10_000_000;     // $10
        tier3Usdc = 110_000_000;     // $110 = 100 CCTP + 10 buyback
        tier4Usdc = 2_000_000_000;   // $2,000 (paid in chosen asset)

        cctpActivationUSDC = 100 * 10**6; // 100 USDC

        // Pre-approve permanent routers / sinks (avoids per-call SSTOREs).
        IERC20(a.usdc).forceApprove(a.uniV2Router, type(uint256).max);
        IERC20(a.vy  ).forceApprove(a.uniV2Router, type(uint256).max);
        IERC20(a.vy  ).forceApprove(a.vdax,        type(uint256).max);
        IERC20(a.usdc).forceApprove(a.vdax,        type(uint256).max);
        // USDC second leg (base-USDC launches) seeds the VDAO DAX directly.
        IERC20(a.usdc).forceApprove(a.vdaoDax,     type(uint256).max);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PRICING — USDC → ASSET via spot composition (no TWAP)
    // ═════════════════════════════════════════════════════════════════════════
    //
    // For non-USDC assets, VARO derives "how much <asset> equals N USDC?" by
    // composing two spot pools:
    //
    //   asset/VY  → reserves on VDAX (private — only whitelisted swappers,
    //                                  so the pool can't be sandwiched)
    //   VY/USDC   → reserves on V2 (public; theoretically sandwich-able,
    //                                  bounded in $ per-tx by tier caps)
    //
    //   assetAmount = usdcAmount × (assetReserve_DAX × vyReserve_V2)
    //                            ───────────────────────────────────
    //                              (vyReserve_DAX × usdcReserve_V2)
    //
    // Callers pass slippage bounds (`maxAssetAmount` on T4, `minVyOut` on
    // ETH-pay tiers) so any drift between quote and settle is user-bounded.
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Convert `usdcAmount` (1e6) to the equivalent amount of
    ///         `assetChoice`. ASSET_USDC returns the input unchanged.
    function quoteUsdcInAsset(uint8 assetChoice, uint256 usdcAmount)
        external
        view
        returns (uint256)
    {
        return _usdcToAsset(assetChoice, usdcAmount);
    }

    function _usdcToAsset(uint8 assetChoice, uint256 usdcAmount)
        internal
        view
        returns (uint256 assetAmount)
    {
        if (assetChoice == ASSET_USDC) return usdcAmount;
        uint256 daxPoolId = _daxPoolId(_assetAddr(assetChoice)); // resolved live
        ( , uint256 vyReserveDax, uint256 assetReserveDax) =
            vdax.getPoolReserves(daxPoolId);
        (uint256 vyReserveV2, uint256 usdcReserveV2) = _readVyUsdcReserves();
        if (vyReserveDax == 0 || usdcReserveV2 == 0) revert InvalidConfig();
        // Two-step to keep intermediates within 256 bits at realistic reserve depths.
        // assetAmount = usdcAmount * assetReserveDax * vyReserveV2 / (vyReserveDax * usdcReserveV2)
        assetAmount = (usdcAmount * assetReserveDax) / usdcReserveV2;
        assetAmount = (assetAmount * vyReserveV2) / vyReserveDax;
    }

    /// @dev Oriented V2 VY/USDC reserves (instantaneous spot).
    function _readVyUsdcReserves()
        internal
        view
        returns (uint256 vyReserve, uint256 usdcReserve)
    {
        (uint112 r0, uint112 r1, ) = vyUsdcV2Pool.getReserves();
        if (vyIsToken0) { vyReserve = r0; usdcReserve = r1; }
        else            { vyReserve = r1; usdcReserve = r0; }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // REFERRAL BINDING (internal — called by T1 entries)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Bind `referree` to `referrer` (or to `house` if `referrer == 0`).
    ///      Called inside `purchaseTier1With*`. Reverts on self-referral or on
    ///      attempt to re-bind to a different referrer. Idempotent on same pair.
    function _bindReferrer(address referree, address referrer) internal {
        if (referree == address(0)) revert InvalidAddress();
        address ref = referrer == address(0) ? house : referrer;
        if (ref == address(0)) revert InvalidAddress();
        if (ref == referree) revert SelfReferral();

        address existing = referredBy[referree];
        if (existing == ref) return; // idempotent on same pair
        if (existing != address(0)) revert AlreadyRegistered();

        referredBy[referree] = ref;
        _referees[ref].push(referree);
        _allReferees.push(referree); // global keeper-sweep list (one-shot per referee)

        // Snapshot every PULL-source checkpoint so past activity earns nothing.
        checkpoints[referree][SRC_VEO_TRADING]  = veo.cumulativeUserFeeVY(referree);
        checkpoints[referree][SRC_VLO_INTEREST] = vlo.cumulativeInterestPaidVY(referree);
        checkpoints[referree][SRC_VYO_YIELD]    = IVYO(vyo).totalYieldClaimedVY(referree);

        emit ReferralRegistered(referree, ref);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TIER 1 — registration entry (USDC or ETH path)
    // ═════════════════════════════════════════════════════════════════════════
    //
    // Every Valinity user enters through T1. It binds the caller to a referrer
    // (or the house if none) and registers them on VEO so they can trade.
    // Fee = $0.50 USD (`tier1Usdc`), paid in USDC directly or in ETH sized
    // via `_usdcToAsset(ASSET_ETH, tier1Usdc)`. All proceeds buy VY → VBBO.
    //
    // Webapp resolves `referrer`:
    //   - Came in via `/r/<addr>` invitee link → pass that addr
    //   - Came in directly to the app          → pass address(0); VARO substitutes `house`
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Register the caller (T1) by paying `tier1Usdc` USDC. USDC → VY
    ///         on the V2 VY/USDC pool; VY lands at VBBO.
    function purchaseTier1WithUSDC(address referrer)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcPaid)
    {
        if (tier[msg.sender] >= 1) revert AlreadyRegistered();

        usdcPaid = tier1Usdc;
        usdc.safeTransferFrom(msg.sender, address(this), usdcPaid);
        // minVyOut=0: $0.50 swap is too small to be sandwich-economical
        // (attacker gas cost >> extractable value).
        _swapUsdcToVyV2(usdcPaid, vbbo, 0);

        _activateT1(referrer);
        tier[msg.sender] = 1;
        emit TierPurchased(msg.sender, 1, tier1Usdc, usdcPaid);
    }

    /// @notice Register the caller (T1) by paying ETH. Required ETH is sized
    ///         from `tier1Usdc` via spot composition; any excess `msg.value`
    ///         is refunded. ETH → WETH → VY on VDAX WETH/VY; VY lands at VBBO.
    /// @param  referrer From the webapp invitee link, or 0 for the house.
    /// @param  minVyOut Slippage protection on the VDAX swap.
    function purchaseTier1WithETH(address referrer, uint256 minVyOut)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 ethRequired)
    {
        if (tier[msg.sender] >= 1) revert AlreadyRegistered();

        ethRequired = _usdcToAsset(ASSET_ETH, tier1Usdc);
        if (msg.value < ethRequired) revert BandViolation();

        _buybackEthToVbbo(ethRequired, minVyOut);
        _refundExcessEth(ethRequired);

        _activateT1(referrer);
        tier[msg.sender] = 1;
        emit TierPurchased(msg.sender, 1, tier1Usdc, ethRequired);
    }

    /// @dev T1-activation side effect: register the caller on VEO and bind to
    ///      the referrer (or house). Called either by `purchaseTier1With*` or
    ///      by any higher-tier entry when the caller is not yet T1.
    function _activateT1(address referrer) internal {
        veo.register(msg.sender);
        _bindReferrer(msg.sender, referrer);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TIER 2 — activate as referrer (USDC or ETH path)
    // ═════════════════════════════════════════════════════════════════════════
    //
    // Caller is already T1 (has a referrer bound). Paying T2 unlocks earnings
    // on the caller's own referees: anyone bound to caller via the invitee
    // link starts contributing source-fee deltas through `_bpsForRefererAndSource`
    // at the T2 rate. Caller cannot earn anything until they reach T2.
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Upgrade to (or skip directly to) Tier 2 by paying `tier2Usdc`
    ///         USDC. If the caller is not yet T1, `referrer` is consumed and
    ///         the T1 side effects execute as part of this tx; otherwise it
    ///         is ignored.
    function purchaseTier2WithUSDC(address referrer)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcPaid)
    {
        uint8 t = tier[msg.sender];
        if (t >= 2) revert AlreadyRegistered();

        usdcPaid = tier2Usdc;
        usdc.safeTransferFrom(msg.sender, address(this), usdcPaid);
        // minVyOut=0: $10 swap is gas-uneconomical to sandwich.
        _swapUsdcToVyV2(usdcPaid, vbbo, 0);

        if (t == 0) _activateT1(referrer);
        tier[msg.sender] = 2;
        // Crossing T<2 → T>=2: force forward-only credits on next settle.
        needsCheckpointReset[msg.sender] = true;
        emit TierPurchased(msg.sender, 2, tier2Usdc, usdcPaid);
    }

    /// @notice Upgrade to (or skip directly to) Tier 2 by paying ETH. Required
    ///         ETH sized from `tier2Usdc`; excess `msg.value` refunded.
    function purchaseTier2WithETH(address referrer, uint256 minVyOut)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 ethRequired)
    {
        uint8 t = tier[msg.sender];
        if (t >= 2) revert AlreadyRegistered();

        ethRequired = _usdcToAsset(ASSET_ETH, tier2Usdc);
        if (msg.value < ethRequired) revert BandViolation();

        _buybackEthToVbbo(ethRequired, minVyOut);
        _refundExcessEth(ethRequired);

        if (t == 0) _activateT1(referrer);
        tier[msg.sender] = 2;
        // Crossing T<2 → T>=2: force forward-only credits on next settle.
        needsCheckpointReset[msg.sender] = true;
        emit TierPurchased(msg.sender, 2, tier2Usdc, ethRequired);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TIER 3 — HL builder (USDC entry; carves CCTP)
    // ═════════════════════════════════════════════════════════════════════════
    //
    // T3 is USDC-only because CCTP requires native USDC for the cross-chain
    // bridge. The bridged 100 USDC funds the predicted V_R address on
    // HyperEVM; the remainder is single-leg buybacked to VBBO.

    /// @notice Upgrade to (or skip directly to) Tier 3 by paying `tier3Usdc`
    ///         USDC ($110 = $100 CCTP bridge + $10 buyback). If caller is not
    ///         yet T1, `referrer` is consumed; otherwise ignored. T2-skip is
    ///         silently bundled.
    function purchaseTier3WithUSDC(address referrer)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcPaid)
    {
        uint8 t = tier[msg.sender];
        if (t >= 3) revert AlreadyRegistered();

        usdcPaid = tier3Usdc;
        usdc.safeTransferFrom(msg.sender, address(this), usdcPaid);
        _executeTier3(msg.sender, usdcPaid);

        if (t == 0) _activateT1(referrer);
        tier[msg.sender] = 3;
        // If skipping from T<2 → T3, force forward-only credits on next settle.
        if (t < 2) needsCheckpointReset[msg.sender] = true;
        emit TierPurchased(msg.sender, 3, tier3Usdc, usdcPaid);
    }

    /// @notice Launch a V-DAO (Tier 4) — a BASE V-DAO, or a nested LAYER on top
    ///         of an existing V-DAO when `parentVdao != 0`. A higher tier
    ///         auto-activates all lower tiers in this single tx.
    ///
    ///         Payment: `tier4Usdc` (default $2,000) worth of the chosen asset,
    ///         sized via `_usdcToAsset`. If the caller is not yet T3, ALSO pulls
    ///         a separate `cctpActivationUSDC` for the HL-builder CCTP bridge.
    ///
    ///         Liquidity: the VY leg (45% supply + half the payment as VY) seeds
    ///         the main VDAX VY/V-DAO pool. The SECOND leg (45% supply + the
    ///         other half) seeds the VDAO DAX — paired with the chosen asset for
    ///         a base launch, or with the bought parent V-DAO for a layer.
    ///         10% supply → creator.
    ///
    /// @param  name_                Base name. Layer → `{name_} {parentSymbol} L{depth}`.
    /// @param  symbol_              Base symbol. Layer → `{symbol_}L{depth}`.
    /// @param  totalSupply_         V-DAO total supply (caller-chosen, 18 decimals).
    /// @param  logoCID              IPFS multihash (bytes32 v1) of the logo.
    /// @param  pairAssetChoice      Payment asset: 1=USDC, 2=WBTC, 3=ETH, 4=PAXG.
    /// @param  parentVdao           0 = base launch; else the V-DAO to layer on.
    /// @param  maxAssetAmount       Slippage cap on the asset amount VARO pulls.
    /// @param  minVyOutForSeed      Floor on VY received when converting the
    ///                              payment → VY (base: half; layer: all). Anti-
    ///                              sandwich for the public USDC→VY V2 leg; a
    ///                              sanity floor for the private VDAX legs.
    /// @param  minParentOutForSeed  Floor on parent V-DAO received when buying it
    ///                              with VY on the main VDAX (layers only).
    /// @param  referrer             Used only if caller is not yet T1.
    function launchVDAO(
        string  calldata name_,
        string  calldata symbol_,
        uint256 totalSupply_,
        bytes32 logoCID,
        uint8   pairAssetChoice,
        address parentVdao,
        uint256 maxAssetAmount,
        uint256 minVyOutForSeed,
        uint256 minParentOutForSeed,
        address referrer
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (address vdaoAddr, uint256 assetPaid)
    {
        if (totalSupply_ == 0) revert InvalidConfig();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert InvalidConfig();
        uint8 callerTier = tier[msg.sender];
        if (vdao[msg.sender] != address(0)) revert AlreadyLaunched();
        if (callerTier >= 4)                revert AlreadyLaunched();
        // `vsr` is init-required non-zero (no setter); `vdaoFactory` is set
        // post-deploy so it still needs the guard.
        if (address(vdaoFactory) == address(0)) revert InvalidConfig();

        // Resolve depth, then hand the BASE inputs (+ parent/layer) to the
        // factory, which is the single source of truth for V-DAO token info: it
        // DERIVES the final name/symbol, enforces + reserves FCFS uniqueness, and
        // bakes its own veo/mainDax into the immutable token. VARO no longer
        // supplies derived strings or permanent wiring.
        uint8 childLayer = 1;
        if (parentVdao != address(0)) {
            if (!isLaunchedVDAO[parentVdao]) revert NotRegistered();
            childLayer = vdaoLayer[parentVdao] + 1;
        }
        // Deploy V-DAO via factory (S → factory → VARO). Reverts NameTaken/
        // SymbolTaken from the factory if the derived strings collide.
        (vdaoAddr, , ) = vdaoFactory.launch(
            name_, symbol_, totalSupply_, msg.sender, logoCID, parentVdao, childLayer
        );

        // Size + pull the $tier4Usdc payment (bundles the T3 CCTP carve if <T3).
        address pairAsset;
        (pairAsset, assetPaid) = _pullTier4Payment(pairAssetChoice, maxAssetAmount, callerTier);

        // Seed both legs (VY leg first → main-DAX listing rule passes for the
        // VDAO DAX leg) + pay the creator. Returns the main VDAX VY/V-DAO poolId.
        uint256 daxPoolId = _executeVDAOSplit(
            msg.sender, vdaoAddr, totalSupply_, assetPaid,
            pairAsset, pairAssetChoice, parentVdao, minVyOutForSeed, minParentOutForSeed
        );

        // The recorded second-leg token is the parent (layer) or the asset (base);
        // VEO keeps it (VARO doesn't need its own copy).
        address secondToken = parentVdao == address(0) ? pairAsset : parentVdao;
        veo.registerVDAO(vdaoAddr, msg.sender, daxPoolId, secondToken);
        vsr.registerVDAO(vdaoAddr);

        // Mark state. Name/symbol uniqueness was reserved by the factory inside
        // `launch`. `isLaunchedVDAO` doubles as the "both legs seeded" flag the
        // claim payout reads (set iff the seeding above ran).
        vdao[msg.sender]         = vdaoAddr;
        isLaunchedVDAO[vdaoAddr] = true;
        vdaoLayer[vdaoAddr]      = childLayer;

        // T1 side effect if caller skipped straight to T4 with no prior tier.
        if (callerTier == 0) _activateT1(referrer);
        tier[msg.sender] = 4;
        // If skipping from T<2 → T4, force forward-only credits on next settle.
        if (callerTier < 2) needsCheckpointReset[msg.sender] = true;

        emit VDAOLaunched(msg.sender, vdaoAddr, totalSupply_, assetPaid);
        emit TierPurchased(msg.sender, 4, tier4Usdc, assetPaid);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PARTNER (no token) — fee-sharing affiliate of an existing V-DAO
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Register as a fee-sharing PARTNER (affiliate) of an existing
    ///         V-DAO without launching a token. A partner is just a normal
    ///         T2/T3 buyer whose referral payouts get the T4 treatment — the
    ///         only difference between a partner and a direct-to-Valinity user
    ///         is who they are affiliated with: a partner's fees route through
    ///         `targetVdao` (95% bps; at CLAIM time 50% to them in the target
    ///         token + 50% donated to its VDAO DAX leg, via `_payOut`), a direct
    ///         user's route through the house.
    ///
    ///         NO V-DAO is bought at registration; the split happens at claim.
    ///         The payment is just a tier purchase bound to the V-DAO:
    ///
    ///           withBuilder == false → $10 (`tier2Usdc`), USDC → VY → VBBO.
    ///               A "T2-level" partner: no HL builder, no perp trading.
    ///               Gated to callers < T2.
    ///           withBuilder == true  → $110 (`tier3Usdc`): $100 CCTP → the
    ///               caller's own predicted HL builder + $10 → VY → VBBO.
    ///               A "T3-level" partner WITH perp trading. Gated to callers
    ///               < T3 (this funds their one builder slot).
    ///
    ///         Either way the caller becomes a terminal T4 bound to the target
    ///         (`vdao[caller]` set → can never `launchVDAO`, one partnership per
    ///         wallet). A `withBuilder == false` partner who later wants perps
    ///         tops up via `fundMyBuilder` ($100) without changing tier.
    /// @param  targetVdao  The V-DAO to partner (must be VARO-launched).
    /// @param  withBuilder True to fund an HL builder ($110); false for the
    ///                     no-builder $10 path.
    /// @param  referrer    Used only if caller is not yet T1.
    function registerAsPartner(
        address targetVdao,
        bool    withBuilder,
        address referrer
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcPaid)
    {
        if (!isLaunchedVDAO[targetVdao]) revert NotRegistered();
        uint8 callerTier = tier[msg.sender];
        if (vdao[msg.sender] != address(0)) revert AlreadyLaunched();

        if (withBuilder) {
            // T3-level partner: funds the one builder slot → gate to < T3.
            if (callerTier >= 3) revert AlreadyRegistered();
            usdcPaid = tier3Usdc;
            usdc.safeTransferFrom(msg.sender, address(this), usdcPaid);
            _executeTier3(msg.sender, usdcPaid); // $100 CCTP → builder, $10 → VBBO
        } else {
            // T2-level partner: $10 → VY → VBBO, no builder. Gate to < T2.
            if (callerTier >= 2) revert AlreadyRegistered();
            usdcPaid = tier2Usdc;
            usdc.safeTransferFrom(msg.sender, address(this), usdcPaid);
            // minVyOut=0: $10 swap is gas-uneconomical to sandwich.
            _swapUsdcToVyV2(usdcPaid, vbbo, 0);
        }

        // State: a partner is a full T4 pointed at the target. Terminal —
        // `vdao[msg.sender]` is set, so `launchVDAO` reverts AlreadyLaunched.
        vdao[msg.sender] = targetVdao;
        if (callerTier == 0) _activateT1(referrer);
        tier[msg.sender] = 4;
        // Skipping from T<2 → T4: force forward-only credits on next settle.
        if (callerTier < 2) needsCheckpointReset[msg.sender] = true;

        emit PartnerRegistered(msg.sender, targetVdao, usdcPaid);
        emit TierPurchased(msg.sender, 4, usdcPaid, usdcPaid);
    }

    /// @notice Fund the caller's HyperEVM builder after the fact — for a
    ///         `withBuilder == false` partner (or any tier-4 holder without a
    ///         builder) who later wants perp trading. Charges `cctpActivationUSDC`
    ///         ($100) USDC and bridges it to the caller's predicted V_R, exactly
    ///         like the T3 carve. Does NOT change the caller's tier (they stay
    ///         the T4-treated partner they already are). One-shot per address —
    ///         `hasBuilder` blocks a second funding.
    /// @dev    Open to any tier-4 holder missing a builder. A plain T2-level
    ///         partner is the intended caller; a T4 V-DAO creator already has a
    ///         builder (auto-funded at launch when < T3) so `hasBuilder` short-
    ///         circuits them.
    function fundMyBuilder()
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcPaid)
    {
        if (tier[msg.sender] != 4) revert NotRegistered();
        if (hasBuilder[msg.sender]) revert AlreadyRegistered();
        usdcPaid = cctpActivationUSDC;
        usdc.safeTransferFrom(msg.sender, address(this), usdcPaid);
        _cctpBridgeToBuilder(msg.sender, usdcPaid); // sets hasBuilder = true
    }


    // ═════════════════════════════════════════════════════════════════════════
    // TIER 3 (HL builder)
    // ═════════════════════════════════════════════════════════════════════════

    function _executeTier3(address user, uint256 usdcPaid) internal {
        if (address(hlFactory) == address(0) || address(cctp) == address(0)) revert InvalidConfig();
        uint256 bridgeAmount = cctpActivationUSDC;
        if (bridgeAmount > usdcPaid) revert InvalidConfig();
        _cctpBridgeToBuilder(user, bridgeAmount);
        uint256 remainder = usdcPaid - bridgeAmount;
        // minVyOut=0: $10 remainder after CCTP carve is too small to sandwich.
        if (remainder > 0) _swapUsdcToVyV2(remainder, vbbo, 0);
    }

    /// @dev Shared T4/partner intake: size `tier4Usdc` into `choice`, pull it
    ///      (ETH-wrap, else `transferFrom`; stray ETH rejected on non-ETH), and
    ///      bundle the CCTP HL-builder carve when the caller is below T3.
    ///      Returns the resolved asset + the amount actually paid.
    function _pullTier4Payment(uint8 choice, uint256 maxAsset, uint8 callerTier)
        internal
        returns (address asset, uint256 paid)
    {
        asset = _assetAddr(choice); // address only — pool id resolved live where needed
        paid = _usdcToAsset(choice, tier4Usdc);
        if (paid > maxAsset) revert BandViolation();
        if (choice == ASSET_ETH) {
            if (msg.value < paid) revert BandViolation();
            IWETH9(weth).deposit{value: paid}();
            _refundExcessEth(paid);
        } else {
            if (msg.value != 0) revert InvalidConfig();
            IERC20(asset).safeTransferFrom(msg.sender, address(this), paid);
        }
        if (callerTier < 3) {
            uint256 carve = cctpActivationUSDC;
            usdc.safeTransferFrom(msg.sender, address(this), carve);
            _cctpBridgeToBuilder(msg.sender, carve);
        }
    }

    /// @dev Bridge `amount` USDC via CCTP to `user`'s predicted V_R address on
    ///      HyperEVM and flag `user` as builder-funded. Single chokepoint for
    ///      every builder-funding path (T3, the T4 carve, the `withBuilder`
    ///      partner path, and `fundMyBuilder`), so `hasBuilder` is always set
    ///      here regardless of caller.
    function _cctpBridgeToBuilder(address user, uint256 amount) internal {
        if (address(hlFactory) == address(0) || address(cctp) == address(0)) revert InvalidConfig();
        address predictedVR = hlFactory.predictBuilder(user);
        // USDC → CCTP approval set permanently in `setCctp`.
        uint64 nonce = cctp.depositForBurn(
            amount,
            cctpHLDomain,
            bytes32(uint256(uint160(predictedVR))),
            address(usdc)
        );
        hasBuilder[user] = true;
        emit CCTPBridged(user, predictedVR, amount, nonce);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TIER 4 SPLIT (V-DAO launch)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Execute the T4 launch split. Seeds BOTH legs + pays the creator.
    ///   PAYMENT (assetTotal of `pairAsset`):
    ///     - base (parentVdao==0): half → VY (VY leg); the other half (the
    ///       asset) is the second leg.
    ///     - layer (parentVdao!=0): ALL → VY; half is the VY leg, the other
    ///       half buys the parent on the main VDAX → the second leg.
    ///   V-DAO supply: 45% → VY leg (main VDAX), 45% → second leg (VDAO DAX),
    ///     10% → creator. The VY leg is seeded FIRST so `mainDax.hasPool(vdao)`
    ///     is true when the VDAO DAX listing rule checks the new V-DAO leg.
    ///     VARO is fee-exempt on every V-DAO, so seed transfers pay no burn.
    function _executeVDAOSplit(
        address creator,
        address vdaoAddr,
        uint256 totalSupply_,
        uint256 assetTotal,
        address pairAsset,
        uint8   pairAssetChoice,
        address parentVdao,
        uint256 minVyOutForSeed,
        uint256 minParentOut
    ) internal returns (uint256 daxPoolId) {
        uint256 vdaoToVyLeg     = (totalSupply_ * T4_VDAO_TO_DAX_POOL_BPS)   / BPS_DENOMINATOR;
        uint256 vdaoToSecondLeg = (totalSupply_ * T4_VDAO_TO_SECOND_LEG_BPS) / BPS_DENOMINATOR;
        uint256 vdaoToCreator   = (totalSupply_ * T4_VDAO_TO_CREATOR_BPS)    / BPS_DENOMINATOR;

        uint256 vyForVyLeg;
        address secondToken;
        uint256 secondAmt;
        if (parentVdao == address(0)) {
            // BASE: half asset → VY; the other half (the asset) is the second leg.
            uint256 halfForVY = assetTotal / 2;
            vyForVyLeg  = _swapAssetToVY(pairAssetChoice, pairAsset, halfForVY, minVyOutForSeed);
            secondToken = pairAsset;
            secondAmt   = assetTotal - halfForVY;
        } else {
            // LAYER: all asset → VY; half is the VY leg, half buys the parent.
            uint256 totalVy = _swapAssetToVY(pairAssetChoice, pairAsset, assetTotal, minVyOutForSeed);
            vyForVyLeg  = totalVy / 2;
            secondToken = parentVdao;
            secondAmt   = VAROReferralSettleLib.buyVdaoWithVy(
                address(vdax), address(vy), parentVdao, totalVy - vyForVyLeg, minParentOut
            );
        }

        // ── (1) VY leg on the main VDAX (FIRST → satisfies the listing rule) ──
        // VY → VDAX approval is permanent (init); the V-DAO is fresh, approve now.
        IERC20(vdaoAddr).forceApprove(address(vdax), vdaoToVyLeg);
        daxPoolId = vdax.addPool(vdaoAddr, vyForVyLeg, vdaoToVyLeg);

        // ── (2) Second leg on the VDAO DAX ───────────────────────────────────
        // Max-approve the fresh V-DAO once → covers this seed AND every future
        // claim/partner donate (V-DAO max allowance is never decremented). The
        // second-leg token is pre-approved at init (USDC) / setReserveAsset
        // (WBTC/ETH/PAXG) / its own launch (a parent V-DAO).
        IERC20(vdaoAddr).forceApprove(address(vdaoDax), type(uint256).max);
        vdaoDaxSecondPoolId[vdaoAddr] =
            vdaoDax.addPool(secondToken, vdaoAddr, secondAmt, vdaoToSecondLeg);

        // ── (3) creator cut ─────────────────────────────────────────────────
        IERC20(vdaoAddr).safeTransfer(creator, vdaoToCreator);

        // Rounding dust (bps may sum < 10000) stays at VARO with no exit.
    }

    /// @dev Convert `assetIn` of `pairAsset` to VY using the asset's natural
    ///      pool. USDC → V2 VY/USDC. WBTC/ETH/PAXG → VDAX <asset>/VY pool.
    ///      `minVyOut` is the floor on VY received — anti-sandwich for V2
    ///      and a sanity check for VDAX (private but still pool-state-drift
    ///      sensitive between submission and execution).
    function _swapAssetToVY(uint8 assetChoice, address asset, uint256 assetIn, uint256 minVyOut)
        internal
        returns (uint256 vyOut)
    {
        if (assetChoice == ASSET_USDC) {
            return _swapUsdcToVyV2(assetIn, address(this), minVyOut);
        }
        // Asset → VDAX approval pre-set at `setReserveAsset`; pool id resolved live.
        vyOut = vdax.swapExactIn(_daxPoolId(asset), asset, assetIn, minVyOut, address(this));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SWAP HELPERS (USDC → VY on V2 ; ETH → VY on VDAX WETH/VY)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Wrap `ethValue` ETH to WETH and swap on the VDAX WETH/VY pool;
    ///      VY delivered to VBBO. Used by T1 ETH and T2 ETH. WETH was given a
    ///      permanent VDAX max-approval at `setReserveAsset(ETH, ...)`. The pool
    ///      id is resolved live (`_daxPoolId`), which also reverts if WETH is
    ///      unset/unlisted.
    function _buybackEthToVbbo(uint256 ethValue, uint256 minVyOut)
        internal
        returns (uint256 vyToVbbo)
    {
        uint256 poolId = _daxPoolId(weth);
        IWETH9(weth).deposit{value: ethValue}();
        vyToVbbo = vdax.swapExactIn(poolId, weth, ethValue, minVyOut, vbbo);
    }

    /// @dev Low-level V2 USDC→VY swap. Caller passes `minVyOut` for slippage
    ///      protection (set to 0 by tier 1/2/3 buyback paths where the swap
    ///      amount is too small to be sandwich-economical).
    ///      USDC pre-approved to uniV2Router at init.
    function _swapUsdcToVyV2(uint256 amountIn, address recipient, uint256 minVyOut)
        internal
        returns (uint256 vyOut)
    {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(vy);
        uint256[] memory amounts = uniV2Router.swapExactTokensForTokens(
            amountIn,
            minVyOut,
            path,
            recipient,
            block.timestamp
        );
        vyOut = amounts[1];
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PUSH NOTIFY ENTRY POINT (sole VPO data path into VARO)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice HyperEVM builder push. Called by VPO L1 after a referrer's
    ///         accumulated HL builder fees have drained back to L1 and been
    ///         converted to VY. The HL builder is owned by the T3/T4
    ///         referrer (one builder per referrer), so the credit goes
    ///         straight to the builder owner. T4 owners receive their cut as
    ///         V-DAO at `claimMine` time (50% creator + 50% donate, or 100%
    ///         donate for VGC); T2/T3 receive plain VY.
    /// @dev    Caller-gated to `vpo`. Silently no-ops below T3.
    function notifyReferrerPerpCredit(address referrer, uint256 vyAmount)
        external
        nonReentrant
        whenNotPaused
    {
        if (msg.sender != vpo) revert NotRegistered();
        if (vyAmount == 0 || referrer == address(0)) return;
        if (tier[referrer] < 3) return;
        _credit(referrer, referrer, SRC_VPO_HL_BLDR, vyAmount);
    }

    /// @notice Generic invitee-revenue PUSH. Any contract holding
    ///         `REVENUE_PUSHER_ROLE` (granted by admin) reports the VY-denominated
    ///         gross revenue an INVITEE generated; VARO looks up that invitee's
    ///         inviter (`referredBy`) and credits THEM at the standard/VDAO
    ///         "other" rate (50% / 95%, same as VEO trading), exactly like the
    ///         PULL sources direct the cut to the inviter — only pushed, not read.
    /// @dev    Role-gated to any number of trusted revenue contracts. Trust-based
    ///         (no checkpoint, like the VPO push): pushers MUST report deltas and
    ///         never double-send. No tier gate beyond the bps (T<2 inviters get 0).
    /// @param  invitee  The user whose activity generated the revenue.
    /// @param  grossVY  VY-denominated gross revenue; VARO applies the bps.
    function notifyInviteeRevenue(address invitee, uint256 grossVY)
        external
        nonReentrant
        whenNotPaused
    {
        if (!hasRole(REVENUE_PUSHER_ROLE, msg.sender)) revert NotRegistered();
        if (grossVY == 0 || invitee == address(0)) return;
        address ref = referredBy[invitee];
        if (ref == address(0)) return;          // unbound invitee → nothing to credit
        _credit(ref, invitee, SRC_REVENUE, grossVY);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SETTLE / CLAIM
    // ═════════════════════════════════════════════════════════════════════════

    // Two-step UX: caller loops `settleMine` until `hasSettled[caller]` is
    // true (one tx per `MAX_SETTLE_PER_CALL` invitees), then calls
    // `claimMine` to be paid out. Frontends read `hasSettled` + `settleCursor`
    // + `refereeCount` to drive the loop and `rewardsSummary` for the ledger.

    /// @notice Walks up to `MAX_SETTLE_PER_CALL` of caller's invitees from
    ///         `settleCursor[caller]`, pulling VEO/VLO/VYO deltas and
    ///         crediting `pendingVY[caller]`. When the cursor reaches the
    ///         end of the subtree, `hasSettled[caller]` is set true and the
    ///         cursor resets. Until then, caller must keep calling this.
    ///
    ///         For users with <= MAX_SETTLE_PER_CALL invitees, ONE call
    ///         completes the cycle. For whales, multiple calls are required;
    ///         `claimMine` is locked until `hasSettled` is true.
    function settleMine() external nonReentrant whenNotPaused {
        (uint256 newCursor, uint256 credited, bool finished) = VAROReferralSettleLib.settleSubtree(
            referredBy,
            needsCheckpointReset,
            checkpoints,
            pendingVY,
            tier,
            _referees[msg.sender],
            _settleCfg(),
            settleCursor[msg.sender],
            MAX_SETTLE_PER_CALL
        );

        if (credited != 0) globalCreditedVY += credited;
        settleCursor[msg.sender] = newCursor; // 0 when finished, else next index

        if (finished) {
            hasSettled[msg.sender] = true;
            // Full subtree walked — the reset pass (if any) is done; subsequent
            // settles credit forward-only deltas.
            if (needsCheckpointReset[msg.sender]) needsCheckpointReset[msg.sender] = false;
        }
    }

    /// @notice Pay out caller's `pendingVY`. Requires `hasSettled[caller]`
    ///         (i.e. caller has fully walked their subtree in the current
    ///         cycle), so the user always sees what they're being paid. The
    ///         flag is cleared on success so the next cycle restarts.
    /// @dev    Reverts `MustSettleFirst` if the subtree isn't fully settled,
    ///         `NoPending` if zero accrued.
    function claimMine() external nonReentrant whenNotPaused returns (uint256 paid) {
        if (!hasSettled[msg.sender]) revert MustSettleFirst();
        hasSettled[msg.sender] = false;
        paid = _payOut(msg.sender);
    }


    /// @dev Snapshot VARO's bps schedule + source officer addresses for the
    ///      settle library (which has no storage of its own).
    function _settleCfg() internal view returns (VAROReferralSettleLib.Cfg memory c) {
        c.veo = address(veo);
        c.vlo = address(vlo);
        c.vyo = vyo;
        // Only the 3 PULL-source bps are read by the library; the VPO HL-builder
        // bps live in VARO and are applied on the push path, not here.
        c.veoBps  = veoTradingBps;      c.vloBps  = vloInterestBps;     c.vyoBps  = vyoYieldBps;
        c.veoBpsV = veoTradingBpsVDAO;  c.vloBpsV = vloInterestBpsVDAO; c.vyoBpsV = vyoYieldBpsVDAO;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // KEEPER SWEEP — protocol-wide settlement for an honest liability counter
    // ═════════════════════════════════════════════════════════════════════════
    //
    // `settleMine` only walks a referrer's OWN subtree, and only when they
    // bother to call it — so `outstandingReferralDebtVY()` (read by the VYO to
    // reserve VY out of distributable yield) lags reality and collapses to ~0
    // whenever referrers settle-then-claim in one sitting. `sweep` fixes that: a
    // keeper walks EVERY referee in cursor-paginated batches, running the SAME
    // `_settleOne` crediting, so the global counter tracks the truth.
    //
    // Permissionless + gas-reimbursed: VGO refunds the caller's gas plus a flat
    // tip (beginReward/payReward bracket), so bots are paid to keep it fresh.
    // Throttled to one full lap per `effectiveSweepCooldown()` (default 24h):
    // mid-lap batches run back-to-back; only STARTING a new lap waits.
    //
    // Crediting is checkpoint-based and idempotent — whether the keeper or the
    // referrer's own `settleMine` runs first, each fee is credited exactly once,
    // and `sweep` pays no referrer (payout stays in `claimMine`), so it can
    // never over- or under-pay. Referees whose referrer is mid tier-upgrade
    // (`needsCheckpointReset`) are skipped here and left to that referrer's own
    // `settleMine`, which owns the forward-only baseline and clears the flag.

    /// @notice Number of referees enrolled in the global sweep list. Keepers
    ///         read this to size their batches.
    function allRefereesLength() external view returns (uint256) {
        return _allReferees.length;
    }

    /// @notice Permissionless, gas-reimbursed batch settlement of all referees.
    ///         Lap cooldown is the fixed `DEFAULT_SWEEP_COOLDOWN` (24h).
    ///         Advances `globalCreditedVY` (and each referrer's `pendingVY`) so
    ///         `outstandingReferralDebtVY()` reflects true liability. Pays NO
    ///         referrer — payout stays in `claimMine`.
    /// @param  count Max referees to process this call (clamped to the lap end).
    /// @dev    A lap is one full pass of `_allReferees`. Starting a lap
    ///         (cursor == 0) requires the cooldown to have elapsed; continuing
    ///         one does not. A call must process >= MIN_SWEEP_BATCH referees
    ///         unless it finishes the lap (anti-farm). Any revert rolls back the
    ///         VGO gas snapshot, so a reverted call is never reimbursed.
    function sweep(uint256 count) external nonReentrant whenNotPaused {
        // Cheap validation first — so a doomed call never wastes the VGO gas
        // snapshot (beginReward) before reverting.
        if (_allReferees.length == 0) revert NoReferees();

        uint256 cursor = sweepCursor;
        if (cursor == 0 && block.timestamp < lastLapCompletedAt + DEFAULT_SWEEP_COOLDOWN) {
            revert SweepCooldownActive();
        }

        address _vgo = vgo;
        bool reward = _vgo != address(0);
        if (reward) {
            // Best-effort: a VGO that is unwired, paused, or hasn't granted VARO
            // OFFICER_ROLE must never brick the permissionless sweep. If the
            // snapshot fails we simply skip the reward and run the sweep unpaid.
            try IKeeperRewards(_vgo).beginReward() {} catch { reward = false; }
        }

        // The library walks the global list (reset-skip), clamps `count` to the
        // lap end, enforces MIN_SWEEP_BATCH, and reports progress + VY credited.
        (uint256 newCursor, uint256 credited, bool finishesLap) = VAROReferralSettleLib.sweepRange(
            referredBy,
            needsCheckpointReset,
            checkpoints,
            pendingVY,
            tier,
            _allReferees,
            _settleCfg(),
            cursor,
            count,
            MIN_SWEEP_BATCH
        );

        sweepCursor = newCursor;
        if (finishesLap) lastLapCompletedAt = block.timestamp;
        if (credited != 0) globalCreditedVY += credited;
        emit SweepProgressed(newCursor, finishesLap);

        if (reward) {
            try IKeeperRewards(_vgo).payReward(msg.sender) {} catch {}
        }
    }

    /// @dev Apply bps × delta and credit `referrer`. Source determines which
    ///      bps table (standard or pro) to read.
    function _credit(
        address referrer,
        address referree,
        uint8   sourceId,
        uint256 delta
    ) internal {
        if (delta == 0) return;
        uint16 bps = _bpsForRefererAndSource(referrer, sourceId);
        if (bps == 0) return;
        uint256 cut = (delta * bps) / BPS_DENOMINATOR;
        if (cut == 0) return;
        pendingVY[referrer] += cut;
        globalCreditedVY    += cut;
        emit Credited(referrer, referree, sourceId, delta, cut);
    }

    function _bpsForRefererAndSource(address referrer, uint8 sourceId)
        internal
        view
        returns (uint16)
    {
        uint8 t = tier[referrer];
        if (t < 2) return 0;           // T1 referrers earn nothing
        bool isVDAO = t >= 4;
        if (sourceId == SRC_VEO_TRADING)  return isVDAO ? veoTradingBpsVDAO  : veoTradingBps;
        if (sourceId == SRC_VLO_INTEREST) return isVDAO ? vloInterestBpsVDAO : vloInterestBps;
        if (sourceId == SRC_VPO_HL_BLDR)  return isVDAO ? vpoHLBuilderBpsVDAO: vpoHLBuilderBps;
        if (sourceId == SRC_VYO_YIELD)    return isVDAO ? vyoYieldBpsVDAO    : vyoYieldBps;
        // Generic invitee revenue rides the "other" 50/95 rate (VEO trading bps),
        // so it auto-tracks setBpsStandard/setBpsVDAO without its own fields.
        if (sourceId == SRC_REVENUE)      return isVDAO ? veoTradingBpsVDAO  : veoTradingBps;
        return 0;
    }

    function _payOut(address referrer) internal returns (uint256 paid) {
        paid = pendingVY[referrer];
        if (paid == 0) revert NoPending();
        pendingVY[referrer] = 0;
        globalClaimedVY    += paid;
        totalClaimedByReferrer[referrer] += paid;

        // Pull-from-VYT pattern (matches VYO/VGO/VLO).
        vyt.pullTokens(address(this), paid);
        vco.addToHighestLTVFCap(paid);

        // T4 referrers (creators AND partners): route the VY through the V-DAO
        // they point at — `vdao[referrer]` is the creator's own token, or the
        // target token for a partner. Buy it on the main VDAX VY/V-DAO pool,
        // then split (50% to referrer, 50% donated to the VDAO DAX leg; or 100%
        // donated for VGC `vdaoDonateAll`). VARO is permanently fee-exempt on
        // every V-DAO, so the transfers pay no 0.7% burn.
        address rVDao = vdao[referrer];
        if (tier[referrer] == 4 && isLaunchedVDAO[rVDao]) {
            VAROReferralSettleLib.buyAndSplit(
                address(vdax), address(vdaoDax), address(vy), vdaoDaxSecondPoolId,
                rVDao, paid, 0, referrer, vdaoDonateAll[rVDao]
            );
            emit Claimed(referrer, paid);
            return paid;
        }
        // T2/T3 referrers (and any T4 referrer with a missing pool): plain VY.
        IERC20(address(vy)).safeTransfer(referrer, paid);
        emit Claimed(referrer, paid);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Total VY credited to referrers but not yet claimed. Equals
    ///         `globalCreditedVY - globalClaimedVY`.
    /// @dev    INTEGRATION HOOK FOR VYO. Every time a user claims yield in
    ///         VYO, VYO MUST read this value and subtract it from the pool of
    ///         VY supply it treats as "free" / yield-distributable. Without
    ///         this read, VYO can over-distribute supply that VARO has already
    ///         earmarked for referral payouts.
    function outstandingReferralDebtVY() external view returns (uint256) {
        return globalCreditedVY - globalClaimedVY;
    }

    function getReferees(address referrer) external view returns (address[] memory) {
        return _referees[referrer];
    }

    function refereeCount(address referrer) external view returns (uint256) {
        return _referees[referrer].length;
    }

    function refereeAt(address referrer, uint256 i) external view returns (address) {
        return _referees[referrer][i];
    }

    /// @notice Per-user reward ledger for frontend display.
    /// @return available  Settled but unclaimed VY (`pendingVY`).
    /// @return claimed    Lifetime claimed VY (`totalClaimedByReferrer`).
    /// @return total      `available + claimed` — what they have ever earned.
    /// @dev    `available` is a snapshot — does NOT simulate uncredited
    ///         deltas. Frontend should prompt `settleMine` first if it wants
    ///         live numbers.
    function rewardsSummary(address referrer)
        external
        view
        returns (uint256 available, uint256 claimed, uint256 total)
    {
        available = pendingVY[referrer];
        claimed   = totalClaimedByReferrer[referrer];
        total     = available + claimed;
    }

    function bpsForReferrer(address referrer, uint8 sourceId) external view returns (uint16) {
        return _bpsForRefererAndSource(referrer, sourceId);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ADMIN — ADDRESSES
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev TEMPORARY — `setVpo` exists because VPO L1 is not yet deployed.
    ///      Per the "no setter if both UUPS" rule, this must be deleted via
    ///      a VARO upgrade and `vpo` added to `InitArgs` once VPO ships.
    function setVpo(address newVpo)               external onlyRole(ADMIN_ROLE) { _emitAddrUpdate("vpo", newVpo); vpo = newVpo; }
    /// @dev TEMPORARY — same rationale as `setVpo`: VGO is live but VARO may be
    ///      wired post-deploy. Per the "no setter if both UUPS" rule, fold `vgo`
    ///      into `InitArgs` and delete this on the next fresh deploy. To turn
    ///      rewards off, leave VARO unregistered on VGO — `sweep` still runs.
    function setVgo(address newVgo)               external onlyRole(ADMIN_ROLE) { _emitAddrUpdate("vgo", newVgo); vgo = newVgo; }
    /// @notice Update the house BEFORE VGC-VDAO bootstrap. After
    ///         `bootstrapVGCVDAO` runs, house is permanently locked at
    ///         the VGC recipient address and this setter reverts forever.
    function setHouse(address newHouse) external onlyRole(ADMIN_ROLE) {
        if (vdaoBootstrapped) revert AlreadyBootstrapped();
        _emitAddrUpdate("house", newHouse);
        house = newHouse;
    }
    function setCctp(address newCctp, uint32 domain) external onlyRole(ADMIN_ROLE) {
        _emitAddrUpdate("cctp", newCctp);
        cctp = ICCTPTokenMessenger(newCctp);
        cctpHLDomain = domain;
        // Permanent max-approval so per-bridge forceApprove SSTOREs go away.
        usdc.forceApprove(newCctp, type(uint256).max);
    }
    function setCctpActivationUSDC(uint256 newAmount) external onlyRole(ADMIN_ROLE) {
        if (newAmount == 0) revert InvalidConfig();
        cctpActivationUSDC = newAmount;
    }

    function setVDAOFactory(address newFactory) external onlyRole(ADMIN_ROLE) {
        _emitAddrUpdate("vdaoFactory", newFactory);
        vdaoFactory = IValinityVDAOFactory(newFactory);
    }

    /// @notice Set/rotate the HyperEVM Valinity builder factory used to
    ///         predict the CCTP delivery address for T3/T4 builder funding.
    ///         Post-deploy settable (like `cctp`/`vdaoFactory`) because the
    ///         HL-side factory is deployed in a separate, cross-chain process
    ///         and its address may not be final at VARO deploy. T3/T4 bridging
    ///         reverts `InvalidConfig` until this is set.
    function setHlFactory(address newHlFactory) external onlyRole(ADMIN_ROLE) {
        _emitAddrUpdate("hlFactory", newHlFactory);
        hlFactory = IReferrerBuilderFactory(newHlFactory);
    }

    /// @notice ONE-SHOT setter for the VGC deployer key. After this is set
    ///         the value is locked forever — admin cannot rotate it. Only
    ///         the chosen `vgcDeployer` may call `bootstrapVGCVDAO`.
    function setVgcDeployer(address newDeployer) external onlyRole(ADMIN_ROLE) {
        if (vgcDeployer != address(0)) revert DeployerAlreadySet();
        _emitAddrUpdate("vgcDeployer", newDeployer);
        vgcDeployer = newDeployer;
    }

    /// @notice ONE-SHOT setter for the VGC recipient. After this is set the
    ///         value is locked forever — admin cannot rotate it. This is
    ///         the address that gets every role + every payout from the
    ///         bootstrap. Deployer cannot override.
    function setVgcRecipient(address newRecipient) external onlyRole(ADMIN_ROLE) {
        if (vgcRecipient != address(0)) revert RecipientAlreadySet();
        _emitAddrUpdate("vgcRecipient", newRecipient);
        vgcRecipient = newRecipient;
    }

    /// @notice ONE-SHOT bootstrap for the first V-DAO (VGC-VDAO).
    ///         Registers a pre-deployed V-DAO token into VARO's protocol
    ///         state without going through the paid `launchVDAO` flow.
    ///         After first use, `vdaoBootstrapped` is true and this reverts
    ///         forever — every future V-DAO must go through `launchVDAO`.
    /// @dev    Separation of duties:
    ///           - Admin picks the DEPLOYER (`setVgcDeployer`, one-shot)
    ///           - Admin picks the RECIPIENT (`setVgcRecipient`, one-shot)
    ///           - DEPLOYER only triggers this tx; cannot override RECIPIENT
    ///         Deployer must have pre-funded VARO (via approvals) with VY +
    ///         V-DAO for the main-VDAX VY leg AND `pairAsset` + V-DAO for the
    ///         VDAO DAX second leg. `pairAsset` must be `assetAllowed` on the
    ///         VDAO DAX. Seeds BOTH legs on-chain (VY leg first → the VDAO DAX
    ///         listing rule passes for the VGC leg).
    /// @param  assetForSecondLeg `pairAsset` amount seeding the VDAO DAX leg.
    /// @param  vdaoForSecondLeg  V-DAO amount seeding the VDAO DAX leg.
    function bootstrapVGCVDAO(
        address vgcAddr,
        string calldata name_,
        string calldata symbol_,
        address pairAsset,
        uint256 vyForDaxSeed,
        uint256 vdaoForDaxSeed,
        uint256 assetForSecondLeg,
        uint256 vdaoForSecondLeg
    ) external nonReentrant {
        if (msg.sender != vgcDeployer) revert NotVgcDeployer();
        address recipient = vgcRecipient;
        if (recipient == address(0)) revert RecipientNotSet();
        if (vdaoBootstrapped) revert AlreadyBootstrapped();
        if (
            vgcAddr == address(0) ||
            pairAsset == address(0) || vyForDaxSeed == 0 ||
            vdaoForDaxSeed == 0 || assetForSecondLeg == 0 || vdaoForSecondLeg == 0
        ) revert InvalidConfig();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert InvalidConfig();

        if (vdao[recipient] != address(0)) revert AlreadyLaunched();
        // Reserve name/symbol in the factory — the single uniqueness authority.
        // VGC is deployed OUTSIDE the factory, so it can't reserve via `launch`;
        // reverts NameTaken/SymbolTaken if either collides.
        if (address(vdaoFactory) == address(0)) revert InvalidConfig();
        vdaoFactory.reserveName(name_, symbol_);

        vdaoBootstrapped = true;

        // Pull pre-funded VY + V-DAO (both legs) + the second-leg asset.
        IERC20(address(vy)).safeTransferFrom(msg.sender, address(this), vyForDaxSeed);
        IERC20(vgcAddr).safeTransferFrom(msg.sender, address(this), vdaoForDaxSeed + vdaoForSecondLeg);
        IERC20(pairAsset).safeTransferFrom(msg.sender, address(this), assetForSecondLeg);

        // (1) VY leg on the main VDAX FIRST (VY pre-approved at init; V-DAO fresh).
        IERC20(vgcAddr).forceApprove(address(vdax), vdaoForDaxSeed);
        uint256 daxPoolId = vdax.addPool(vgcAddr, vyForDaxSeed, vdaoForDaxSeed);

        // (2) Second leg on the VDAO DAX (max-approve the fresh V-DAO + the asset).
        IERC20(vgcAddr).forceApprove(address(vdaoDax), type(uint256).max);
        IERC20(pairAsset).forceApprove(address(vdaoDax), type(uint256).max);
        vdaoDaxSecondPoolId[vgcAddr] =
            vdaoDax.addPool(pairAsset, vgcAddr, assetForSecondLeg, vdaoForSecondLeg);

        // Register V-DAO in VEO (recipient is passed as VEO's "creator" so
        // the 0.7% V-DAO swap fee routes here) + VSR (stakeable).
        veo.registerVDAO(vgcAddr, recipient, daxPoolId, pairAsset);
        vsr.registerVDAO(vgcAddr);

        // VARO state — `recipient` plays every role. VGC donates 100% of
        // claim payouts to its VDAO DAX leg (no creator cut), unlike standard
        // V-DAOs which split 50% creator / 50% donate.
        vdao[recipient]         = vgcAddr;
        vdaoDonateAll[vgcAddr]  = true;
        isLaunchedVDAO[vgcAddr] = true;
        vdaoLayer[vgcAddr]      = 1;
        tier[recipient]         = 4;

        // Recipient becomes the house — direct-traffic users (T1 with no
        // /r/ link) bind to this address forever. `setHouse` is permanently
        // locked after this point.
        house = recipient;
        emit AddressUpdated("house", recipient);

        // If any direct-traffic users bound to `recipient` while it was the
        // pre-bootstrap house (tier 0), force a forward-only baseline on
        // recipient's first settle so it earns from bootstrap forward, not
        // back. No-op if recipient has no referees yet (the normal case).
        needsCheckpointReset[recipient] = true;

        emit VDAOLaunched(recipient, vgcAddr, vdaoForDaxSeed, 0);
    }

    /// @notice Register a reserve asset's ADDRESS (WBTC/ETH/PAXG) + its permanent
    ///         max-approvals. Required before:
    ///           - ETH path of T1/T2 (assetId == ASSET_ETH)
    ///           - T4 launch with that asset as `pairAssetChoice`
    /// @dev    USDC is configured at init and not settable here. The VDAX pool id
    ///         is NOT stored — it's resolved live per call (see `_daxPoolId`),
    ///         so this only needs the asset address.
    function setReserveAsset(uint8 assetId, address asset)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (asset == address(0)) revert InvalidConfig();
        if (assetId == ASSET_WBTC) wbtc = asset;
        else if (assetId == ASSET_ETH)  weth = asset;
        else if (assetId == ASSET_PAXG) paxg = asset;
        else revert InvalidConfig();
        // Permanent max-approval to VDAX (asset→VY swaps) + the VDAO DAX
        // (this asset as a base-launch second leg) so per-call SSTOREs go away.
        IERC20(asset).forceApprove(address(vdax),    type(uint256).max);
        IERC20(asset).forceApprove(address(vdaoDax), type(uint256).max);
        emit ReserveAssetSet(assetId, asset);
    }

    /// @dev Resolve a `pairAssetChoice` to its token ADDRESS only — no pool
    ///      lookup. The VDAX VY/<asset> pool id is resolved separately and LIVE
    ///      via `_daxPoolId` at the two sites that actually need it (pricing in
    ///      `_usdcToAsset`, swapping in `_swapAssetToVY`), so the intake path
    ///      never pays for a pool resolution it would discard.
    function _assetAddr(uint8 assetId) internal view returns (address asset) {
        if (assetId == ASSET_USDC) return address(usdc);
        if (assetId == ASSET_WBTC) return wbtc;
        if (assetId == ASSET_ETH)  return weth;
        if (assetId == ASSET_PAXG) return paxg;
        revert InvalidConfig();
    }

    /// @dev Live VDAX VY/<asset> pool id. Reverts if the asset has no pool —
    ///      `hasPool` disambiguates the valid pool-id-0 case from "not listed"
    ///      (both return 0 from `assetToPoolId`). Mirrors how the other officers
    ///      resolve DAX pools every call instead of caching a stale id.
    function _daxPoolId(address asset) internal view returns (uint256) {
        if (asset == address(0) || !vdax.hasPool(asset)) revert InvalidConfig();
        return vdax.assetToPoolId(asset);
    }

    /// @dev Refund any `msg.value` above `used` back to the original caller.
    ///      Gas-capped to 23000 — enough for any standard EOA `receive`/`fallback`
    ///      but blocks griefing via gas-consuming smart-wallet receive hooks.
    function _refundExcessEth(uint256 used) internal {
        uint256 excess = msg.value - used;
        if (excess == 0) return;
        (bool ok, ) = msg.sender.call{value: excess, gas: 23_000}("");
        if (!ok) revert RefundFailed();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ADMIN — BPS / PRICES / BANDS / WINDOW
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Shared cap validation for both bps setters (caps: VYO ≤ 9.9%,
    ///      others ≤ 99%).
    function _validateBps(uint16 vyo_, uint16 veo_, uint16 vlo_, uint16 vpoHL_) private pure {
        if (vyo_  > MAX_BPS_VYO)   revert InvalidBps();
        if (veo_  > MAX_BPS_OTHER) revert InvalidBps();
        if (vlo_  > MAX_BPS_OTHER) revert InvalidBps();
        if (vpoHL_> MAX_BPS_OTHER) revert InvalidBps();
    }

    function setBpsStandard(
        uint16 vyo_, uint16 veo_, uint16 vlo_, uint16 vpoHL_
    ) external onlyRole(ADMIN_ROLE) {
        _validateBps(vyo_, veo_, vlo_, vpoHL_);
        vyoYieldBps      = vyo_;
        veoTradingBps    = veo_;
        vloInterestBps   = vlo_;
        vpoHLBuilderBps  = vpoHL_;
        emit BpsSet("std", vyo_);
    }

    function setBpsVDAO(
        uint16 vyo_, uint16 veo_, uint16 vlo_, uint16 vpoHL_
    ) external onlyRole(ADMIN_ROLE) {
        _validateBps(vyo_, veo_, vlo_, vpoHL_);
        vyoYieldBpsVDAO      = vyo_;
        veoTradingBpsVDAO    = veo_;
        vloInterestBpsVDAO   = vlo_;
        vpoHLBuilderBpsVDAO  = vpoHL_;
        emit BpsSet("vdao", vyo_);
    }

    function setTierUsdcPrice(uint8 tier_, uint256 usdcPrice) external onlyRole(ADMIN_ROLE) {
        if (tier_ == 1)      tier1Usdc = usdcPrice;
        else if (tier_ == 2) tier2Usdc = usdcPrice;
        else if (tier_ == 3) tier3Usdc = usdcPrice;
        else if (tier_ == 4) tier4Usdc = usdcPrice;
        else revert InvalidTier();
        emit TierPriceSet(tier_, usdcPrice);
    }

    function setPaused(bool p) external onlyRole(ADMIN_ROLE) {
        paused = p;
        emit PausedSet(p);
    }

    /// @dev Zero-address guard + event emit. Caller is responsible for the
    ///      actual storage write that follows.
    function _emitAddrUpdate(bytes32 key, address newAddr) internal {
        if (newAddr == address(0)) revert InvalidAddress();
        emit AddressUpdated(key, newAddr);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // UUPS
    // ─────────────────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}
}
