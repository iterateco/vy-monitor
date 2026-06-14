// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// pairKeyOf retained only to seed the deprecated public PAIR_* keys in the
// first-deploy initializer (already run on the live proxy).
import { pairKeyOf } from "../interfaces/IValinityPositions.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Empty stubs preserved ONLY so the deprecated storage variables (swapRouter,
// npm, vlm) keep their exact declared types and the UUPS storage layout is
// byte-for-byte compatible with the deployed V3 implementation. Nothing on
// these interfaces is called any more.
// ─────────────────────────────────────────────────────────────────────────────
interface ISwapRouter {}
interface INonfungiblePositionManager {}
interface IValinityLiquidityManager {}

interface IValinityCapOfficer {
    function getAssetCap(address asset) external view returns (uint256);
    function effectiveFloor() external view returns (uint256);
    function increaseAssetCap(address asset, uint256 amount) external;
    function decreaseAssetCap(address asset, uint256 amount) external;
    function getLTV(address asset) external view returns (uint256);
    function getTotalCirculatingVY() external view returns (uint256);
}

/// @dev VRYO-local view of the VRT surface. After the DAX migration VRYO only
///      needs the asset-pull primitive; all V3 custody/recall methods are gone.
interface IValinityReserveTreasury {
    function deployForYield(
        address[] calldata assets,
        uint256[] calldata amounts,
        address recipient
    ) external;
}

/// @dev VRYO-local view of the ValinityDAX reserve surface. `reserveInject`/
///      `reserveExtract` are single-sided, no-swap, no-VDAX-mint primitives
///      gated to RESERVE_OFFICER_ROLE: VRYO injects pure asset and recalls the
///      exact asset back — no forced VY sale, no impermanent loss. The public
///      `assetToPoolId`/`hasPool` getters resolve the pool index for an asset
///      (poolId is stable per asset; the mapping survives admin pool compaction).
interface IValinityDAX {
    function assetToPoolId(address asset) external view returns (uint256);
    function hasPool(address asset) external view returns (bool);
    function getPoolReserves(uint256 poolId)
        external view returns (address asset, uint256 reserveVY, uint256 reserveAsset);
    function reserveInjectAsset(uint256 poolId, uint256 assetAmount) external;
    function reserveExtractAsset(uint256 poolId, uint256 assetAmount, address recipient)
        external returns (uint256 assetOut);
}

