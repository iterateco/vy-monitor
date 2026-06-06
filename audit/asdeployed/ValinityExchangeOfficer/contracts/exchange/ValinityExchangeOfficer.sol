// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// ─────────────────────────────────────────────────────────────────────────────
// External minimal interfaces
// ─────────────────────────────────────────────────────────────────────────────

interface IValinityDAX {
    function swapExactIn(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    /// @notice Returns the DAX VY/asset poolId for `asset`, or 0 if none.
    function assetToPoolId(address asset) external view returns (uint256);
}

interface IUniV3Router {
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

    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params)
        external payable returns (uint256 amountOut);
}

interface IUniV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title ValinityExchangeOfficer (VEO)
 * @notice The single public-facing trading router for the Valinity ecosystem.
 *         Charges a flat protocol fee (default 0.7%) on every swap. Standard
 *         swap fees convert to VY and land at the BuybackOfficer (VBO). V-DAO
 *         swaps charge the same 0.7% but push it direct to the V-DAO creator
 *         in V-DAO tokens (no VBO portion on V-DAO trades).
 *
 *         VEO is the ONLY public swap address whitelisted on the DAX, is
 *         whitelisted on the VY token (bypassing the 1% VY transfer fee), and
 *         is whitelisted on every V-DAO (bypassing the 0.7% V-DAO burn fee so
 *         VEO can redirect the equivalent to the creator instead).
 *
 *         Registration is VARO-only. Users acquire trading rights by paying
 *         VARO Tier 1; VARO calls `register(trader)` to flip the gate. The
 *         legacy self-register path is removed.
 *
 *  Fee priority for the 0.7% skim on standard swaps (two-sided routing —
 *  auto-detected per swap, picks whichever side has the cheaper VY path):
 *    ROUTE_VY        → transfer VY directly to VBO
 *    ROUTE_DAX_ASSET → asset → VY on DAX (our pool, no LP fee, private)
 *    ROUTE_USDC      → USDC → VY on Uniswap V2 (vyUsdcV2Router)
 *    ROUTE_EXTERNAL  → token → USDC on Uniswap V3, then USDC → VY on Uniswap V2
 *                      (V3 fee tier supplied per-swap by caller, fallback to
 *                       `defaultUniFee`)
 *
 *  Routes are auto-detected at swap time via `_routeFor(token)`:
 *  is-VY check → is-USDC check → VDAX `assetToPoolId` query → fallback EXTERNAL.
 *  No admin per-token configuration is required.
 *
 *  Notes:
 *   - Fee-on-transfer tokens are NOT supported as `tokenIn`. Swaps will revert
 *     when the downstream router tries to pull more than VEO received.
 *   - VEO holds zero balance between transactions; any dust accumulated due
 *     to integrator quirks can be rescued by ADMIN_ROLE via `rescueToken`.
 */
