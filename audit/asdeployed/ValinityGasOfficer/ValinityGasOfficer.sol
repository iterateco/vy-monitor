// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IKeeperRewards} from "../interfaces/IKeeperRewards.sol";

// ─────────────────────────────────────────────────────────────────────────────
// External interfaces (minimal surfaces — only what this contract needs)
// ─────────────────────────────────────────────────────────────────────────────

interface IValinityDAX {
    /// @return asset        Address of the pool's non-VY asset
    /// @return reserveVY    Current VY reserves in the pool
    /// @return reserveAsset Current asset reserves in the pool
    function getPoolReserves(uint256 poolId)
        external
        view
        returns (address asset, uint256 reserveVY, uint256 reserveAsset);

    function getNumPools() external view returns (uint256);
}

interface IVGC {
    /// @dev Caller must be the locked `minter` (this contract). Clamped to the
    ///      per-epoch mint ceiling — reverts past it.
    function mint(address to, uint256 amount) external;
    /// @dev Circulating VGC. Used to drive the reward-multiplier decay curve.
    function totalSupply() external view returns (uint256);
}

// ── Legacy interface stubs — retained ONLY so the inert legacy storage slots
//    below keep their exact original types. Never called. ──
interface IValinityYieldTreasury { function pullTokens(address, uint256) external returns (uint256); }
interface IValinityCapOfficer    { function addToHighestLTVFCap(uint256) external; }
interface IWETH                  { function withdraw(uint256) external; }

// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title  ValinityGasOfficer (VGO)
 * @notice Reimburses the keeper that triggered a roled-officer call, in freshly
 *         minted VGC, for the gas that call cost — with an attack-resistant
 *         pricing model and a self-tapering subsidy.
 *
 * @dev    One reward path, nothing else. A roled officer (OFFICER_ROLE) brackets
 *         its permissionless poke with `beginReward()` … `payReward(keeper)`;
 *         VGO meters the gas itself (gasleft snapshots in transient storage), the
 *         keeper supplies nothing.
 *
 *         REWARD (per call), in ETH-value then converted to VGC at the DAX spot:
 *           gasUsed   = meteredSpan + TX_INTRINSIC_GAS(21k) + finalOverheadGas
 *           tip       = tx.gasprice − block.basefee          // effective tip PAID
 *           perGasWei = baseFee × mult/BPS  +  min(tip, tipCapWei)
 *           ethValue  = min( gasUsed × perGasWei , maxRewardPerCallWei )
 *           vgc       = spotQuote(ethValue)                  // WETH→VY→VGC, mid-price
 *
 *         WHY THIS IS SAFE (no overpay incentive):
 *           - The PREMIUM (`mult`, 7×→1.25×) rides ONLY on `block.basefee`, which
 *             the keeper cannot manipulate. So the keeper's margin comes from a
 *             quantity it cannot inflate.
 *           - The TIP (the only keeper-set input) is reimbursed AT MOST 1:1 and
 *             CAPPED (`tipCapWei`). Inflating the tip past the cap is a pure loss;
 *             below the cap it is net-zero (and net-negative after VGC slippage).
 *             So a keeper is never paid a premium on its own tip.
 *           - `maxRewardPerCallWei` caps the per-call value (so the protocol never
 *             overpays for expensive blockspace — keepers self-select cheap gas).
 *           - VGC's per-epoch mint ceiling (`epochMintBps`, `0` = halt) is the
 *             ultimate emission cap + kill-switch, bounding the validator-recycling
 *             edge case to the weekly budget.
 *
 *         DECAY CURVE (mirrors the VGC mint, in reverse):
 *           mult = floorMultBps + (maxMultBps − floorMultBps) × unminted / 6e24
 *           where unminted = VGC_MAX_SUPPLY − VGC.totalSupply().
 *         At launch (most unminted) the premium is `maxMultBps` (7×); as supply
 *         approaches the 7M cap the premium tapers to `floorMultBps` (1.25×) — the
 *         same `unminted` amount that shrinks the weekly mint ceiling. Monotonic
 *         (supply only grows, no burn) ⇒ the multiplier can only fall ⇒ no quiet
 *         period for a keeper to farm a higher rate.
 *
 *         VGC pricing is a 2-hop SPOT quote on the PRIVATE DAX (WETH→VY via
 *         `wethPoolId`, VY→VGC via `vgcVyPoolId`). Safe to spot-price because the
 *         DAX is swap-permissioned — a keeper cannot move reserves in its own tx.
 *         VGO is VGC's sole locked minter.
 *
 *         STORAGE: this upgrades the LIVE proxy in place, so the full prior layout
 *         is preserved byte-for-byte. The inert legacy slots are parked for layout
 *         safety and never read; `dax`, `wethPoolId`, `finalOverheadGas` and
 *         `maxRewardPerCallWei` are reused. The curve band + tip cap are appended.
 */