/**
 * @title ValinityReserveYieldOfficer (VRYO) — ValinityDAX edition
 * @notice Deploys a per-asset fraction of VRT's reserves into the private
 *         ValinityDAX VY/asset pools as one-sided, protocol-owned asset depth,
 *         and recalls it as loans/repays move each asset's cap.
 *
 * Model (per managed asset A ∈ {WETH, WBTC, PAXG}):
 *  - globalCap(A)   = vco.getAssetCap(A) + capVRYO[A]     (conserved across rebalances)
 *  - target deploy  = globalCap(A) × assetDeployRatioBps[A] / 10000
 *  - DEPLOY  moves Δ cap-units VCO→VRYO, pulls `Δ × vco.getLTV(A)` asset out of
 *            VRT and injects it into DAX. Pulling asset + lowering cap by the
 *            SAME LTV leaves vco.getLTV(A) invariant (deploy is LTV-neutral).
 *  - RECALL  moves Δ cap-units VRYO→VCO and extracts `Δ × deployedAsset[A]/capVRYO[A]`
 *            (the STALE blended internal LTV) back to VRT. Because the internal
 *            LTV is frozen-blended while VCO's LTV drifts, recall nudges VCO's
 *            LTV — intended.
 *
 * Yield is NOT captured here: VOE's swap fee routes to VBBO; the deployed asset
 * balance never grows, so the (deployedAsset, capVRYO) ledger stays exact.
 *
 * Rebalance is permissionless (`execute()`) and band-gated: an asset only moves
 * when its deployed share drifts ≥ `keeperThresholdBps` off target.
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
    uint256 public constant MAX_DEPLOY_RATIO_BPS = 9500;       // ≤95% so vcoCap stays > 0
    uint256 public constant DEFAULT_DEPLOY_RATIO_BPS = 8500;
    uint256 public constant DEFAULT_KEEPER_THRESHOLD_BPS = 100; // ±1 percentage-point band
    uint256 public constant MAX_KEEPER_THRESHOLD_BPS = 2000;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50;

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE — layout is UUPS-compatible with the deployed V3 implementation.
    // Every variable below the constants keeps its exact slot. V3/VLM-era
    // fields are retained (marked deprecated) purely to pin the layout; the
    // DAX-edition state is appended at the end out of the former __gap.
    // ═══════════════════════════════════════════════════════════════════════

    // ── reserve refs (slots preserved) ──────────────────────────────────────
    IValinityCapOfficer public vco;
    IValinityReserveTreasury public vrt;
    /// @dev DEPRECATED (V3). Unused; kept for storage layout.
    ISwapRouter public swapRouter;
    /// @dev DEPRECATED (V3). Unused; kept for storage layout.
    INonfungiblePositionManager public npm;
    IERC20 public weth;
    IERC20 public wbtc;
    IERC20 public paxg;
    /// @dev DEPRECATED. USDC was the V3 PAXG counterparty; the DAX edition
    ///      deploys PAXG one-sided into the VY/PAXG pool. Slot kept.
    IERC20 public usdc;

    /// @dev DEPRECATED (V3 pair keys). Kept for storage layout.
    bytes32 public PAIR_WETH_WBTC;
    bytes32 public PAIR_PAXG_USDC;

    // ── configurable (slots preserved) ──────────────────────────────────────
    /// @custom:oz-renamed-from stakingRouter
    address public __deprecated_stakingRouter;
    /// @dev DEPRECATED. VLM closed out at the DAX migration. Slot kept.
    IValinityLiquidityManager public vlm;
    /// @custom:oz-renamed-from uniVyUsdcPair
    address public __deprecated_uniVyUsdcPair;
    /// @custom:oz-renamed-from vyIsToken0
    bool public __deprecated_vyIsToken0;
    /// @custom:oz-renamed-from dax
    address public __deprecated_dax;
    /// @custom:oz-renamed-from vdaxToken
    address public __deprecated_vdaxToken;

    /// @dev DEPRECATED (V3 per-pair fee tiers). Kept for storage layout.
    mapping(bytes32 pairKey => uint24 feeTier) public pairFee;

    /// @dev DEPRECATED. Global deploy ratio replaced by per-asset
    ///      `assetDeployRatioBps`. Slot kept.
    uint256 public deployRatioBps;
    /// @dev DEPRECATED dead slot.
    uint256 public capFloor;
    /// @dev DEPRECATED (V3 zap slippage). DAX reserve ops are swapless. Slot kept.
    uint256 public slippageBps;
    bool public paused;

    /// @dev DEPRECATED (V3 global ledger). The DAX edition tracks per-asset
    ///      `capVRYO`. Slot kept; reads as 0 after the pre-upgrade rescue.
    uint256 public capVRYO_total;
    /// @dev DEPRECATED (V3 per-pair ledger). Slot kept.
    mapping(bytes32 pairKey => uint256 vyUnits) public pairPrincipal;

    /// @dev DEPRECATED (V2 circulating snapshot). The band gate is per-asset
    ///      and stateless now. Slot kept.
    uint256 public lastCirculatingVY;
    /// @notice Rebalance band, in bps of an asset's global cap. An asset is
    ///         only rebalanced when its deployed share drifts at least this far
    ///         from target (e.g. 100 = trigger at 15%→14%/16%).
    uint16 public keeperThresholdBps;

    // ── DAX-edition appended storage (carved from the former __gap) ──────────
    /// @notice Per-asset deploy ratio in bps of that asset's global cap
    ///         (vco cap + capVRYO). Admin-ramped (e.g. 2000 → 5000 → 8500).
    ///         0 = deploy nothing / fully recall. A leading mapping here also
    ///         keeps `dax` off the deprecated keeperThresholdBps slot.
    mapping(address asset => uint16 ratioBps) public assetDeployRatioBps;
    /// @notice The private ValinityDAX this officer deploys into.
    IValinityDAX public dax;
    /// @notice Per-asset VY cap-units VRYO currently holds (moved out of VCO).
    mapping(address asset => uint256 vyUnits) public capVRYO;
    /// @notice Per-asset physical token amount (native decimals) credited to
    ///         the DAX pool by VRYO. Numerator of the blended internal LTV
    ///         (deployedAsset / capVRYO) used by recall.
    mapping(address asset => uint256 nativeAmount) public deployedAsset;

    // ── events ─────────────────────────────────────────────────────────────
    event Executed(address indexed caller);
    event ExecuteSkippedPaused();
    event AssetSkippedBelowBand(address indexed asset, uint256 globalCap, uint256 currentVryoCap, uint256 target);
    event Deployed(address indexed asset, uint256 deployVY, uint256 indexed poolId, uint256 assetInjected);
    event Recalled(address indexed asset, uint256 retireVY, uint256 indexed poolId, uint256 assetExtracted);
    event RecallSkipped(address indexed asset, uint256 indexed poolId);
    event DeploySkipped(address indexed asset, uint256 indexed poolId);
    event TargetClamped(address indexed asset, uint256 residualVY, bool isDeploy);
    event AssetDeployRatioUpdated(address indexed asset, uint16 bps);
    event DaxUpdated(address indexed newDax);
    event KeeperThresholdUpdated(uint16 newBps);
    event PausedUpdated(bool paused);
    event SystemReset(address indexed caller);

    // ── errors ─────────────────────────────────────────────────────────────
    error NotConfigured();
    error InvalidAddress();
    error InvalidParam();
    error InvalidAsset();
    error InvariantViolation(address token);
    error OnlySelf();

    // ── constructor / initializer ──────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice First-deploy initializer (unchanged signature). For the live
    ///         proxy this has already run; the DAX migration uses
    ///         `reinitializeV3`. `_swapRouter`/`_npm`/`_usdc` are retained as
    ///         arguments for layout/ABI continuity but are no longer used by
    ///         any code path.
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
        if (_weth == address(0)) revert InvalidAddress();
        if (_wbtc == address(0)) revert InvalidAddress();
        if (_paxg == address(0)) revert InvalidAddress();

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

    /// @dev Only ADMIN_ROLE (multisig) can upgrade the implementation.
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    /// @notice Legacy V2 migration (kept for replay-safety on the live proxy).
    function reinitializeV2() external onlyRole(ADMIN_ROLE) reinitializer(2) {
        deployRatioBps = DEFAULT_DEPLOY_RATIO_BPS;
        keeperThresholdBps = uint16(DEFAULT_KEEPER_THRESHOLD_BPS);
    }

    /// @notice DAX migration. PRECONDITION: the previous (V3) implementation's
    ///         `rescueTokens()` has already unwound all Uniswap V3 positions and
    ///         restored VCO caps, so `capVRYO`/`deployedAsset` start at zero.
    /// @param _dax           ValinityDAX proxy (VRYO must hold RESERVE_OFFICER_ROLE on it).
    /// @param initRatioBps   Starting per-asset deploy ratio for the managed
    ///                       set (e.g. 2000 for a measured 20% first step).
    function reinitializeV3(address _dax, uint16 initRatioBps)
        external
        onlyRole(ADMIN_ROLE)
        reinitializer(3)
    {
        if (_dax == address(0)) revert InvalidAddress();
        if (initRatioBps > MAX_DEPLOY_RATIO_BPS) revert InvalidParam();
        dax = IValinityDAX(_dax);
        if (keeperThresholdBps == 0) keeperThresholdBps = uint16(DEFAULT_KEEPER_THRESHOLD_BPS);
        assetDeployRatioBps[address(weth)] = initRatioBps;
        assetDeployRatioBps[address(wbtc)] = initRatioBps;
        assetDeployRatioBps[address(paxg)] = initRatioBps;
        emit DaxUpdated(_dax);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MAIN ENTRY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Permissionless rebalance. For each managed asset, drives the
    ///         deployed VY-cap share toward `assetDeployRatioBps[asset]` of its
    ///         global cap. Band-gated per asset so hot-path pokes that don't
    ///         move the share past `keeperThresholdBps` are cheap no-ops.
    function execute() external nonReentrant {
        if (address(dax) == address(0)) revert NotConfigured();
        if (paused) {
            emit ExecuteSkippedPaused();
            return;
        }
        _rebalanceAsset(address(weth));
        _rebalanceAsset(address(wbtc));
        _rebalanceAsset(address(paxg));
        emit Executed(msg.sender);
    }

    /// @dev Single-asset rebalance toward its per-asset target share.
    function _rebalanceAsset(address asset) internal {
        uint16 ratio = assetDeployRatioBps[asset];
        uint256 vcoCap = vco.getAssetCap(asset);
        uint256 cVY = capVRYO[asset];
        uint256 globalCap = vcoCap + cVY;
        if (globalCap == 0) return;

        uint256 target = (globalCap * ratio) / BPS_DENOMINATOR;
        // Subtractions are ternary-guarded; the band-gate products cannot
        // overflow (globalCap ≤ VY supply, keeperThresholdBps ≤ 2000).
        uint256 delta;
        bool belowBand;
        unchecked {
            delta = target > cVY ? target - cVY : cVY - target;
            // Band gate: |targetShare − currentShare| = delta / globalCap. Skip
            // unless that drift is at least keeperThresholdBps (e.g. 1 point).
            belowBand = delta == 0 || delta * BPS_DENOMINATOR < globalCap * keeperThresholdBps;
        }
        if (belowBand) {
            emit AssetSkippedBelowBand(asset, globalCap, cVY, target);
            return;
        }

        if (!dax.hasPool(asset)) return;
        uint256 poolId = dax.assetToPoolId(asset);

        if (target > cVY) {
            // Fault-isolated via self external call: any sub-failure rolls back
            // this asset's effects atomically and the next asset still runs.
            try this.deployStep(asset, delta, vcoCap, poolId) {} catch {
                emit DeploySkipped(asset, poolId);
            }
        } else {
            _recall(asset, delta, poolId);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DEPLOY
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Move `deployVY` cap-units VCO→VRYO and inject the matching asset
    ///      into DAX. EXTERNAL + self-only so `_rebalanceAsset` invokes it under
    ///      try/catch: any sub-failure (RESERVE_OFFICER_ROLE/VRYO_ROLE revoked,
    ///      DAX or VRT revert) rolls back this asset's effects atomically and
    ///      execute() continues to the next asset instead of bricking. Clamped
    ///      so VCO's cap never breaches its effective floor (decreaseAssetCap
    ///      reverts below floor). LTV-neutral: asset pulled = deployVY ×
    ///      vco.getLTV(asset), cap lowered by deployVY.
    function deployStep(address asset, uint256 deployVY, uint256 vcoCap, uint256 poolId) external {
        if (msg.sender != address(this)) revert OnlySelf();
        // Clamp to VCO headroom above the effective floor (subtractions guarded).
        uint256 floor_ = vco.effectiveFloor();
        uint256 headroom;
        unchecked { headroom = vcoCap > floor_ ? vcoCap - floor_ : 0; }
        if (deployVY > headroom) {
            uint256 clamped;
            unchecked { clamped = deployVY - headroom; }
            emit TargetClamped(asset, clamped, true);
            deployVY = headroom;
        }
        if (deployVY == 0) return;

        // VY → asset at VCO's live LTV (asset18-per-VY, WAD-scaled).
        uint256 ltv = vco.getLTV(asset);
        if (ltv == 0) return;
        uint256 pull = _scaleFromWad(Math.mulDiv(deployVY, ltv, WAD), asset);
        if (pull == 0) return;

        // Reserve the cap shift up-front.
        vco.decreaseAssetCap(asset, deployVY);

        // Pull the asset out of VRT into this officer; measure actual receipt
        // (PAXG is fee-on-transfer).
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = asset;
        amounts[0] = pull;
        vrt.deployForYield(assets, amounts, address(this));
        uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
        if (received == 0) {
            // Nothing arrived (VRT short / paused) — undo the cap shift.
            vco.increaseAssetCap(asset, deployVY);
            return;
        }

        // Inject into DAX and credit the ledger by the DAX contract's ACTUAL
        // token gain (balanceOf delta) — NOT the requested amount and NOT the
        // DAX internal reserve ledger (which credits the nominal amount and so
        // over-counts a fee-on-transfer asset like PAXG). Booking the real
        // arrival keeps deployedAsset in lockstep with what recall can actually
        // pull back, so PAXG can be fully recalled.
        IValinityDAX dax_ = dax;
        address daxAddr = address(dax_);
        IERC20(asset).forceApprove(daxAddr, received);
        uint256 daxBefore = IERC20(asset).balanceOf(daxAddr);
        dax_.reserveInjectAsset(poolId, received);
        uint256 credited = IERC20(asset).balanceOf(daxAddr) - daxBefore;
        if (credited == 0) revert InvariantViolation(asset);

        capVRYO[asset] += deployVY;
        deployedAsset[asset] += credited;

        // Defense-in-depth: no managed asset should linger on the officer.
        if (IERC20(asset).balanceOf(address(this)) != balBefore) revert InvariantViolation(asset);

        emit Deployed(asset, deployVY, poolId, credited);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RECALL
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Move up to `recallVY` cap-units VRYO→VCO and extract the matching
    ///      asset (at the blended internal LTV deployedAsset/capVRYO) straight
    ///      to VRT. Clamped to the pool's live asset reserve (swaps can thin it)
    ///      and try/caught so a thin pool degrades to partial/zero progress
    ///      instead of bricking execute(). VY is retired proportional to the
    ///      asset actually extracted, preserving the blended LTV.
    function _recall(address asset, uint256 recallVY, uint256 poolId) internal {
        uint256 cVY = capVRYO[asset];
        uint256 dep = deployedAsset[asset];
        if (cVY == 0 || dep == 0) return;
        if (recallVY > cVY) recallVY = cVY;

        // Desired physical at the stale blended LTV. recallVY ≤ cVY (clamped
        // above) ⇒ floored mulDiv ⇒ want ≤ dep, so no extra clamp is needed.
        uint256 want = Math.mulDiv(recallVY, dep, cVY);
        if (want == 0) {
            emit RecallSkipped(asset, poolId);
            return;
        }

        // Clamp to what DAX can actually pay out: bounded by the pool's tracked
        // reserve (DAX's own pre-transfer check) AND the contract's real token
        // balance (the safeTransfer). Using the real balance also absorbs any
        // DAX-side over-count on a fee-on-transfer asset, so the recall tail
        // degrades to partial progress instead of reverting and stranding.
        IValinityDAX dax_ = dax;
        (, , uint256 poolAsset) = dax_.getPoolReserves(poolId);
        uint256 daxBal = IERC20(asset).balanceOf(address(dax_));
        uint256 avail = poolAsset < daxBal ? poolAsset : daxBal;
        uint256 physical = want < avail ? want : avail;
        if (physical == 0) {
            emit RecallSkipped(asset, poolId);
            return;
        }

        // physical < dep ⇒ floored mulDiv ⇒ retireVY < cVY; full ⇒ retireVY == cVY.
        bool full = physical >= dep;
        uint256 retireVY = full ? cVY : Math.mulDiv(physical, cVY, dep);
        if (retireVY == 0) {
            emit RecallSkipped(asset, poolId);
            return;
        }

        // External extract first; bail cleanly if the pool can't satisfy it.
        try dax_.reserveExtractAsset(poolId, physical, address(vrt)) returns (uint256) {
            // ok — asset is now in VRT
        } catch {
            emit RecallSkipped(asset, poolId);
            return;
        }

        // Retire the ledger unconditionally (asset already returned to VRT).
        // !full ⇒ retireVY < cVY and physical < dep, so both subtractions hold.
        unchecked {
            capVRYO[asset] = full ? 0 : cVY - retireVY;
            deployedAsset[asset] = full ? 0 : dep - physical;
        }

        // Restore the VCO cap in ISOLATION: increaseAssetCap reverts if the
        // asset has been de-listed (UnsupportedAsset). That MUST NOT brick
        // execute() — the cap units retire with the de-listed asset and the
        // tokens are already back in VRT. (A revert here would otherwise
        // escape the extract try/catch above, since it sits outside it.)
        try vco.increaseAssetCap(asset, retireVY) {} catch {}

        emit Recalled(asset, retireVY, poolId, physical);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DECIMALS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Convert an 18-decimal amount to the asset's native decimals.
    function _scaleFromWad(uint256 amount18, address asset) internal view returns (uint256) {
        uint8 d = _assetDecimals(asset);
        if (d == 18) return amount18;
        return amount18 / (10 ** (18 - d)); // d < 18 here (only WBTC = 8)
    }

    function _assetDecimals(address asset) internal view returns (uint8) {
        if (asset == address(weth)) return 18;
        if (asset == address(paxg)) return 18;
        if (asset == address(wbtc)) return 8;
        revert InvalidAsset();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set an asset's deploy ratio (bps of its global cap). Use to ramp
    ///         a measured rollout (e.g. 2000 → 5000 → 8500), or 0 to fully
    ///         recall. Only the managed set {WETH, WBTC, PAXG} is accepted.
    function setAssetDeployRatio(address asset, uint16 bps) external onlyRole(ADMIN_ROLE) {
        if (bps > MAX_DEPLOY_RATIO_BPS) revert InvalidParam();
        if (asset != address(weth) && asset != address(wbtc) && asset != address(paxg)) {
            revert InvalidAsset();
        }
        assetDeployRatioBps[asset] = bps;
        emit AssetDeployRatioUpdated(asset, bps);
    }

    /// @notice Point VRYO at the ValinityDAX (must grant RESERVE_OFFICER_ROLE
    ///         to this officer on the DAX side first).
    function setDax(address newDax) external onlyRole(ADMIN_ROLE) {
        if (newDax == address(0)) revert InvalidAddress();
        dax = IValinityDAX(newDax);
        emit DaxUpdated(newDax);
    }

    /// @notice Set the rebalance band (bps of global cap). Lower = rebalances
    ///         on smaller share drift (more frequent); higher = wider deadband.
    function setKeeperThreshold(uint16 bps) external onlyRole(ADMIN_ROLE) {
        if (bps == 0 || bps > MAX_KEEPER_THRESHOLD_BPS) revert InvalidParam();
        keeperThresholdBps = bps;
        emit KeeperThresholdUpdated(bps);
    }

    function setPaused(bool p) external onlyRole(ADMIN_ROLE) {
        paused = p;
        emit PausedUpdated(p);
    }

    /// @notice EMERGENCY — recall every managed asset's full position back to
    ///         VRT and restore VCO caps to their pre-VRYO state. Works while
    ///         paused. For each asset: extract min(deployedAsset, pool reserve)
    ///         to VRT, restore the full capVRYO cap-units to VCO, zero the
    ///         ledger. If the pool can't return the whole position (thinned by
    ///         swaps), the cap is still fully restored; admin may re-tune via
    ///         vco.setAssetCap afterward.
    function rescueTokens() external onlyRole(ADMIN_ROLE) nonReentrant {
        _fullRecall(address(weth));
        _fullRecall(address(wbtc));
        _fullRecall(address(paxg));
        emit SystemReset(msg.sender);
    }

    function _fullRecall(address asset) internal {
        uint256 cVY = capVRYO[asset];
        if (cVY == 0) return;
        uint256 dep = deployedAsset[asset];

        capVRYO[asset] = 0;
        deployedAsset[asset] = 0;

        IValinityDAX dax_ = dax;
        if (dep != 0 && dax_.hasPool(asset)) {
            uint256 poolId = dax_.assetToPoolId(asset);
            (, , uint256 poolAsset) = dax_.getPoolReserves(poolId);
            uint256 daxBal = IERC20(asset).balanceOf(address(dax_));
            uint256 avail = poolAsset < daxBal ? poolAsset : daxBal;
            uint256 physical = dep < avail ? dep : avail;
            if (physical != 0) {
                // Best-effort: never let a thin pool block the cap restore. NOTE:
                // on a caught revert the ledger is already zeroed, so any asset
                // left in the pool must be recovered via the DAX's own
                // adminExtract — not via VRYO (which no longer tracks it).
                try dax_.reserveExtractAsset(poolId, physical, address(vrt)) returns (uint256) {
                    emit Recalled(asset, cVY, poolId, physical);
                } catch {
                    emit RecallSkipped(asset, poolId);
                }
            }
        }

        // Isolated: a de-listed asset (UnsupportedAsset) must not block the
        // rest of the rescue. The cap restore is best-effort here.
        try vco.increaseAssetCap(asset, cVY) {} catch {}
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function getCirculatingVY() external view returns (uint256) { return vco.getTotalCirculatingVY(); }

    /// @notice An asset's conserved global cap = VCO residual + VRYO-held.
    function getGlobalCap(address asset) external view returns (uint256) {
        return vco.getAssetCap(asset) + capVRYO[asset];
    }

    /// @notice Blended internal LTV (asset18-per-VY, WAD-scaled). 0 if nothing
    ///         is deployed. This is the rate recall converts at.
    function getInternalLTV(address asset) external view returns (uint256) {
        uint256 cVY = capVRYO[asset];
        if (cVY == 0) return 0;
        uint256 dep18 = deployedAsset[asset] * (10 ** (18 - _assetDecimals(asset)));
        return Math.mulDiv(dep18, WAD, cVY);
    }

    function getCapVRYO(address asset) external view returns (uint256) { return capVRYO[asset]; }
    function getDeployedAsset(address asset) external view returns (uint256) { return deployedAsset[asset]; }

    /// @dev Storage gap. Reduced from 38 → 34 by the four DAX-edition vars
    ///      (assetDeployRatioBps, dax, capVRYO, deployedAsset). The total
    ///      storage footprint is unchanged, preserving slots after the gap.
    uint256[34] private __gap;
}