contract ValinityExchangeOfficer is
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

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS     = 200; // 2% hard cap

    /// @notice Per-trade V-DAO fee (0.7%, charged in V-DAO and pushed direct
    ///         to creator). Matches the intrinsic 0.7% burn fee that a non-VEO
    ///         transfer would pay — only the destination differs: VEO routes
    ///         it to the creator instead of burning. No buyback / VBO portion
    ///         on V-DAO swaps.
    uint16 public constant VDAO_CREATOR_BPS = 70;  // 0.7%

    // Ondo GMTokenManager selectors.
    bytes4 private constant ONDO_MINT_SELECTOR   = 0x445df08b; // mintWithAttestation
    bytes4 private constant ONDO_REDEEM_SELECTOR = 0x6eefea49; // redeemWithAttestation

    // Fee routes — auto-detected at swap time. Lower number = cheaper path.
    uint8 public constant ROUTE_VY        = 1; // token is VY (direct transfer)
    uint8 public constant ROUTE_DAX_ASSET = 2; // VDAX VY/asset pool (private)
    uint8 public constant ROUTE_USDC      = 3; // token is USDC (V2 USDC/VY)
    uint8 public constant ROUTE_EXTERNAL  = 4; // V3 token→USDC, V2 USDC→VY
    /// @dev Sentinel emitted in `SwapExecuted.route` when fee was 0.
    uint8 public constant ROUTE_NONE      = 255;

    // ─────────────────────────────────────────────────────────────────────────
    // STORAGE
    // ─────────────────────────────────────────────────────────────────────────

    IERC20  public vy;
    IERC20  public usdc;
    address public vbo;                       // BuybackOfficer — receives VY fees
    address private __deprecated_vro;         // was: vro
    address private __deprecated_house;       // was: house

    IValinityDAX  public dax;
    IUniV3Router  public uniRouter;
    address       public ondoGM;       // Ondo GMTokenManager

    /// @notice Flat protocol fee in bps charged on every swap (default 70 = 0.7%).
    uint16 public feeBps;

    /// @notice Default Uniswap V3 fee tier used as fallback for the
    ///         ROUTE_EXTERNAL fee leg when the caller passes 0.
    uint24 public defaultUniFee;

    uint256 private __deprecated_registrationFeeVY; // was: registrationFeeVY

    /// @notice Lifetime registration flag.
    mapping(address => bool) public isRegistered;

    mapping(address => uint8)  private __deprecated_feeRoute;   // was: feeRoute

    /// @notice V-DAO address → VDAX V-DAO/VY poolId. Set by VARO at
    ///         registration. Read by `_swapVDAOLeg` for the VY route. Stays
    ///         valid even if VDAX is paused/upgraded (cache captured at
    ///         registration). Non-V-DAO entries left over from the deprecated
    ///         admin-set path are inert (never read in the new code path).
    mapping(address => uint256) public daxPoolOf;

    mapping(address => uint24) private __deprecated_uniFeeTier; // was: uniFeeTier

    bool public paused;

    /// @notice Uniswap V2 router used for the USDC→VY fee leg.
    ///         Set post-upgrade via `setVyUsdcV2Router`. The V2 path is
    ///         hard-coded to `[USDC, VY]`.
    IUniV2Router02 public vyUsdcV2Router;

    /// @notice Cumulative VY-denominated trading fee paid by each trader.
    ///         Read by ValinityAllianceRegistrationOfficer (VARO) for referral
    ///         accounting. Monotonically increasing; never reset.
    mapping(address => uint256) public cumulativeUserFeeVY;

    /// @notice VARO instance — the only contract permitted to call
    ///         `register` (mark a trader as registered) and
    ///         `registerVDAO`.
    address public varo;

    /// @notice V-DAO address → creator. Non-zero creator implies the address
    ///         is a Valinity Decentralized Organization (V-DAO) launched via
    ///         VARO Tier 4. VEO charges a flat 0.7% in V-DAO and pushes it
    ///         direct to the creator on `swapVDAO` trades (no VBO portion).
    mapping(address => address) public vdaoCreator;

    /// @notice V-DAO address → V2-side pair asset (USDC/WBTC/WETH/PAXG). Set
    ///         by VARO at registration. Used by `_swapVDAOLeg` to route V2
    ///         hops through V2 `<pairAsset>/V-DAO` (the only V2 pair that
    ///         actually exists for this V-DAO).
    mapping(address => address) public vdaoPairAsset;

    uint16 private __deprecated_vdaoSkimBps; // was: vdaoSkimBps

    // ─────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────────

    event TraderRegistered(address indexed trader);
    event SwapExecuted(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeVYToVBO,
        uint8   route
    );
    event FeeRouted(address indexed token, uint256 amountIn, uint256 vyOut, uint8 routeTag);
    /// @notice Emitted after a swap increments the trader's lifetime VY fee total.
    event UserFeeAccrued(address indexed trader, uint256 vyFeeDelta, uint256 vyFeeTotal);

    event FeeBpsUpdated(uint16 newBps);
    event DefaultUniFeeSet(uint24 fee);
    event AddressUpdated(bytes32 indexed key, address newAddr);
    event PausedSet(bool paused);
    event VyUsdcV2RouterSet(address indexed router);
    event VDAORegistered(address indexed vdao, address indexed creator, uint256 daxPoolId, address pairAsset);
    event VDAOSwap(
        address indexed trader,
        address indexed vdao,
        address indexed otherToken,
        bool    sellingVDAO,
        uint256 amountIn,
        uint256 amountOut,
        uint256 creatorFeeVDAO
    );

    // ─────────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────────

    error NotRegistered();
    error AlreadyRegistered();
    error InvalidAddress();
    error RouteNotConfigured();
    error InvalidPool();
    error InvalidFee();
    error InsufficientOutput();
    error DeadlineExpired();
    error Paused();
    error SameToken();
    error V2RouterNotSet();
    error NotVaro();
    error NotVDAO();

    // ─────────────────────────────────────────────────────────────────────────
    // INITIALIZER
    // ─────────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address vy_,
        address usdc_,
        address vbo_,
        address dax_,
        address uniRouter_,
        address ondoGM_
    ) external initializer {
        if (
            admin_ == address(0) || vy_ == address(0) || usdc_ == address(0) ||
            vbo_ == address(0) || dax_ == address(0) || uniRouter_ == address(0)
        ) revert InvalidAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);

        vy        = IERC20(vy_);
        usdc      = IERC20(usdc_);
        vbo       = vbo_;
        dax       = IValinityDAX(dax_);
        uniRouter = IUniV3Router(uniRouter_);
        ondoGM    = ondoGM_;

        feeBps        = 70;     // 0.7%
        defaultUniFee = 3000;   // 0.3% V3 tier (fallback for ROUTE_EXTERNAL)

        // Pre-approve the routers we always use.
        IERC20(vy_).forceApprove(dax_, type(uint256).max);
        IERC20(usdc_).forceApprove(uniRouter_, type(uint256).max);
        IERC20(vy_).forceApprove(uniRouter_, type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────────────────────────────────

    modifier whenLive() {
        if (!isRegistered[msg.sender]) revert NotRegistered();
        if (paused) revert Paused();
        _;
    }

    modifier beforeDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // REGISTRATION
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Mark a trader as registered. Callable ONLY by VARO. VARO is
    ///         responsible for collecting the Tier 1 fee (USDC at TWAP) and
    ///         all referrer accounting — VEO is a pure flag-flip.
    /// @dev    Idempotent: if `trader` is already registered (e.g. legacy
    ///         user from the deprecated self-register path), this is a no-op
    ///         success. That keeps VARO's `_activateT1` path working when a
    ///         pre-existing trader pays for a higher tier.
    function register(address trader) external nonReentrant {
        if (msg.sender != varo)   revert NotVaro();
        if (paused)               revert Paused();
        if (trader == address(0)) revert InvalidAddress();
        if (isRegistered[trader]) return;

        isRegistered[trader] = true;
        emit TraderRegistered(trader);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // SWAP ROUTES
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Swap on the Valinity DAX (VY ↔ asset).
    /// @dev Two-sided fee routing: fee is skimmed from whichever side has the
    ///      cheaper VY path (auto-detected). `minFeeVYOut` is forwarded only
    ///      for routes that cross a public V2 pool (USDC, EXTERNAL); pass 0
    ///      otherwise. `uniFeeForFeeLeg` is only used when the picked route
    ///      is EXTERNAL; pass 0 to fall back to `defaultUniFee`.
    function swapDAX(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 poolId,
        uint256 minFeeVYOut,
        uint24  uniFeeForFeeLeg,
        uint256 deadline
    )
        external
        nonReentrant
        whenLive
        beforeDeadline(deadline)
        returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut) revert SameToken();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        (bool fromInput, address feeToken, uint8 route, uint256 feeDaxPool) = _pickFeeSide(tokenIn, tokenOut);
        uint256 vyFee;

        if (fromInput) {
            uint256 amtAfterFee;
            (amtAfterFee, vyFee) = _collectFeeAsVY(feeToken, amountIn, route, feeDaxPool, uniFeeForFeeLeg, minFeeVYOut);
            _ensureApproval(tokenIn, address(dax));
            amountOut = dax.swapExactIn(poolId, tokenIn, amtAfterFee, minAmountOut, msg.sender);
        } else {
            _ensureApproval(tokenIn, address(dax));
            uint256 grossOut = dax.swapExactIn(poolId, tokenIn, amountIn, 0, address(this));
            uint256 netOut;
            (netOut, vyFee) = _collectFeeAsVY(feeToken, grossOut, route, feeDaxPool, uniFeeForFeeLeg, minFeeVYOut);
            if (netOut < minAmountOut) revert InsufficientOutput();
            IERC20(tokenOut).safeTransfer(msg.sender, netOut);
            amountOut = netOut;
        }

        _accrueUserFee(msg.sender, vyFee);
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut, vyFee, vyFee == 0 ? ROUTE_NONE : route);
    }

    /// @notice Swap on Uniswap V3 (single-hop) with two-sided fee routing.
    /// @param minFeeVYOut     Lower bound on VY → VBO from the fee leg (MEV guard).
    ///                        Pass 0 only when fee route is VY or DAX_ASSET.
    /// @param uniFeeForFeeLeg V3 fee tier for the fee leg's token→USDC swap
    ///                        when ROUTE_EXTERNAL is picked. Pass 0 for default.
    function swapUniV3(
        address tokenIn,
        address tokenOut,
        uint24  poolFee,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 minFeeVYOut,
        uint24  uniFeeForFeeLeg,
        uint256 deadline
    )
        external
        nonReentrant
        whenLive
        beforeDeadline(deadline)
        returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut) revert SameToken();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        (bool fromInput, address feeToken, uint8 route, uint256 feeDaxPool) = _pickFeeSide(tokenIn, tokenOut);
        uint256 vyFee;

        _ensureApproval(tokenIn, address(uniRouter));

        if (fromInput) {
            uint256 amtAfterFee;
            (amtAfterFee, vyFee) = _collectFeeAsVY(feeToken, amountIn, route, feeDaxPool, uniFeeForFeeLeg, minFeeVYOut);
            amountOut = uniRouter.exactInputSingle(
                IUniV3Router.ExactInputSingleParams({
                    tokenIn:           tokenIn,
                    tokenOut:          tokenOut,
                    fee:               poolFee,
                    recipient:         msg.sender,
                    deadline:          deadline,
                    amountIn:          amtAfterFee,
                    amountOutMinimum:  minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );
        } else {
            uint256 grossOut = uniRouter.exactInputSingle(
                IUniV3Router.ExactInputSingleParams({
                    tokenIn:           tokenIn,
                    tokenOut:          tokenOut,
                    fee:               poolFee,
                    recipient:         address(this),
                    deadline:          deadline,
                    amountIn:          amountIn,
                    amountOutMinimum:  0,
                    sqrtPriceLimitX96: 0
                })
            );
            uint256 netOut;
            (netOut, vyFee) = _collectFeeAsVY(feeToken, grossOut, route, feeDaxPool, uniFeeForFeeLeg, minFeeVYOut);
            if (netOut < minAmountOut) revert InsufficientOutput();
            IERC20(tokenOut).safeTransfer(msg.sender, netOut);
            amountOut = netOut;
        }

        _accrueUserFee(msg.sender, vyFee);
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut, vyFee, vyFee == 0 ? ROUTE_NONE : route);
    }

    /// @notice Multi-hop swap via Uniswap V3 encoded path. Input-side fee only
    ///         (tokenOut is path-encoded, not a parameter).
    /// @param path             Encoded as token0|fee0|token1|fee1|token2...
    /// @param uniFeeForFeeLeg  V3 fee tier for tokenIn→USDC fee leg when
    ///                         ROUTE_EXTERNAL is picked. Pass 0 for default.
    function swapBridged(
        bytes calldata path,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        uint256 minFeeVYOut,
        uint24  uniFeeForFeeLeg,
        uint256 deadline
    )
        external
        nonReentrant
        whenLive
        beforeDeadline(deadline)
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        (uint8 route, uint256 feeDaxPool) = _routeFor(tokenIn);
        (uint256 amtAfterFee, uint256 vyFee) =
            _collectFeeAsVY(tokenIn, amountIn, route, feeDaxPool, uniFeeForFeeLeg, minFeeVYOut);

        _ensureApproval(tokenIn, address(uniRouter));
        amountOut = uniRouter.exactInput(
            IUniV3Router.ExactInputParams({
                path:             path,
                recipient:        msg.sender,
                deadline:         deadline,
                amountIn:         amtAfterFee,
                amountOutMinimum: minOut
            })
        );

        _accrueUserFee(msg.sender, vyFee);
        emit SwapExecuted(msg.sender, tokenIn, address(0), amountIn, amountOut, vyFee, vyFee == 0 ? ROUTE_NONE : route);
    }

    /// @notice Mint an Ondo GM token (NVDAon, TSLAon, …).
    /// @dev VEO is the whitelisted caller on Ondo. `quoteCalldata` is the
    ///      prebuilt Quote+attestation body (selector stripped — VEO prepends
    ///      ONDO_MINT_SELECTOR).
    function swapMintOndoGM(
        address tokenIn,
        uint256 amountIn,
        uint24  uniFeeForUSDC,
        uint256 minUsdcAfterSwap,
        uint256 minFeeVYOut,
        address gmToken,
        bytes calldata quoteCalldata,
        uint256 deadline
    )
        external
        nonReentrant
        whenLive
        beforeDeadline(deadline)
        returns (uint256 mintedAmount)
    {
        if (ondoGM == address(0) || gmToken == address(0)) revert InvalidAddress();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Fee leg may be tokenIn→USDC on V3 (ROUTE_EXTERNAL). Reuse
        // `uniFeeForUSDC` since it's the same swap as the user's leg below.
        (uint8 route, uint256 feeDaxPool) = _routeFor(tokenIn);
        (uint256 amtAfterFee, uint256 vyFee) =
            _collectFeeAsVY(tokenIn, amountIn, route, feeDaxPool, uniFeeForUSDC, minFeeVYOut);

        if (tokenIn != address(usdc)) {
            _ensureApproval(tokenIn, address(uniRouter));
            uniRouter.exactInputSingle(
                IUniV3Router.ExactInputSingleParams({
                    tokenIn:           tokenIn,
                    tokenOut:          address(usdc),
                    fee:               uniFeeForUSDC,
                    recipient:         address(this),
                    deadline:          deadline,
                    amountIn:          amtAfterFee,
                    amountOutMinimum:  minUsdcAfterSwap,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        _ensureApproval(address(usdc), ondoGM);

        uint256 gmBefore = IERC20(gmToken).balanceOf(address(this));

        (bool ok, ) = ondoGM.call(abi.encodePacked(ONDO_MINT_SELECTOR, quoteCalldata));
        if (!ok) _bubbleRevert();

        mintedAmount = IERC20(gmToken).balanceOf(address(this)) - gmBefore;
        if (mintedAmount == 0) revert InsufficientOutput();

        IERC20(gmToken).safeTransfer(msg.sender, mintedAmount);

        // Refund any USDC Ondo didn't consume. VEO holds zero USDC outside this
        // call so anything sitting here is the user's dust.
        uint256 usdcDust = usdc.balanceOf(address(this));
        if (usdcDust != 0) usdc.safeTransfer(msg.sender, usdcDust);

        _accrueUserFee(msg.sender, vyFee);
        emit SwapExecuted(msg.sender, tokenIn, gmToken, amountIn, mintedAmount, vyFee, vyFee == 0 ? ROUTE_NONE : route);
    }

    /// @notice Redeem a GM token to USDC (and optionally swap USDC → tokenOut).
    function swapRedeemOndoGM(
        address gmToken,
        uint256 gmAmount,
        bytes calldata quoteCalldata,
        address tokenOut,
        uint24  uniFeeForOut,
        uint256 minAmountOut,
        uint256 minFeeVYOut,
        uint256 deadline
    )
        external
        nonReentrant
        whenLive
        beforeDeadline(deadline)
        returns (uint256 amountOut)
    {
        if (ondoGM == address(0) || gmToken == address(0) || tokenOut == address(0)) {
            revert InvalidAddress();
        }

        IERC20(gmToken).safeTransferFrom(msg.sender, address(this), gmAmount);
        _ensureApproval(gmToken, ondoGM);

        uint256 usdcBefore = usdc.balanceOf(address(this));
        (bool ok, ) = ondoGM.call(abi.encodePacked(ONDO_REDEEM_SELECTOR, quoteCalldata));
        if (!ok) _bubbleRevert();

        uint256 usdcOut = usdc.balanceOf(address(this)) - usdcBefore;
        if (usdcOut == 0) revert InsufficientOutput();

        // Refund any GM token Ondo didn't consume (symmetric with mint dust).
        uint256 gmDust = IERC20(gmToken).balanceOf(address(this));
        if (gmDust != 0) IERC20(gmToken).safeTransfer(msg.sender, gmDust);

        // Fee is taken from the USDC intermediate. Auto-detect picks ROUTE_USDC,
        // so neither daxPool nor uniFeeForFeeLeg is needed (pass 0).
        (uint8 route, ) = _routeFor(address(usdc));
        (uint256 usdcAfterFee, uint256 vyFee) =
            _collectFeeAsVY(address(usdc), usdcOut, route, 0, 0, minFeeVYOut);

        if (tokenOut == address(usdc)) {
            if (usdcAfterFee < minAmountOut) revert InsufficientOutput();
            amountOut = usdcAfterFee;
            usdc.safeTransfer(msg.sender, amountOut);
        } else {
            _ensureApproval(address(usdc), address(uniRouter));
            amountOut = uniRouter.exactInputSingle(
                IUniV3Router.ExactInputSingleParams({
                    tokenIn:           address(usdc),
                    tokenOut:          tokenOut,
                    fee:               uniFeeForOut,
                    recipient:         msg.sender,
                    deadline:          deadline,
                    amountIn:          usdcAfterFee,
                    amountOutMinimum:  minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        _accrueUserFee(msg.sender, vyFee);
        emit SwapExecuted(msg.sender, gmToken, tokenOut, gmAmount, amountOut, vyFee, vyFee == 0 ? ROUTE_NONE : route);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // V-DAO SWAP PATH (Tier 4 Valinity Decentralized Organization tokens)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Register a VARO-launched V-DAO. Only callable by VARO. Stores
    ///         the creator, the VDAX V-DAO/VY poolId (cached so V-DAO swaps
    ///         don't depend on VDAX availability for routing), and the
    ///         V2-side pair asset. Idempotent on matching creator;
    ///         `daxPoolId` and `pairAsset` can be re-set defensively.
    function registerVDAO(
        address vdao,
        address creator,
        uint256 daxPoolId,
        address pairAsset
    ) external {
        if (msg.sender != varo) revert NotVaro();
        if (
            vdao == address(0) ||
            creator == address(0) ||
            daxPoolId == 0 ||
            pairAsset == address(0)
        ) revert InvalidAddress();
        address existing = vdaoCreator[vdao];
        if (existing == creator) {
            daxPoolOf[vdao]     = daxPoolId;
            vdaoPairAsset[vdao] = pairAsset;
            return;
        }
        if (existing != address(0)) revert AlreadyRegistered();
        vdaoCreator[vdao]   = creator;
        daxPoolOf[vdao]     = daxPoolId;
        vdaoPairAsset[vdao] = pairAsset;
        emit VDAORegistered(vdao, creator, daxPoolId, pairAsset);
    }

    /// @notice Swap V-DAO ↔ otherToken via VEO.
    /// @dev    Fee model (V-DAO-specific):
    ///           - 0.7% of the V-DAO leg → creator (direct push in V-DAO).
    ///         Outside VEO, the V-DAO contract burns 0.7% on every transfer;
    ///         VEO is whitelisted on the V-DAO so the burn is bypassed, and
    ///         VEO redirects the same 0.7% to the creator instead.
    ///         Routing (per V-DAO's stored `pairAsset`):
    ///           - otherToken == VY        → VDAX V-DAO/VY pool (private, direct)
    ///           - otherToken == pairAsset → V2 <pairAsset>/V-DAO pool (direct)
    ///           - anything else           → revert; webapp must compose
    ///                                       otherToken → {VY|pairAsset} externally,
    ///                                       then call swapVDAO.
    /// @param  vdao         The V-DAO address (must be registered via VARO).
    /// @param  otherToken   The counter-side of the trade (must be VY or pairAsset).
    /// @param  sellingVDAO  true: V-DAO in, otherToken out. false: reverse.
    /// @param  amountIn     Input amount.
    /// @param  minAmountOut Min output the caller will accept (slippage guard).
    /// @param  deadline     Tx deadline.
    function swapVDAO(
        address vdao,
        address otherToken,
        bool    sellingVDAO,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    )
        external
        nonReentrant
        whenLive
        beforeDeadline(deadline)
        returns (uint256 amountOut)
    {
        address creator = vdaoCreator[vdao];
        if (creator == address(0)) revert NotVDAO();
        if (vdao == otherToken)    revert SameToken();

        uint256 creatorFee;

        if (sellingVDAO) {
            // Take fee from V-DAO input, swap remainder to otherToken for user.
            IERC20(vdao).safeTransferFrom(msg.sender, address(this), amountIn);
            uint256 amtAfterFee;
            (amtAfterFee, creatorFee) = _collectVDAOFee(vdao, amountIn, creator);
            amountOut = _swapVDAOLeg(vdao, otherToken, true, amtAfterFee, minAmountOut, msg.sender, deadline);
        } else {
            // Swap otherToken → V-DAO to VEO, take fee from V-DAO output, send net to user.
            IERC20(otherToken).safeTransferFrom(msg.sender, address(this), amountIn);
            uint256 grossOut = _swapVDAOLeg(vdao, otherToken, false, amountIn, 0, address(this), deadline);
            uint256 netOut;
            (netOut, creatorFee) = _collectVDAOFee(vdao, grossOut, creator);
            if (netOut < minAmountOut) revert InsufficientOutput();
            IERC20(vdao).safeTransfer(msg.sender, netOut);
            amountOut = netOut;
        }

        emit VDAOSwap(msg.sender, vdao, otherToken, sellingVDAO, amountIn, amountOut, creatorFee);
    }

    /// @dev Take the 0.7% creator fee out of `amount` and push it to `creator`
    ///      in V-DAO. Outside VEO, the V-DAO contract burns the same 0.7% on
    ///      transfer; VEO replaces burn with creator-direct. The `VDAOSwap`
    ///      event carries `creatorFee`, so no additional fee event is emitted.
    function _collectVDAOFee(address vdao, uint256 amount, address creator)
        internal
        returns (uint256 amountAfterFee, uint256 creatorFee)
    {
        creatorFee = (amount * VDAO_CREATOR_BPS) / BPS_DENOMINATOR;
        unchecked { amountAfterFee = amount - creatorFee; }
        if (creatorFee != 0) {
            IERC20(vdao).safeTransfer(creator, creatorFee);
        }
    }

    /// @dev Execute the V-DAO ↔ otherToken leg using the best available venue.
    ///      Routes (per the V-DAO's pair-asset config):
    ///         otherToken == VY        → VDAX V-DAO/VY pool (direct)
    ///         otherToken == pairAsset → V2 <pairAsset>/V-DAO (direct)
    ///         otherToken == anything  → revert (webapp composes multi-step)
    function _swapVDAOLeg(
        address vdao,
        address otherToken,
        bool    selling,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (otherToken == address(vy)) {
            uint256 poolId = daxPoolOf[vdao];
            if (poolId == 0) revert InvalidPool();
            address tokenIn_ = selling ? vdao : address(vy);
            _ensureApproval(tokenIn_, address(dax));
            amountOut = dax.swapExactIn(poolId, tokenIn_, amountIn, minOut, recipient);
            return amountOut;
        }
        address pairAsset = vdaoPairAsset[vdao];
        if (pairAsset != address(0) && otherToken == pairAsset) {
            amountOut = selling
                ? _v2SwapDirect(vdao, pairAsset, amountIn, minOut, recipient, deadline)
                : _v2SwapDirect(pairAsset, vdao, amountIn, minOut, recipient, deadline);
            return amountOut;
        }
        // Other routes are not supported on-chain. Webapp must compose:
        //   otherToken → pairAsset (or → VY) externally, then call swapVDAO.
        revert RouteNotConfigured();
    }

    /// @dev Generic single-hop V2 swap using `vyUsdcV2Router`. The router is
    ///      pair-agnostic; reverts if no pair exists for (tokenIn, tokenOut).
    function _v2SwapDirect(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        IUniV2Router02 router = vyUsdcV2Router;
        if (address(router) == address(0)) revert V2RouterNotSet();
        _ensureApproval(tokenIn, address(router));

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minOut,
            path,
            recipient,
            deadline
        );
        amountOut = amounts[1];
    }

    /// @dev Increments the trader's lifetime VY fee total. No-op when fee is 0.
    ///      ValinityAllianceRegistrationOfficer (VARO) reads `cumulativeUserFeeVY`
    ///      and pays the referrer their bps share of the delta since last
    ///      settlement.
    function _accrueUserFee(address trader, uint256 vyFee) internal {
        if (vyFee == 0) return;
        uint256 newTotal = cumulativeUserFeeVY[trader] + vyFee;
        cumulativeUserFeeVY[trader] = newTotal;
        emit UserFeeAccrued(trader, vyFee, newTotal);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FEE CONVERSION (always lands as VY in VBO)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Auto-detect the cheapest VY route for `token`. Always returns a
    ///      route (1-4). For ROUTE_DAX_ASSET, also returns the VDAX poolId
    ///      (non-zero); for other routes, daxPoolId == 0.
    function _routeFor(address token) internal view returns (uint8 route, uint256 daxPoolId) {
        if (token == address(vy))   return (ROUTE_VY, 0);
        if (token == address(usdc)) return (ROUTE_USDC, 0);
        daxPoolId = dax.assetToPoolId(token);
        if (daxPoolId != 0)         return (ROUTE_DAX_ASSET, daxPoolId);
        return (ROUTE_EXTERNAL, 0);
    }

    /// @dev Pick which side of a swap to take the fee from. Auto-detects the
    ///      route for each side via `_routeFor` and uses the cheaper path
    ///      (lower route number wins; ties favor the input side so we can
    ///      skim before swapping).
    function _pickFeeSide(address tokenIn, address tokenOut)
        internal view
        returns (bool fromInput, address feeToken, uint8 route, uint256 daxPoolId)
    {
        (uint8 rIn,  uint256 pIn)  = _routeFor(tokenIn);
        (uint8 rOut, uint256 pOut) = _routeFor(tokenOut);
        if (rIn <= rOut) return (true,  tokenIn,  rIn,  pIn);
        return                 (false, tokenOut, rOut, pOut);
    }

    /// @dev Skim `feeBps` of `amount` and convert to VY → VBO via `route`.
    /// @param token            Fee-input token (chosen by caller).
    /// @param amount           Gross amount to skim from.
    /// @param route            Route to use (pre-selected by `_pickFeeSide` or `_routeFor`).
    /// @param daxPoolId        Required when route == ROUTE_DAX_ASSET; ignored otherwise.
    /// @param uniFeeForFeeLeg  V3 fee tier for token→USDC. Used only when
    ///                         route == ROUTE_EXTERNAL. Pass 0 → `defaultUniFee`.
    /// @param minFeeVYOut      Lower bound on VY delivered to VBO. Ignored for
    ///                         VY and DAX_ASSET routes (no MEV exposure).
    function _collectFeeAsVY(
        address token,
        uint256 amount,
        uint8   route,
        uint256 daxPoolId,
        uint24  uniFeeForFeeLeg,
        uint256 minFeeVYOut
    )
        internal
        returns (uint256 amountAfterFee, uint256 vyToVbo)
    {
        uint256 fee = (amount * feeBps) / BPS_DENOMINATOR;
        if (fee == 0) {
            return (amount, 0);
        }
        unchecked { amountAfterFee = amount - fee; }

        if (route == ROUTE_VY) {
            vy.safeTransfer(vbo, fee);
            vyToVbo = fee;
        } else if (route == ROUTE_DAX_ASSET) {
            _ensureApproval(token, address(dax));
            vyToVbo = dax.swapExactIn(daxPoolId, token, fee, 0, vbo);
        } else if (route == ROUTE_USDC) {
            vyToVbo = _swapUsdcToVyV2(fee, minFeeVYOut, vbo);
        } else {
            // ROUTE_EXTERNAL — only remaining branch by construction of `_routeFor`.
            uint24 v3Fee = uniFeeForFeeLeg == 0 ? defaultUniFee : uniFeeForFeeLeg;
            _ensureApproval(token, address(uniRouter));
            uint256 usdcOut = uniRouter.exactInputSingle(
                IUniV3Router.ExactInputSingleParams({
                    tokenIn:           token,
                    tokenOut:          address(usdc),
                    fee:               v3Fee,
                    recipient:         address(this),
                    deadline:          block.timestamp,
                    amountIn:          fee,
                    amountOutMinimum:  0,
                    sqrtPriceLimitX96: 0
                })
            );
            vyToVbo = _swapUsdcToVyV2(usdcOut, minFeeVYOut, vbo);
        }

        emit FeeRouted(token, fee, vyToVbo, route);
    }

    /// @dev Internal helper: swap `amountIn` USDC → VY via the configured V2
    ///      router using the fixed path [USDC, VY]. Thin wrapper over
    ///      `_v2SwapDirect` with the deadline pinned to `block.timestamp`
    ///      (the outer user-facing swap has its own deadline check).
    function _swapUsdcToVyV2(uint256 amountIn, uint256 minVyOut, address recipient)
        internal
        returns (uint256 vyOut)
    {
        return _v2SwapDirect(address(usdc), address(vy), amountIn, minVyOut, recipient, block.timestamp);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FRONTEND QUOTE HELPERS (pure / view — no backend required)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Splits `amountIn` into (afterFee, fee) using the current `feeBps`.
    /// @dev Pure helper so a frontend can size downstream Uniswap/DAX quotes.
    function previewFee(uint256 amountIn)
        external
        view
        returns (uint256 amountAfterFee, uint256 fee)
    {
        fee = (amountIn * feeBps) / BPS_DENOMINATOR;
        unchecked { amountAfterFee = amountIn - fee; }
    }

    /// @notice Returns the auto-detected fee route for `token` and the VDAX
    ///         poolId (non-zero only when route == ROUTE_DAX_ASSET). Frontend
    ///         pairs this with off-chain V3/V2/DAX quoting to compute
    ///         `minFeeVYOut` and pick `uniFeeForFeeLeg` (only relevant for
    ///         ROUTE_EXTERNAL).
    function quoteFeeRoute(address token)
        external
        view
        returns (uint8 route, uint256 daxPoolId)
    {
        (route, daxPoolId) = _routeFor(token);
    }

    function _ensureApproval(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), spender) < type(uint128).max) {
            IERC20(token).forceApprove(spender, type(uint256).max);
        }
    }

    /// @dev Bubble up the last external call's revert reason verbatim.
    function _bubbleRevert() private pure {
        assembly {
            let s := returndatasize()
            let p := mload(0x40)
            returndatacopy(p, 0, s)
            revert(p, s)
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═════════════════════════════════════════════════════════════════════════

    function setFeeBps(uint16 newBps) external onlyRole(ADMIN_ROLE) {
        if (newBps > MAX_FEE_BPS) revert InvalidFee();
        feeBps = newBps;
        emit FeeBpsUpdated(newBps);
    }

    function setDefaultUniFee(uint24 fee) external onlyRole(ADMIN_ROLE) {
        defaultUniFee = fee;
        emit DefaultUniFeeSet(fee);
    }

    function setVBO(address newVbo)     external onlyRole(ADMIN_ROLE) { _setAddr("vbo",  newVbo);  vbo = newVbo; }
    function setVaro(address newVaro)   external onlyRole(ADMIN_ROLE) { _setAddr("varo", newVaro); varo = newVaro; }
    function setDAX(address newDax)     external onlyRole(ADMIN_ROLE) { _setAddr("dax",  newDax);  dax = IValinityDAX(newDax); }
    function setUniRouter(address newR) external onlyRole(ADMIN_ROLE) { _setAddr("uni",  newR);    uniRouter = IUniV3Router(newR); }
    function setOndoGM(address newOndo) external onlyRole(ADMIN_ROLE) { _setAddr("ondo", newOndo); ondoGM = newOndo; }

    function setPaused(bool p) external onlyRole(ADMIN_ROLE) {
        paused = p;
        emit PausedSet(p);
    }

    /// @notice Set the Uniswap V2 router used for the USDC → VY fee leg.
    ///         Pre-approves USDC → router at max so subsequent fee swaps
    ///         don't pay an approval gas surcharge.
    function setVyUsdcV2Router(address router) external onlyRole(ADMIN_ROLE) {
        if (router == address(0)) revert InvalidAddress();
        vyUsdcV2Router = IUniV2Router02(router);
        usdc.forceApprove(router, type(uint256).max);
        emit VyUsdcV2RouterSet(router);
    }

    function _setAddr(bytes32 key, address newAddr) internal {
        if (newAddr == address(0)) revert InvalidAddress();
        emit AddressUpdated(key, newAddr);
    }

    /// @notice Rescue stuck tokens. VEO holds zero balance between txs.
    function rescueToken(address token, address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // UUPS
    // ─────────────────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    /// @dev Storage gap for future upgrades.
    ///      Original deployment reserved __gap[40] at slot 15. The 7291bbd
    ///      upgrade consumed 1 (cumulativeUserFeeVY). This upgrade consumes 4
    ///      (varo, vdaoCreator, vdaoPairAsset, __deprecated_vdaoSkimBps).
    ///      40 - 1 - 4 = 35.
    uint256[35] private __gap;
}