contract ValinityGasOfficer is
    Initializable,
    AccessControl,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    IKeeperRewards
{
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // ROLES
    // ─────────────────────────────────────────────────────────────────────────

    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");
    /// @notice The sole authorization to call beginReward/payReward.
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER_ROLE");

    // ─────────────────────────────────────────────────────────────────────────
    // STORAGE — INERT LEGACY SLOTS (DO NOT REORDER / REMOVE)
    //
    // Preserved byte-for-byte from the live V1/V2→V3 layout so this upgrades the
    // existing proxy. Only `dax`, `wethPoolId`, `finalOverheadGas` and
    // `maxRewardPerCallWei` are read; the rest are inert.
    // ─────────────────────────────────────────────────────────────────────────

    // Inert slots are `private` (no auto-getter → smaller bytecode); names/types
    // are byte-identical to the live layout. Only read slots are public.
    IValinityYieldTreasury private vyt;           // inert
    IValinityCapOfficer    private vco;           // inert
    IValinityDAX           public  dax;           // USED — spot-quote source
    IERC20                 private vy;            // inert
    IWETH                  private weth;          // inert (read for its address in wireVgc)

    uint256 public  wethPoolId;                   // USED — VY/WETH pool id
    uint256 private lowThresholdWei;              // inert
    uint256 private topUpTargetWei;               // inert
    uint256 private cooldown;                     // inert
    uint256 private lastTopUp;                    // inert
    uint256 private slippageBps;                  // inert

    address[] private wallets;                    // inert
    mapping(address => bool) private isWallet;    // inert

    struct LegacyJob { uint96 rewardWei; uint64 cooldown; uint64 lastPaidAt; bool enabled; }
    mapping(bytes32 => LegacyJob) private _legacyJobs;     // inert
    bytes32[] private _legacyJobIds;                       // inert

    struct OfficerCfg { uint96 rewardWei; uint64 cooldown; uint64 lastPaidAt; bool enabled; }
    mapping(address => OfficerCfg) private officerConfigs; // inert (auth is OFFICER_ROLE); name kept for layout

    /// @notice RE-ACTIVATED legacy slot — absolute per-call reward ceiling (wei of
    ///         ETH value). `0` = no cap. Same name/type/slot as the V3 swap-era
    ///         knob, so the proxy layout is unchanged.
    uint256 public  maxRewardPerCallWei;
    uint256 private maxGasPriceWei;               // inert (V3 swap-era knob)
    uint256 private swapOverheadGas;              // inert (V3 swap-era knob)
    /// @notice Fixed gas added to the metered span (tail: quote + mint + event,
    ///         plus calldata allowance). REUSED.
    uint256 public finalOverheadGas;

    // ─────────────────────────────────────────────────────────────────────────
    // STORAGE — APPENDED (VGC-reward engine)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The VGC token. VGO is its sole locked minter. `address(0)` until
    ///         `wireVgc` — `payReward` reverts `VgcNotWired` until then.
    IVGC    public vgc;
    /// @notice VGC/VY pool id on the main DAX, discovered by `wireVgc`.
    uint256 public vgcVyPoolId;
    /// @notice DEPRECATED — the old fixed reward multiple. Superseded by the
    ///         `maxMultBps`/`floorMultBps` decay curve; left in place for layout.
    uint256 public rewardMultipleBps;
    /// @notice Optional cap on the base fee used for the PREMIUM leg (wei); `0` =
    ///         no cap. Does not affect the tip leg.
    uint256 public maxBaseFeeWei;

    // ── Curve band + tip cap (this upgrade) ──
    /// @notice Premium multiplier at launch / ceiling, bps (70000 = 7×). Applied
    ///         to the base fee only. Admin-tunable within [HARD_MIN, HARD_MAX].
    uint256 public maxMultBps;
    /// @notice Premium multiplier floor, bps (12500 = 1.25×). The mature/asymptotic
    ///         premium once the VGC cap is approached.
    uint256 public floorMultBps;
    /// @notice Max reimbursable priority tip per gas (wei). Tip is paid 1:1 up to
    ///         this; above it the keeper eats the excess (no overpay incentive).
    uint256 public tipCapWei;

    /// @dev Reserve for future upgrades. Prior __gap[37]; 3 vars appended ⇒ 34.
    uint256[34] private __gap;

    // ─────────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant BPS              = 10_000;
    /// @notice EVM intrinsic gas floor (base tx cost), added so the refund tracks
    ///         the WHOLE transaction, not just the metered span.
    uint256 public constant TX_INTRINSIC_GAS = 21_000;

    uint256 public constant DEFAULT_FINAL_OVERHEAD_GAS  = 120_000;

    // ── Decay-curve bounds + defaults (this upgrade) ──
    /// @notice Hard ceiling on the premium multiplier — admin can never exceed 7×.
    uint256 public constant HARD_MAX_MULT_BPS = 70_000; // 7×
    /// @notice Hard floor on the premium multiplier — admin can never go below 1.25×.
    uint256 public constant HARD_MIN_MULT_BPS = 12_500; // 1.25×
    uint256 public constant DEFAULT_MAX_MULT_BPS    = 70_000;       // 7×
    uint256 public constant DEFAULT_FLOOR_MULT_BPS  = 12_500;       // 1.25×
    uint256 public constant DEFAULT_TIP_CAP_WEI     = 25 gwei;
    uint256 public constant DEFAULT_PER_CALL_CAP_WEI = 0.005 ether;

    /// @notice VGC supply constants (immutable on the VGC token), used to drive the
    ///         decay curve. VGC_REWARD_POOL = MAX_SUPPLY − INITIAL_SUPPLY (premint).
    uint256 public constant VGC_MAX_SUPPLY  = 7_000_000 * 1e18;
    uint256 public constant VGC_REWARD_POOL = 6_000_000 * 1e18;

    /// @dev Seed for the per-officer transient slot holding `beginReward`'s
    ///      `gasleft()` snapshot. Namespaced vs ReentrancyGuardTransient.
    bytes32 private constant _GAS_START_SLOT_SEED =
        keccak256("valinity.vgo.beginReward.v1");

    // ─────────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────────

    error InvalidAddress();
    error InvalidParameters(string reason);
    error NoBeginReward(address officer);
    error VgcNotWired();
    error VgcPoolNotFound(address vgc);
    error WethPoolNotFound();
    error EthTransferFailed();

    // ─────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────────

    event RewardPaid(address indexed officer, address indexed keeper, uint256 gasUsed, uint256 ethValueWei, uint256 vgcMinted);
    event VgcWired(address indexed vgc, uint256 vgcVyPoolId, uint256 wethPoolId);
    event MaxBaseFeeUpdated(uint256 newValue);
    event FinalOverheadGasUpdated(uint256 newValue);
    event MultiplierBandUpdated(uint256 maxMultBps, uint256 floorMultBps);
    event TipCapUpdated(uint256 newValue);
    event MaxRewardPerCallUpdated(uint256 newValue);
    event EthRescued(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // INITIALIZER / REINITIALIZERS
    // ─────────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Fresh-deploy initializer — NEW environments only. The mainnet proxy
     *         reaches this impl by UPGRADE (already past `initializer`), so it
     *         NEVER calls this; it calls `initializeRewardsV2` directly.
     */
    function initialize(address daxAddr, address wethAddr, address admin_)
        external
        initializer
    {
        if (daxAddr == address(0) || wethAddr == address(0) || admin_ == address(0)) revert InvalidAddress();
        dax  = IValinityDAX(daxAddr);
        weth = IWETH(wethAddr);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        // wethPoolId + vgcVyPoolId are (re)discovered by wireVgc.
    }

    /**
     * @notice One-time reinit (`reinitializer(5)`) for the premium-on-base +
     *         capped-tip + decay-curve model. Each `0` argument falls back to its
     *         DEFAULT_*. `maxBaseFeeWei` is left untouched (persisted / 0 = no cap;
     *         set later via `setMaxBaseFeeWei`).
     */
    function initializeRewardsV2(
        uint256 _maxMultBps,
        uint256 _floorMultBps,
        uint256 _tipCapWei,
        uint256 _maxRewardPerCallWei,
        uint256 _finalOverheadGas
    ) external reinitializer(5) onlyRole(ADMIN_ROLE) {
        uint256 mx = _maxMultBps   == 0 ? DEFAULT_MAX_MULT_BPS   : _maxMultBps;
        uint256 fl = _floorMultBps == 0 ? DEFAULT_FLOOR_MULT_BPS : _floorMultBps;
        if (mx > HARD_MAX_MULT_BPS) revert InvalidParameters("maxMult too high");
        if (fl < HARD_MIN_MULT_BPS) revert InvalidParameters("floorMult too low");
        if (fl > mx)                revert InvalidParameters("floor > max");

        maxMultBps          = mx;
        floorMultBps        = fl;
        tipCapWei           = _tipCapWei == 0           ? DEFAULT_TIP_CAP_WEI      : _tipCapWei;
        maxRewardPerCallWei = _maxRewardPerCallWei == 0 ? DEFAULT_PER_CALL_CAP_WEI : _maxRewardPerCallWei;
        finalOverheadGas    = _finalOverheadGas == 0    ? DEFAULT_FINAL_OVERHEAD_GAS : _finalOverheadGas;

        emit MultiplierBandUpdated(mx, fl);
        emit TipCapUpdated(tipCapWei);
        emit MaxRewardPerCallUpdated(maxRewardPerCallWei);
        emit FinalOverheadGasUpdated(finalOverheadGas);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CORE
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Snapshot `gasleft()` at the entry of a roled officer's poke.
     *         Stored in transient storage keyed by msg.sender; cleared in
     *         `payReward` and when the tx ends.
     * @dev    Auth: `OFFICER_ROLE`.
     */
    function beginReward() external override onlyRole(OFFICER_ROLE) {
        uint256 g = gasleft();
        bytes32 slot = keccak256(abi.encode(_GAS_START_SLOT_SEED, msg.sender));
        assembly { tstore(slot, g) }
    }

    /**
     * @notice Reimburse the keeper for the call's gas, in VGC: a base-fee premium
     *         (curve, 7×→1.25×) plus the keeper's tip 1:1 up to `tipCapWei`,
     *         capped per call by `maxRewardPerCallWei`. MUST follow `beginReward()`
     *         in the same tx from the same officer.
     * @dev    Auth: `OFFICER_ROLE`. No swap, no ETH movement. Reverts are meant to
     *         be caught by the officer's try/catch so the poke never bricks.
     */
    function payReward(address keeper)
        external
        override
        onlyRole(OFFICER_ROLE)
        nonReentrant
    {
        if (keeper == address(0)) revert InvalidAddress();

        // ── Load + clear the transient gas snapshot from beginReward() ──
        uint256 gasStart;
        {
            bytes32 slot = keccak256(abi.encode(_GAS_START_SLOT_SEED, msg.sender));
            assembly {
                gasStart := tload(slot)
                tstore(slot, 0)
            }
        }
        if (gasStart == 0) revert NoBeginReward(msg.sender);

        IVGC _vgc = vgc;
        if (address(_vgc) == address(0)) revert VgcNotWired();

        // ── Whole-tx gas ≈ metered span + intrinsic + fixed tail ──
        uint256 gasUsed;
        unchecked { gasUsed = gasStart - gasleft() + TX_INTRINSIC_GAS + finalOverheadGas; }

        // ── Per-gas reimbursement = premium on base fee + capped 1:1 tip ──
        uint256 rawBase = block.basefee;
        uint256 premBase = rawBase;
        {
            uint256 capBf = maxBaseFeeWei;            // optional base-fee cap (premium leg only)
            if (capBf != 0 && premBase > capBf) premBase = capBf;
        }
        // Effective tip actually paid. tx.gasprice >= block.basefee always ⇒ safe.
        uint256 tip;
        unchecked { tip = tx.gasprice - rawBase; }
        {
            uint256 tc = tipCapWei;                   // reimburse tip 1:1, capped
            if (tip > tc) tip = tc;
        }

        uint256 multBps = _currentMultBps(_vgc);      // 7× → 1.25× by VGC supply
        uint256 perGasWei = Math.mulDiv(premBase, multBps, BPS) + tip;

        uint256 ethValue = gasUsed * perGasWei;
        {
            uint256 cap = maxRewardPerCallWei;        // absolute per-call ceiling; 0 = none
            if (cap != 0 && ethValue > cap) ethValue = cap;
        }
        if (ethValue == 0) return;                    // nothing to reimburse

        // ── Price ETH value → VGC via 2-hop DAX spot quote (no swap) ──
        uint256 vgcAmount = _quoteVgcForWeth(ethValue);
        if (vgcAmount == 0) return;                   // pool unseeded / rounded to zero

        _vgc.mint(keeper, vgcAmount);
        emit RewardPaid(msg.sender, keeper, gasUsed, ethValue, vgcAmount);
    }

    /**
     * @notice Current premium multiplier (bps), decaying linearly with the VGC
     *         unminted fraction — the mirror of the mint curve.
     * @dev    mult = floor + (max − floor) × unminted / VGC_REWARD_POOL, where
     *         unminted = VGC_MAX_SUPPLY − totalSupply(). Since supply ≥ premint and
     *         never burns, unminted ∈ [0, VGC_REWARD_POOL] ⇒ mult ∈ [floor, max].
     */
    function _currentMultBps(IVGC _vgc) internal view returns (uint256) {
        uint256 supply = _vgc.totalSupply();
        uint256 unminted = VGC_MAX_SUPPLY > supply ? VGC_MAX_SUPPLY - supply : 0;
        uint256 fl = floorMultBps;
        uint256 mx = maxMultBps;
        uint256 mult = fl + Math.mulDiv(mx - fl, unminted, VGC_REWARD_POOL);
        return mult > mx ? mx : mult; // defensive clamp
    }

    /**
     * @notice Spot-price `wethWei` of WETH into VGC across two DAX pools.
     * @dev    Mid-price (reserve ratio), not a swap simulation:
     *           VY per WETH = reserveVY(VY/WETH) / reserveWETH(VY/WETH)
     *           VGC per VY  = reserveVGC(VGC/VY) / reserveVY(VGC/VY)
     *         Returns 0 if either pool is unseeded.
     */
    function _quoteVgcForWeth(uint256 wethWei) internal view returns (uint256) {
        IValinityDAX _dax = dax;                                             // 1 SLOAD, reused
        (, uint256 rVYw, uint256 rWeth) = _dax.getPoolReserves(wethPoolId);  // VY/WETH
        (, uint256 rVYv, uint256 rVGC)  = _dax.getPoolReserves(vgcVyPoolId); // VGC/VY
        if (rVYw == 0 || rWeth == 0 || rVYv == 0 || rVGC == 0) return 0;
        uint256 vyEquiv = Math.mulDiv(wethWei, rVYw, rWeth);
        return Math.mulDiv(vyEquiv, rVGC, rVYv);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VIEWS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice True once `vgc` is set and both quote pools are non-empty.
    function isPayoutReady() external view returns (bool) {
        if (address(vgc) == address(0)) return false;
        return _quoteVgcForWeth(1 ether) > 0;
    }

    /// @notice The current premium multiplier (bps). `0` if VGC is not wired.
    function currentMultipleBps() external view returns (uint256) {
        IVGC _vgc = vgc;
        if (address(_vgc) == address(0)) return 0;
        return _currentMultBps(_vgc);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADMIN
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Set VGC and (re)discover BOTH quote-pool ids on the main DAX in one
     *         scan — the WETH pool (`asset == weth`) and the VGC/VY pool
     *         (`asset == vgcAddr`). Call AFTER `VGC.setMinter(this)` and the VGC/VY
     *         pool seed. RE-RUNNABLE: call again any time the DAX is reindexed so
     *         both ids stay correct. Reverts if either pool is missing.
     */
    function wireVgc(address vgcAddr) external onlyRole(ADMIN_ROLE) {
        if (vgcAddr == address(0)) revert InvalidAddress();
        address wethAddr = address(weth);

        IValinityDAX _dax = dax;
        uint256 n = _dax.getNumPools();
        bool wethFound;
        bool vgcFound;
        uint256 wethPid;
        uint256 vgcPid;
        for (uint256 i; i < n;) {
            (address asset,,) = _dax.getPoolReserves(i);
            if (asset == wethAddr)      { wethPid = i; wethFound = true; }
            else if (asset == vgcAddr)  { vgcPid  = i; vgcFound  = true; }
            unchecked { ++i; }
        }
        if (!wethFound) revert WethPoolNotFound();
        if (!vgcFound)  revert VgcPoolNotFound(vgcAddr);

        wethPoolId  = wethPid;
        vgcVyPoolId = vgcPid;
        vgc         = IVGC(vgcAddr);
        emit VgcWired(vgcAddr, vgcPid, wethPid);
    }

    /// @notice Set the premium band. Hard-bounded to [1.25×, 7×]; floor ≤ max.
    function setMultiplierBand(uint256 _maxMultBps, uint256 _floorMultBps) external onlyRole(ADMIN_ROLE) {
        if (_maxMultBps > HARD_MAX_MULT_BPS)   revert InvalidParameters("maxMult too high");
        if (_floorMultBps < HARD_MIN_MULT_BPS) revert InvalidParameters("floorMult too low");
        if (_floorMultBps > _maxMultBps)       revert InvalidParameters("floor > max");
        maxMultBps   = _maxMultBps;
        floorMultBps = _floorMultBps;
        emit MultiplierBandUpdated(_maxMultBps, _floorMultBps);
    }

    /// @notice Max reimbursable tip per gas (wei). `0` ⇒ tip leg disabled (base-fee
    ///         only). Cannot create an overpay incentive — it only lowers payout.
    function setTipCapWei(uint256 v) external onlyRole(ADMIN_ROLE) {
        tipCapWei = v;
        emit TipCapUpdated(v);
    }

    /// @notice Absolute per-call reward ceiling (wei of ETH value). `0` = no cap.
    function setMaxRewardPerCallWei(uint256 v) external onlyRole(ADMIN_ROLE) {
        maxRewardPerCallWei = v;
        emit MaxRewardPerCallUpdated(v);
    }

    /// @notice `v == 0` disables the base-fee cap (premium leg).
    function setMaxBaseFeeWei(uint256 v) external onlyRole(ADMIN_ROLE) {
        maxBaseFeeWei = v;
        emit MaxBaseFeeUpdated(v);
    }

    function rescueEth(address payable to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert InvalidAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthRescued(to, amount);
    }

    function rescueToken(IERC20 token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert InvalidAddress();
        token.safeTransfer(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // UUPS
    // ─────────────────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
