// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Canonical V3 position types shared with VRT (custody) and VLM (authoring).
// Field ordering is consensus-critical; never import a local copy.
import { PositionSnapshot, pairKeyOf } from "../interfaces/IValinityPositions.sol";
import { V3ZapMath } from "../library/V3ZapMath.sol";

interface IUniswapV3Pool {
    function slot0()
        external view
        returns (
            uint160 sqrtPriceX96,
            int24   tick,
            uint16  observationIndex,
            uint16  observationCardinality,
            uint16  observationCardinalityNext,
            uint8   feeProtocol,
            bool    unlocked
        );
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

interface INonfungiblePositionManager {
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IValinityCapOfficer {
    function getAssetCap(address asset) external view returns (uint256);
    function effectiveFloor() external view returns (uint256);
    function increaseAssetCap(address asset, uint256 amount) external;
    function decreaseAssetCap(address asset, uint256 amount) external;
    function getLTV(address asset) external view returns (uint256);
    function getTotalCirculatingVY() external view returns (uint256);
}

interface IValinityLiquidityManager {
    function refreshSnapshot(bytes32 pairKey) external;
    function assertTwapAligned(bytes32 pairKey) external view;
    function snapbackHome() external returns (bytes32 pairKey, uint256 newTokenId);
}

/// @dev VRYO-local extension of the shared VRT surface. The shared header in
///      IValinityPositions.sol defines only what VLM needs; VRYO additionally
///      needs the reader + recall + token-pull surface.
interface IValinityReserveTreasury {
    function deployForYield(
        address[] calldata assets,
        uint256[] calldata amounts,
        address recipient
    ) external;

    function getPositionSnapshot(bytes32 pairKey)
        external view returns (PositionSnapshot memory);

    function decreasePositionLiquidity(
        bytes32 pairKey,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);
}

/**
 * @title ValinityReserveYieldOfficer (VRYO) — Uniswap V3 edition
 * @notice Deploys a fraction of VRT's reserves into VRT-owned V3 positions.
 *         Deployed amount tracks VY staked in StakingRouter.
 */
contract ValinityReserveYieldOfficer is
    UUPSUpgradeable,
    AccessControl,
    ReentrancyGuardTransient,
    Initializable
{
    using SafeERC20 for IERC20;

    // ── roles ──────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ── constants ──────────────────────────────────────────────────────────
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_DEPLOY_RATIO_BPS = 9500;
    uint256 public constant DEFAULT_DEPLOY_RATIO_BPS = 8500;
    uint256 public constant DEFAULT_KEEPER_THRESHOLD_BPS = 100;
    uint256 public constant MAX_KEEPER_THRESHOLD_BPS = 2000;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;            // hard cap 5%
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50;         // 0.50%
    /// @notice Buffer added to `block.timestamp` when VRYO calls VRT's
    ///         `decreasePositionLiquidity`. Long enough to survive normal
    ///         re-org / mempool latency, short enough that a stale tx can't
    ///         settle hours later against a moved pool.
    uint256 public constant DEADLINE_BUFFER = 5 minutes;

    /// @dev Hard cap on multi-pass loop iterations per execute() to bound gas.
    uint256 public constant MAX_LOOP_PASSES = 12;

    /// @dev Per-tx skip-mask bits for the two managed pairs. Stable values
    ///      independent of pair-key hashes so we can avoid storage reads on
    ///      the hot loop and keep the picker pure-cheap.
    uint8 private constant BIT_WW = 1;
    uint8 private constant BIT_PU = 2;

    // ── reserve refs (set once at initialize; not immutable so the impl
    //     can be upgraded behind the proxy without redeploying state) ───────
    IValinityCapOfficer public vco;
    IValinityReserveTreasury public vrt;
    ISwapRouter public swapRouter;
    INonfungiblePositionManager public npm;
    IERC20 public weth;
    IERC20 public wbtc;
    IERC20 public paxg;
    /// @notice Counterparty token for the PAXG pair. NOT a managed reserve —
    ///         VRT must never receive USDC; the close/recall path on VLM
    ///         swaps any USDC back into PAXG before settling to VRT, and
    ///         VRYO's recall reverse-zaps USDC into the recall asset.
    IERC20 public usdc;

    /// @notice WETH/WBTC pair: shared by WETH and WBTC deployments.
    bytes32 public PAIR_WETH_WBTC;
    /// @notice PAXG/USDC pair: sole pair for PAXG deployments. USDC counterparty.
    bytes32 public PAIR_PAXG_USDC;

    // ── configurable ───────────────────────────────────────────────────────
    /// @custom:oz-renamed-from stakingRouter
    /// @dev V1 slot: was `address stakingRouter`. Unused in V2; kept for
    ///      storage layout compatibility.
    address public __deprecated_stakingRouter;
    IValinityLiquidityManager public vlm;
    /// @custom:oz-renamed-from uniVyUsdcPair
    /// @dev V1 slot: was `IUniswapV2Pair uniVyUsdcPair`. Unused in V2.
    address public __deprecated_uniVyUsdcPair;
    /// @custom:oz-renamed-from vyIsToken0
    /// @dev V1 slot: was `bool vyIsToken0`. Unused in V2.
    bool public __deprecated_vyIsToken0;
    /// @custom:oz-renamed-from dax
    /// @dev V1 slot: was `IValinityDAX dax`. Unused in V2.
    address public __deprecated_dax;
    /// @custom:oz-renamed-from vdaxToken
    /// @dev V1 slot: was `IERC20 vdaxToken`. Unused in V2.
    address public __deprecated_vdaxToken;

    mapping(bytes32 pairKey => uint24 feeTier) public pairFee;

    uint256 public deployRatioBps;
    /// @dev Deprecated in V3. Kept as a dead slot for storage layout
    ///      compatibility with deployed proxy state.
    uint256 public capFloor;
    uint256 public slippageBps;
    bool public paused;

    // ── Option D state ─────────────────────────────────────────────────────
    /// @notice Total VY currently deployed across all pairs (= Σ pairPrincipal).
    uint256 public capVRYO_total;
    /// @notice VY-equivalent principal per pair (frozen at deploy time).
    ///         Decremented on recall by the VY units retired (not by physical
    ///         token amounts). Yield accrues silently in VRT free balance.
    mapping(bytes32 pairKey => uint256 vyUnits) public pairPrincipal;

    // ── V2 storage (appended) ──────────────────────────────────────────────
    /// @notice Snapshot of `vco.getTotalCirculatingVY()` at the last
    ///         executed run. Used as the reference for the keeper drift
    ///         trigger on subsequent calls.
    uint256 public lastCirculatingVY;
    /// @notice Drift threshold (bps of `lastCirculatingVY`) below which an
    ///         `execute()` call silently no-ops. Default 100 (1%).
    uint16 public keeperThresholdBps;

    // ── events ─────────────────────────────────────────────────────────────
    event Executed(uint256 circulatingVY, uint256 target, int256 netDelta);
    event SnapbackInvoked(bytes32 indexed pairKey, uint256 newTokenId);
    event SnapbackSkipped(bytes reason);
    event ExecuteSkippedPaused();
    event ExecuteSkippedBelowThreshold(uint256 lastCirculating, uint256 currentCirculating);
    event Deployed(address indexed asset, uint256 vyTake, bytes32 indexed pairKey, uint256 pullAmount, uint128 liquidityMinted);
    event Recalled(address indexed asset, uint256 vyReduced, bytes32 indexed pairKey, uint128 liquidityBurned, uint256 amount0Out, uint256 amount1Out);
    event DeployRatioUpdated(uint256 newBps);
    event SlippageUpdated(uint256 newBps);
    event KeeperThresholdUpdated(uint16 newBps);
    event VlmUpdated(address indexed newVlm);
    event PairFeeUpdated(bytes32 indexed pairKey, uint24 fee);
    event PausedUpdated(bool paused);
    event SystemReset(address indexed caller);
    event TargetClamped(uint256 residualVY, bool isDeploy);

    // ── errors ─────────────────────────────────────────────────────────────
    error PairsNotConfigured();
    error InvalidAddress();
    error InvalidParam();
    error InvalidAsset();
    error InvalidFee();
    error PairHasLiveDeployments();
    error InvariantViolation(address token);

    // ── constructor / initializer ──────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer for the UUPS proxy. Same 9 args as the prior
    ///         constructor; behaviour is identical.
    function initialize(
        address _admin,
        address _vco,
        address _vrt,
        address _swapRouter,
        address _npm,
        address _weth,
        address _wbtc,
        address _paxg,
        address _usdc
    ) external initializer {
        if (_admin == address(0)) revert InvalidAddress();
        if (_vco == address(0)) revert InvalidAddress();
        if (_vrt == address(0)) revert InvalidAddress();
        if (_swapRouter == address(0)) revert InvalidAddress();
        if (_npm == address(0)) revert InvalidAddress();
        if (_weth == address(0)) revert InvalidAddress();
        if (_wbtc == address(0)) revert InvalidAddress();
        if (_paxg == address(0)) revert InvalidAddress();
        if (_usdc == address(0)) revert InvalidAddress();

        vco = IValinityCapOfficer(_vco);
        vrt = IValinityReserveTreasury(_vrt);
        swapRouter = ISwapRouter(_swapRouter);
        npm = INonfungiblePositionManager(_npm);
        weth = IERC20(_weth);
        wbtc = IERC20(_wbtc);
        paxg = IERC20(_paxg);
        usdc = IERC20(_usdc);

        PAIR_WETH_WBTC = pairKeyOf(_weth, _wbtc);
        PAIR_PAXG_USDC = pairKeyOf(_paxg, _usdc);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(ADMIN_ROLE, DEFAULT_ADMIN_ROLE);

        deployRatioBps = DEFAULT_DEPLOY_RATIO_BPS;
        slippageBps = DEFAULT_SLIPPAGE_BPS;
    }

    /// @dev UUPS upgrade authorization. Only ADMIN_ROLE (multisig) can
    ///      upgrade the implementation behind the proxy.
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    /// @notice One-shot V2 migration: switches the deploy reference from
    ///         VSR-staked VY to circulating VY, lowers the default deploy
    ///         ratio to 85%, and seeds the keeper drift threshold to 1%.
    /// @dev Idempotent via reinitializer(2). Admin-only as defense-in-depth.
    function reinitializeV2() external onlyRole(ADMIN_ROLE) reinitializer(2) {
        deployRatioBps = DEFAULT_DEPLOY_RATIO_BPS;
        keeperThresholdBps = uint16(DEFAULT_KEEPER_THRESHOLD_BPS);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MAIN ENTRY (Option D: target-based atomic distribution)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Permissionless rebalance entry point.
    /// @dev Reads `vco.getTotalCirculatingVY()` and rebalances deployed
    ///      reserves toward `circulating × deployRatioBps`. To bound gas on
    ///      hot paths (VSR/VLO heartbeats), calls below `keeperThresholdBps`
    ///      drift from the last snapshot are silent no-ops. The first call
    ///      after upgrade always executes (snapshot starts at zero).
    function execute() external nonReentrant {
        if (pairFee[PAIR_WETH_WBTC] == 0 || pairFee[PAIR_PAXG_USDC] == 0) {
            revert PairsNotConfigured();
        }
        // Without VLM the deploy/recall path silently skips TWAP alignment
        // and runs on a stale snapshot — sandwich exposure. Hard-fail.
        if (address(vlm) == address(0)) revert InvalidParam();

        // Pause and drift-gate short-circuit the deploy/recall body, but the
        // snapback hook still fires so VLM re-centers on every permissionless
        // poke. Hook is gas-bounded + try/catch'd so it can never fail VRYO.
        bool runBody = true;
        if (paused) {
            emit ExecuteSkippedPaused();
            runBody = false;
        }

        uint256 circulatingVY = vco.getTotalCirculatingVY();
        if (runBody) {
            uint256 snap = lastCirculatingVY;
            // Drift gate: skip cheaply when neither VBBO/VFO nor mints/repays
            // have moved circulating supply enough since the last run. The
            // first call (snap == 0) always proceeds so V2 can seed the
            // snapshot and align deployments to the new circulating-based
            // target.
            if (snap != 0) {
                uint256 delta = snap > circulatingVY ? snap - circulatingVY : circulatingVY - snap;
                if (delta * BPS_DENOMINATOR < snap * keeperThresholdBps) {
                    emit ExecuteSkippedBelowThreshold(snap, circulatingVY);
                    runBody = false;
                }
            }
        }

        if (runBody) {
            uint256 target = (circulatingVY * deployRatioBps) / BPS_DENOMINATOR;
            uint256 totalDeployed = capVRYO_total;
            int256 netDelta = int256(target) - int256(totalDeployed);

            // Cache managed-asset addresses once; passed into hot-loop helpers
            // to avoid repeated SLOADs from IERC20 storage slots.
            address w = address(weth);
            address b = address(wbtc);
            address p = address(paxg);

            if (netDelta > 0) {
                _executeDeployLoop(uint256(netDelta), w, b, p);
            } else if (netDelta < 0) {
                _executeRecallLoop(uint256(-netDelta), w, b);
            }

            _settleAllToVRT(w, b, p);

            lastCirculatingVY = circulatingVY;
            emit Executed(circulatingVY, target, netDelta);
        }

        // Permissionless re-center hook on VLM. Fires on every execute() —
        // including paused / below-threshold skips — so VLM's cooldown owns
        // throttling, not VRYO's drift gate. Best-effort: VLM-side reverts
        // (cooldown not elapsed, VLM paused, no eligible pair, TWAP/slippage
        // guards) MUST NOT fail VRYO.execute(). Bound gas to keep the hot
        // path predictable.
        try vlm.snapbackHome{gas: 1_500_000}() returns (bytes32 sbPair, uint256 sbTokenId) {
            emit SnapbackInvoked(sbPair, sbTokenId);
        } catch (bytes memory reason) {
            emit SnapbackSkipped(reason);
        }
    }

    /// @dev Sweep all three managed tokens to VRT and assert the
    ///      zero-balance invariant in a single pass (replaces 3× separate
    ///      `_settleToVRT` + invariant checks). Converts any USDC residual
    ///      (counterparty dust from PAXG/USDC deploys) to PAXG first so
    ///      VRT never receives an unmanaged token.
    function _settleAllToVRT(address w, address b, address p) internal {
        // Convert any USDC dust left over from PAXG/USDC zap rounding before
        // sweeping managed reserves. This runs on every execute() so dust
        // accumulated across multiple deploy cycles is cleared each time.
        _swapAllUsdcToPaxg();
        uint256 bal;
        bal = IERC20(w).balanceOf(address(this));
        if (bal != 0) {
            IERC20(w).safeTransfer(address(vrt), bal);
            if (IERC20(w).balanceOf(address(this)) != 0) revert InvariantViolation(w);
        }
        bal = IERC20(b).balanceOf(address(this));
        if (bal != 0) {
            IERC20(b).safeTransfer(address(vrt), bal);
            if (IERC20(b).balanceOf(address(this)) != 0) revert InvariantViolation(b);
        }
        bal = IERC20(p).balanceOf(address(this));
        if (bal != 0) {
            IERC20(p).safeTransfer(address(vrt), bal);
            if (IERC20(p).balanceOf(address(this)) != 0) revert InvariantViolation(p);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DEPLOY (Option D)
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Multi-pass deploy. Each pass picks the managed asset with the
    ///      largest VCO headroom (above VCO's effective floor) and routes it to its
    ///      single configured pair (WETH/WBTC → PAIR_WETH_WBTC, PAXG →
    ///      PAIR_PAXG_USDC). Take = min(gap, srcHR, slice). Pair-level failures
    ///      mark the pair in a per-tx skip mask and the loop continues.
    /// @dev Cold-start / large-jump anti-concentration: if the gap is large
    ///      relative to system size (≥ 25% of the largest VCO cap), each pass
    ///      is bounded by `gap / 3`, so a single source can absorb at most a
    ///      third of the gap per pass. After 3 productive passes the loop
    ///      naturally closes. For small gaps the slice is unbounded and the
    ///      loop converges in 1 pass like steady state. The slice is computed
    ///      once at loop entry so the bound is deterministic across passes.
    function _executeDeployLoop(uint256 gap, address w, address b, address p) internal {
        // Read VCO caps once. We mutate `caps` locally as deploys consume
        // headroom so the picker can converge without re-querying VCO each
        // pass. `decreaseAssetCap` is also called on VCO so the on-chain
        // state stays in sync; the cache only avoids redundant reads.
        uint256[3] memory caps;
        caps[0] = vco.getAssetCap(w);
        caps[1] = vco.getAssetCap(b);
        caps[2] = vco.getAssetCap(p);

        // Self-scaling fair-share threshold: 25% of the largest managed VCO
        // cap. When the gap exceeds this, each pass is sliced to gap/3 so up
        // to three productive passes are required to close — preventing one
        // asset from absorbing a disproportionate share at cold start or on
        // large stake events. Below the threshold the loop runs unclamped.
        uint256 maxCap = caps[0];
        if (caps[1] > maxCap) maxCap = caps[1];
        if (caps[2] > maxCap) maxCap = caps[2];
        uint256 slice = type(uint256).max;
        if (maxCap > 0 && gap >= maxCap / 4) {
            slice = gap / 3;
        }

        uint256 floor_ = vco.effectiveFloor();
        // Cache pair-keys & usdc once — eliminates repeated SLOADs inside
        // _pickDeploySource across up to MAX_LOOP_PASSES iterations.
        bytes32 pkWW = PAIR_WETH_WBTC;
        bytes32 pkPU = PAIR_PAXG_USDC;
        address u = address(usdc);
        uint8 skipMask;
        for (uint256 pass; pass < MAX_LOOP_PASSES && gap > 0;) {
            (uint8 srcIdx, uint8 srcBit, address source, address counterparty, bytes32 pairKey, uint256 srcHR)
                = _pickDeploySource(caps, floor_, skipMask, w, b, p, u, pkWW, pkPU);
            if (source == address(0)) break;

            uint256 take = gap;
            if (take > srcHR) take = srcHR;
            if (take > slice) take = slice;
            if (take == 0) {
                skipMask |= srcBit;
                unchecked { ++pass; }
                continue;
            }

            uint256 deployed = _deployIntoPair(source, counterparty, pairKey, take);
            if (deployed == 0) {
                skipMask |= srcBit;
                unchecked { ++pass; }
                continue;
            }
            // Keep the local cache in sync with the on-chain cap mutation.
            caps[srcIdx] -= deployed;
            gap -= deployed;
            unchecked { ++pass; }
        }
        if (gap > 0) emit TargetClamped(gap, true);
    }

    /// @dev Picks the managed asset with the largest VCO headroom whose pair
    ///      isn't in `skipMask`, using a pre-read cap cache. WETH/WBTC both
    ///      route to PAIR_WETH_WBTC; PAXG routes to PAIR_PAXG_USDC.
    function _pickDeploySource(
        uint256[3] memory caps,
        uint256 floor_,
        uint8 skipMask,
        address w,
        address b,
        address p,
        address u,
        bytes32 pkWW,
        bytes32 pkPU
    )
        internal pure
        returns (uint8 srcIdx, uint8 srcBit, address source, address counterparty, bytes32 pairKey, uint256 srcHR)
    {
        // pair fees are validated non-zero by the execute() preamble, so
        // we don't re-check pairFee[pk] here.
        bool wwBlocked = (skipMask & BIT_WW) != 0;
        bool puBlocked = (skipMask & BIT_PU) != 0;

        // candidate 0: WETH (→ WETH/WBTC, counterparty WBTC)
        if (!wwBlocked) {
            uint256 hr = caps[0] > floor_ ? caps[0] - floor_ : 0;
            if (hr > srcHR) {
                srcHR = hr; source = w; counterparty = b; pairKey = pkWW; srcIdx = 0; srcBit = BIT_WW;
            }
        }
        // candidate 1: WBTC (→ WETH/WBTC, counterparty WETH)
        if (!wwBlocked) {
            uint256 hr = caps[1] > floor_ ? caps[1] - floor_ : 0;
            if (hr > srcHR) {
                srcHR = hr; source = b; counterparty = w; pairKey = pkWW; srcIdx = 1; srcBit = BIT_WW;
            }
        }
        // candidate 2: PAXG (→ PAXG/USDC, counterparty USDC)
        if (!puBlocked) {
            uint256 hr = caps[2] > floor_ ? caps[2] - floor_ : 0;
            if (hr > srcHR) {
                srcHR = hr; source = p; counterparty = u; pairKey = pkPU; srcIdx = 2; srcBit = BIT_PU;
            }
        }
    }

    function _vcoHeadroom(address asset) internal view returns (uint256) {
        uint256 cap = vco.getAssetCap(asset);
        uint256 floor_ = vco.effectiveFloor();
        return cap > floor_ ? cap - floor_ : 0;
    }

    /// @dev Single deploy step: source's VCO cap -= takeVY, pull source asset
    ///      from VRT (amount = takeVY × vco.getLTV(source)), zap into pair,
    ///      mint LP. On any sub-failure (VLM revert, snap missing, zap=0)
    ///      returns 0 without mutating state.
    function _deployIntoPair(address source, address counterparty, bytes32 pairKey, uint256 takeVY)
        internal returns (uint256 deployed)
    {
        if (takeVY == 0) return 0;

        // execute() reverts if vlm == 0, so this path is only reachable
        // with a configured VLM — no need to re-check here.
        try vlm.refreshSnapshot{gas: 500_000}(pairKey) {} catch { return 0; }
        try vlm.assertTwapAligned{gas: 100_000}(pairKey) {} catch { return 0; }

        PositionSnapshot memory snap = vrt.getPositionSnapshot(pairKey);
        if (snap.tokenId == 0 || snap.poolAddress == address(0)) return 0;

        // Convert VY → source asset amount via VCO's live LTV.
        // vco.getLTV returns reserve(18-dec) / cap × WAD = asset_per_VY × WAD.
        // We need source asset native-decimal amount.
        uint256 ltv = vco.getLTV(source);
        if (ltv == 0) return 0;
        uint256 pullAmount18 = Math.mulDiv(takeVY, ltv, WAD);
        uint256 pullAmount = _scaleFromWad(pullAmount18, source);
        if (pullAmount == 0) return 0;

        // Reserve the cap shift up-front (source only).
        vco.decreaseAssetCap(source, takeVY);

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = source;
        amounts[0] = pullAmount;
        vrt.deployForYield(assets, amounts, address(this));

        uint128 liquidityMinted = _zapIntoV3(snap, source, counterparty);

        if (liquidityMinted == 0) {
            // Roll back the cap shift; tokens settled back to VRT in execute().
            vco.increaseAssetCap(source, takeVY);
            emit Deployed(source, 0, pairKey, pullAmount, 0);
            return 0;
        }

        capVRYO_total += takeVY;
        pairPrincipal[pairKey] += takeVY;

        emit Deployed(source, takeVY, pairKey, pullAmount, liquidityMinted);
        return takeVY;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RECALL (Option D)
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Multi-pass recall. Each pass picks the pair with the LARGEST VY
    ///      ledger (`pairPrincipal`); within that pair the recall asset is
    ///      the managed token that most needs cap restoration:
    ///        - PAXG/USDC → PAXG (sole managed asset on this pair).
    ///        - WETH/WBTC → whichever of WETH/WBTC has the lower VCO cap;
    ///                       tie → WETH; if exactly one is zero → that one.
    ///      Take = min(gap, ledgerVY). Pair-level failures mark the pair
    ///      in a per-tx skip mask and the loop continues.
    function _executeRecallLoop(uint256 gap, address w, address b) internal {
        // Pre-read WETH/WBTC caps once (PAXG recall doesn't need them).
        // Updated locally after each successful recall to mirror VCO state.
        uint256 capW = vco.getAssetCap(w);
        uint256 capB = vco.getAssetCap(b);

        uint8 skipMask;
        for (uint256 pass; pass < MAX_LOOP_PASSES && gap > 0;) {
            (uint8 srcBit, address recallAsset, bytes32 pairKey, uint256 prin)
                = _pickRecallAsset(capW, capB, skipMask, w, b);
            if (prin == 0) break;

            uint256 take = gap;
            if (take > prin) take = prin;
            if (take == 0) {
                skipMask |= srcBit;
                unchecked { ++pass; }
                continue;
            }

            uint256 reduced = _recallFromPair(pairKey, recallAsset, take, prin);
            if (reduced == 0) {
                skipMask |= srcBit;
                unchecked { ++pass; }
                continue;
            }
            // Mirror the on-chain cap restore in the local cache.
            if (recallAsset == w) capW += reduced;
            else if (recallAsset == b) capB += reduced;
            gap -= reduced;
            unchecked { ++pass; }
        }
        if (gap > 0) emit TargetClamped(gap, false);
    }

    /// @dev Picks (recallAsset, pairKey, ledgerVY) using:
    ///      1. Pair = whichever of (WETH/WBTC, PAXG/USDC) has the larger
    ///         non-skipped `pairPrincipal`.
    ///      2. Recall asset:
    ///         - PAXG/USDC pair → PAXG.
    ///         - WETH/WBTC pair → the side with lower VCO cap. Tie → WETH.
    ///                              Exactly one side at zero → that side.
    function _pickRecallAsset(uint256 capW, uint256 capB, uint8 skipMask, address w, address b)
        internal view
        returns (uint8 srcBit, address recallAsset, bytes32 pairKey, uint256 prin)
    {
        uint256 pWW = ((skipMask & BIT_WW) == 0) ? pairPrincipal[PAIR_WETH_WBTC] : 0;
        uint256 pPU = ((skipMask & BIT_PU) == 0) ? pairPrincipal[PAIR_PAXG_USDC] : 0;
        if (pWW == 0 && pPU == 0) return (0, address(0), bytes32(0), 0);

        if (pWW >= pPU) {
            srcBit = BIT_WW;
            pairKey = PAIR_WETH_WBTC;
            prin = pWW;
            recallAsset = _pickWWRecall(capW, capB, w, b);
        } else {
            srcBit = BIT_PU;
            pairKey = PAIR_PAXG_USDC;
            prin = pPU;
            recallAsset = address(paxg);
        }
    }

    /// @dev WETH/WBTC recall-asset tie-break: side with the lower VCO cap
    ///      (most-depleted). Tie → WETH. Exactly one cap at 0 → that side.
    ///      Single source of truth, used by both the recall loop and rescue.
    function _pickWWRecall(uint256 capW, uint256 capB, address w, address b)
        internal pure
        returns (address)
    {
        if (capW == 0 && capB != 0) return w;
        if (capB == 0 && capW != 0) return b;
        return capW <= capB ? w : b;
    }

    /// @dev Single recall step: burn `takeVY / pairPrincipal` fraction of LP,
    ///      reverse-zap counterparty side back into recall asset, return all
    ///      to VRT. Cap accounting: recall asset's VCO cap += takeVY (VY units,
    ///      not physical tokens). Yield = excess physical tokens beyond
    ///      `takeVY × LTV` lands in VRT free balance.
    function _recallFromPair(bytes32 pairKey, address recallAsset, uint256 takeVY, uint256 prin)
        internal returns (uint256 reduced)
    {
        // execute() reverts if vlm == 0, so this path is only reachable
        // with a configured VLM — no need to re-check here.
        try vlm.refreshSnapshot{gas: 500_000}(pairKey) {} catch { return 0; }
        try vlm.assertTwapAligned{gas: 100_000}(pairKey) {} catch { return 0; }

        PositionSnapshot memory snap = vrt.getPositionSnapshot(pairKey);
        if (snap.tokenId == 0 || snap.liquidity == 0) return 0;
        if (snap.poolAddress == address(0)) return 0;

        // Caller (the recall loop) read `prin` from `pairPrincipal[pairKey]`
        // immediately before this call; passing it through avoids a redundant
        // SLOAD. `takeVY <= prin` is guaranteed by the loop's clamp.
        if (prin == 0 || takeVY > prin) return 0;

        // Proportional unwind: liquidity fraction = takeVY / pairPrincipal.
        uint128 liqToBurn = uint128(Math.mulDiv(uint256(snap.liquidity), takeVY, prin));
        if (liqToBurn == 0) return 0;

        (uint256 out0, uint256 out1) = vrt.decreasePositionLiquidity(
            pairKey, liqToBurn, 0, 0, block.timestamp + DEADLINE_BUFFER
        );

        // Reverse-zap: swap the non-recall side into recall asset.
        // Use the full counterparty balance (not just this burn's `cpartyOut`) so
        // any USDC dust accumulated from prior deploy cycles is also swept in the
        // same swap — prevents indefinite dust build-up on VRYO.
        address counterparty = (recallAsset == snap.token0) ? snap.token1 : snap.token0;
        uint256 cpartySwap = IERC20(counterparty).balanceOf(address(this));
        if (cpartySwap > 0) {
            uint256 minOut = _computeReverseZapMinOut(snap, counterparty, cpartySwap);
            IERC20(counterparty).forceApprove(address(swapRouter), cpartySwap);
            swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: counterparty,
                    tokenOut: recallAsset,
                    fee: snap.fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: cpartySwap,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // Update accounting (VY units, not tokens). Yield = excess physical
        // tokens beyond the deploy-time `takeVY × LTV` lands in VRT free
        // balance and grows the system's LTV (intrinsic VY value).
        pairPrincipal[pairKey] = prin - takeVY;
        capVRYO_total -= takeVY;
        // VCO cap restore by VY units (symmetric with deploy).
        vco.increaseAssetCap(recallAsset, takeVY);

        emit Recalled(recallAsset, takeVY, pairKey, liqToBurn, out0, out1);
        return takeVY;
    }

    function _computeReverseZapMinOut(
        PositionSnapshot memory snap,
        address tokenIn,
        uint256 amountIn
    ) internal view returns (uint256) {
        (uint160 liveSqrtP, , , , , , ) = IUniswapV3Pool(snap.poolAddress).slot0();
        bool tokenInIsToken0 = (tokenIn == snap.token0);
        return V3ZapMath.computeMinOut(amountIn, tokenInIsToken0, liveSqrtP, snap.fee, uint16(slippageBps));
    }

    /// @dev Convert a 18-decimal amount to the asset's native decimals.
    function _scaleFromWad(uint256 amount18, address asset) internal view returns (uint256) {
        uint8 d = _assetDecimals(asset);
        if (d == 18) return amount18;
        return amount18 / (10 ** (18 - d)); // d always < 18 here (only WBTC = 8)
    }

    function _assetDecimals(address asset) internal view returns (uint8) {
        // Managed asset set is fixed (WETH, WBTC, PAXG). Any other address
        // is a programmer error — revert rather than guess decimals.
        if (asset == address(weth)) return 18;
        if (asset == address(paxg)) return 18;
        if (asset == address(wbtc)) return 8;
        revert InvalidAsset();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PAIR HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev L1 opt: each asset has exactly one valid pair under the new
    ///      routing (WETH and WBTC share WETH/WBTC; PAXG uses PAXG/USDC).
    ///      Returns 0 for any other token combination.
    function _pairKeyFor(address x, address y) internal view returns (bytes32) {
        address w = address(weth);
        address b = address(wbtc);
        address p = address(paxg);
        address u = address(usdc);
        if ((x == w && y == b) || (x == b && y == w)) return PAIR_WETH_WBTC;
        if ((x == p && y == u) || (x == u && y == p)) return PAIR_PAXG_USDC;
        return bytes32(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // V3 ZAP
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Single-sided zap into VRT's V3 NFT.
     *         H2: uses live `slot0().sqrtPriceX96` for split math.
     *         C2: slippage-protected swap and increaseLiquidity.
     *         H3: bail only if *both* sides end up zero.
     */
    function _zapIntoV3(PositionSnapshot memory snap, address tokenIn, address tokenOther)
        internal returns (uint128 liquidityMinted)
    {
        uint256 amountIn = IERC20(tokenIn).balanceOf(address(this));
        if (amountIn == 0) return 0;

        (uint160 liveSqrtP, , , , , , ) = IUniswapV3Pool(snap.poolAddress).slot0();

        bool tokenInIsToken0 = (tokenIn == snap.token0);
        uint256 swapAmt = V3ZapMath.computeSwapAmount(
            amountIn, tokenInIsToken0,
            liveSqrtP, snap.sqrtRatioLowerX96, snap.sqrtRatioUpperX96
        );

        if (swapAmt > 0) {
            // M1: use snap.fee — VRT has already validated this against the
            // Uniswap factory (factory.getPool(token0, token1, snap.fee) == snap.poolAddress),
            // so price-derivation pool (snap.poolAddress) and swap-execution pool match.
            uint24 fee = snap.fee;
            uint256 minOut = V3ZapMath.computeMinOut(swapAmt, tokenInIsToken0, liveSqrtP, fee, uint16(slippageBps));
            IERC20(tokenIn).forceApprove(address(swapRouter), swapAmt);
            swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOther,
                    fee: fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: swapAmt,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        uint256 bal0 = IERC20(snap.token0).balanceOf(address(this));
        uint256 bal1 = IERC20(snap.token1).balanceOf(address(this));
        // H3: position may be single-sided (price out of range) — one zero balance is fine.
        if (bal0 == 0 && bal1 == 0) return 0;

        if (bal0 > 0) IERC20(snap.token0).forceApprove(address(npm), bal0);
        if (bal1 > 0) IERC20(snap.token1).forceApprove(address(npm), bal1);

        // amount*Min = 0 is safe here. `increaseLiquidity` only uses up to the current-price
        // ratio of (desired0, desired1), returning unused tokens — which `_settleAllToVRT` sweeps.
        // Setting tight mins based on desired amounts causes false reverts on pool drift without
        // adding value protection (the swap's `amountOutMinimum` already bounds loss).
        (liquidityMinted, , ) = npm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: snap.tokenId,
                amount0Desired: bal0,
                amount1Desired: bal1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    /**
     * @notice Closed-form V3 zap split + min-out helpers live in
     *         `V3ZapMath` (shared with VLM). Local copies were removed to
     *         keep this contract under the 24576-byte deploy limit.
     */

    // ═══════════════════════════════════════════════════════════════════════
    // VIEWS / HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev One-shot reverse-zap used by `rescueTokens()` to convert any
    ///      USDC residual (from the PAXG/USDC burn) into PAXG before the
    ///      final settle. USDC is the counterparty token for the PAXG pair
    ///      and is NOT a managed reserve, so it must never reach VRT.
    function _swapAllUsdcToPaxg() internal {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal == 0) return;

        PositionSnapshot memory snap = vrt.getPositionSnapshot(PAIR_PAXG_USDC);
        if (snap.poolAddress == address(0)) return; // pair never registered

        usdc.forceApprove(address(swapRouter), bal);
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           address(usdc),
                tokenOut:          address(paxg),
                fee:               snap.fee,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          bal,
                amountOutMinimum:  _computeReverseZapMinOut(snap, address(usdc), bal),
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════

    function setDeployRatio(uint256 bps) external onlyRole(ADMIN_ROLE) {
        if (bps > MAX_DEPLOY_RATIO_BPS) revert InvalidParam();
        deployRatioBps = bps;
        emit DeployRatioUpdated(bps);
    }

    function setSlippage(uint256 bps) external onlyRole(ADMIN_ROLE) {
        if (bps > MAX_SLIPPAGE_BPS) revert InvalidParam();
        slippageBps = bps;
        emit SlippageUpdated(bps);
    }

    /// @notice Registers the VLM used to refresh position snapshots before
    ///         deploy/recall math. Must be set before the first `execute()`.
    function setVlm(address newVlm) external onlyRole(ADMIN_ROLE) {
        if (newVlm == address(0)) revert InvalidAddress();
        vlm = IValinityLiquidityManager(newVlm);
        emit VlmUpdated(newVlm);
    }

    /// @notice Set the keeper drift threshold (bps of `lastCirculatingVY`).
    /// @dev Calls to `execute()` with smaller drift silently no-op. Lower
    ///      values rebalance more eagerly (more gas on hot paths); higher
    ///      values let circulating drift further before a rebalance fires.
    function setKeeperThreshold(uint16 bps) external onlyRole(ADMIN_ROLE) {
        if (bps == 0 || bps > MAX_KEEPER_THRESHOLD_BPS) revert InvalidParam();
        keeperThresholdBps = bps;
        emit KeeperThresholdUpdated(bps);
    }

    /**
     * @notice Set or update a V3 fee tier for a managed pair.
     * @dev Any fee change (including disable) is blocked while the pair has
     *      live deployments — the pool address is derived from `(tokenA, tokenB,
     *      fee)` so changing fee mid-flight would orphan the active position.
     *      Admin must recall via execute() (or `rescueTokens()`) first.
     */
    function setPairFee(address tokenA, address tokenB, uint24 fee) external onlyRole(ADMIN_ROLE) {
        if (tokenA == tokenB) revert InvalidAsset();
        if (fee != 0 && fee != 100 && fee != 500 && fee != 3000 && fee != 10_000) revert InvalidFee();
        // Validate via the pair-key resolver: the only valid combinations
        // are (WETH,WBTC) and (PAXG,USDC); anything else returns 0.
        bytes32 k = _pairKeyFor(tokenA, tokenB);
        if (k == bytes32(0)) revert InvalidAsset();
        if (pairPrincipal[k] != 0) revert PairHasLiveDeployments();
        pairFee[k] = fee;
        emit PairFeeUpdated(k, fee);
    }

    function setPaused(bool p) external onlyRole(ADMIN_ROLE) {
        paused = p;
        emit PausedUpdated(p);
    }

    /// @notice One-shot admin sweep of any USDC dust sitting on VRYO.
    /// @dev    Converts accumulated USDC → PAXG via the PAXG/USDC pool, then
    ///         transfers all managed balances (WETH/WBTC/PAXG) to VRT. Safe to
    ///         call at any time without affecting positions or VCO caps. Useful
    ///         for clearing dust that pre-dates Option A/B fixes, or if dust
    ///         ever accumulates during a period when execute() is paused.
    function sweepUsdcDust() external onlyRole(ADMIN_ROLE) nonReentrant {
        _settleAllToVRT(address(weth), address(wbtc), address(paxg));
    }

    /// @notice EMERGENCY RESET — unwinds every managed V3 position and
    ///         restores VCO caps to their pre-VRYO state.
    /// @dev
    ///  - Works even when `paused`; this is the escape hatch.
    ///  - For each managed pair with liquidity > 0: calls
    ///    `vrt.decreasePositionLiquidity(pairKey, liquidity, 0, 0)`. Principal
    ///    and fees flow directly to VRT; the NFT shell remains registered
    ///    with liquidity = 0 so VRYO can redeploy into it later without
    ///    needing a fresh VLM mint.
    ///  - Restores VCO caps by the full pair-ledger VY amount on each
    ///    pair, picking the recall asset by the same rules as a normal
    ///    recall (PAXG for PAXG/USDC; lower-cap side for WETH/WBTC).
    ///    Admin can rebalance with `vco.setAssetCap` afterward if desired.
    ///  - Final sweep of WETH/WBTC/PAXG defense-in-depth; `execute()`
    ///    already maintains the zero-balance invariant on happy paths.
    function rescueTokens() external onlyRole(ADMIN_ROLE) nonReentrant {
        // 1. Burn all liquidity on every managed pair.
        _rescuePair(PAIR_WETH_WBTC);
        _rescuePair(PAIR_PAXG_USDC);

        address w = address(weth);
        address b = address(wbtc);
        address p = address(paxg);

        // 2. Restore VCO caps from per-pair ledgers, then zero them.
        uint256 pWW = pairPrincipal[PAIR_WETH_WBTC];
        if (pWW != 0) {
            pairPrincipal[PAIR_WETH_WBTC] = 0;
            vco.increaseAssetCap(_pickWWRecall(vco.getAssetCap(w), vco.getAssetCap(b), w, b), pWW);
        }
        uint256 pPU = pairPrincipal[PAIR_PAXG_USDC];
        if (pPU != 0) {
            pairPrincipal[PAIR_PAXG_USDC] = 0;
            vco.increaseAssetCap(p, pPU);
        }
        capVRYO_total = 0;

        // 3. Convert any USDC proceeds (from the PAXG/USDC burn) back to PAXG
        //    and sweep all managed balances back to VRT. _settleAllToVRT calls
        //    _swapAllUsdcToPaxg() as its first action so USDC never reaches VRT.
        _settleAllToVRT(w, b, p);

        emit SystemReset(msg.sender);
    }

    function _rescuePair(bytes32 pairKey) internal {
        PositionSnapshot memory snap = vrt.getPositionSnapshot(pairKey);
        if (snap.tokenId == 0 || snap.liquidity == 0) return;
        // Pass (0, 0) mins: burning liquidity returns proportionate value at
        // current price; slippage guards only create false reverts.
        vrt.decreasePositionLiquidity(pairKey, snap.liquidity, 0, 0, block.timestamp + DEADLINE_BUFFER);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EXTERNAL VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function getCirculatingVY() external view returns (uint256) { return vco.getTotalCirculatingVY(); }
    function getCapVRYOTotal() external view returns (uint256) { return capVRYO_total; }
    function getPairPrincipal(bytes32 pairKey) external view returns (uint256) { return pairPrincipal[pairKey]; }
    function getVcoHeadroom(address asset) external view returns (uint256) { return _vcoHeadroom(asset); }

    function getPairKey(address tokenA, address tokenB) external pure returns (bytes32) {
        return pairKeyOf(tokenA, tokenB);
    }

    /// @dev Reserved storage to allow future versions to add new state
    ///      variables without shifting existing slots. Decrement on each
    ///      append. See OZ upgradeable docs §"Storage Gaps".
    uint256[38] private __gap;
}
