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
}

// ── Legacy interface stubs — retained ONLY so the inert legacy storage slots
//    below keep their exact original types. Never called. ──
interface IValinityYieldTreasury { function pullTokens(address, uint256) external returns (uint256); }
interface IValinityCapOfficer    { function addToHighestLTVFCap(uint256) external; }
interface IWETH                  { function withdraw(uint256) external; }

// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title  ValinityGasOfficer (VGO)
 * @notice Pays the keeper that triggered a roled-officer call 1.25× the BASE-FEE
 *         cost of that call, in freshly-minted VGC.
 *
 * @dev    One reward path, nothing else:
 *           - A roled officer (OFFICER_ROLE) brackets its permissionless poke
 *             with `beginReward()` … `payReward(keeper)`. VGO meters the gas
 *             itself (gasleft snapshots in transient storage); the keeper
 *             supplies nothing.
 *           - Reimbursed ETH value = `rewardMultipleBps × baseFee × gasUsed`,
 *             where `baseFee = min(block.basefee, maxBaseFeeWei|∞)` (tip ignored)
 *             and `gasUsed` includes the tx INTRINSIC (21k) + a fixed tail so it
 *             approximates the WHOLE transaction's base-fee cost.
 *           - That value is converted to VGC via a 2-hop SPOT quote on the
 *             PRIVATE DAX (WETH→VY via `wethPoolId`, VY→VGC via `vgcVyPoolId`).
 *             Safe to spot-price because the DAX is swap-permissioned — a keeper
 *             cannot move reserves in its own tx.
 *           - VGO is VGC's sole locked minter; VGC's per-epoch ceiling
 *             (`epochMintBps`, `0` = halt) is the protocol-level emission cap +
 *             kill-switch.
 *
 *         STORAGE: this upgrades the LIVE V3 proxy in place, so the full V3
 *         layout is preserved byte-for-byte; the inert slots (V1/V2 wallet
 *         config, `_legacyJobs`, `officerConfigs`, swap knobs) are parked for
 *         layout safety and never read. `finalOverheadGas` is the only V3 slot
 *         reused.
 *
 *         Wiring (admin, AFTER VGC + pools exist): `VGC.setMinter(this)` →
 *         `wireVgc(vgc)` → `grantRole(OFFICER_ROLE, officer)` per officer.
 *         Roles revoked at upgrade (dead): VYT/VCO OFFICER_ROLE, DAX
 *         swapWhitelist, VY whitelist.
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
    // existing proxy. Only `dax`, `wethPoolId`, and `finalOverheadGas` are read.
    // ─────────────────────────────────────────────────────────────────────────

    // Inert slots are `private` (no auto-getter → smaller bytecode); names/types
    // are byte-identical to the live V3 layout. Only the 3 read slots are public.
    IValinityYieldTreasury private vyt;           // inert
    IValinityCapOfficer    private vco;           // inert
    IValinityDAX           public  dax;           // USED — spot-quote source
    IERC20                 private vy;            // inert
    IWETH                  private weth;          // inert

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

    uint256 private maxRewardPerCallWei;          // inert (V3 swap-era knob)
    uint256 private maxGasPriceWei;               // inert (V3 swap-era knob)
    uint256 private swapOverheadGas;              // inert (V3 swap-era knob)
    /// @notice Fixed gas added to the metered span (tail: quote + mint + event,
    ///         plus calldata allowance). REUSED from V3.
    uint256 public finalOverheadGas;

    // ─────────────────────────────────────────────────────────────────────────
    // STORAGE — APPENDED (VGC-reward engine)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The VGC token. VGO is its sole locked minter. `address(0)` until
    ///         `wireVgc` — `payReward` reverts `VgcNotWired` until then.
    IVGC    public vgc;
    /// @notice VGC/VY pool id on the main DAX, discovered by `wireVgc`.
    uint256 public vgcVyPoolId;
    /// @notice Reward multiple, bps of the base-fee cost (12500 = 1.25×).
    uint256 public rewardMultipleBps;
    /// @notice Optional cap on the base fee used (wei); `0` = no cap.
    uint256 public maxBaseFeeWei;

    /// @dev Reserve for future upgrades. V3 had __gap[41]; 4 vars appended ⇒ 37.
    uint256[37] private __gap;

    // ─────────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public constant BPS              = 10_000;
    /// @notice Sanity ceiling on `rewardMultipleBps` (3×) — blocks an init typo.
    uint256 public constant MAX_MULTIPLE_BPS = 30_000;
    /// @notice EVM intrinsic gas floor (base tx cost), added so the refund tracks
    ///         the WHOLE transaction, not just the metered span.
    uint256 public constant TX_INTRINSIC_GAS = 21_000;

    uint256 public constant DEFAULT_REWARD_MULTIPLE_BPS = 12_500; // 1.25×
    uint256 public constant DEFAULT_FINAL_OVERHEAD_GAS  = 120_000;

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
    event RewardMultipleUpdated(uint256 newBps);
    event MaxBaseFeeUpdated(uint256 newValue);
    event FinalOverheadGasUpdated(uint256 newValue);
    event EthRescued(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // INITIALIZER / REINITIALIZER
    // ─────────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Fresh-deploy initializer — NEW environments only. The mainnet
     *         proxy reaches this impl by UPGRADE (already past `initializer`),
     *         so it NEVER calls this; it calls `initializeRewards` directly.
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
     * @notice One-time reinit for the VGC-reward redesign. `reinitializer(4)` —
     *         the live V3 proxy is at initialized version 3. Sets the reward
     *         knobs (0 ⇒ DEFAULT_*). `vgc` is wired later via `wireVgc`. There
     *         are no runtime setters for the multiple/overhead — re-tuning is a
     *         UUPS re-upgrade.
     */
    function initializeRewards(
        uint256 _rewardMultipleBps,
        uint256 _maxBaseFeeWei,
        uint256 _finalOverheadGas
    ) external reinitializer(4) onlyRole(ADMIN_ROLE) {
        uint256 mul = _rewardMultipleBps == 0 ? DEFAULT_REWARD_MULTIPLE_BPS : _rewardMultipleBps;
        if (mul > MAX_MULTIPLE_BPS) revert InvalidParameters("rewardMultiple too high");

        rewardMultipleBps = mul;
        maxBaseFeeWei     = _maxBaseFeeWei; // 0 = no cap
        finalOverheadGas  = _finalOverheadGas == 0 ? DEFAULT_FINAL_OVERHEAD_GAS : _finalOverheadGas;

        emit RewardMultipleUpdated(mul);
        emit MaxBaseFeeUpdated(_maxBaseFeeWei);
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
     * @notice Mint the keeper 1.25× the base-fee cost of the call, in VGC.
     *         MUST follow `beginReward()` in the same tx from the same officer.
     * @dev    Auth: `OFFICER_ROLE`. No swap, no ETH movement. Reverts are meant
     *         to be caught by the officer's try/catch so the poke never bricks.
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

        // ── Effective base fee (tip ignored; optionally capped) ──
        uint256 baseFee = block.basefee;
        {
            uint256 capBf = maxBaseFeeWei;
            if (capBf != 0 && baseFee > capBf) baseFee = capBf;
        }

        // ── Whole-tx gas ≈ metered span + intrinsic + fixed tail ──
        uint256 gasUsed;
        unchecked { gasUsed = gasStart - gasleft() + TX_INTRINSIC_GAS + finalOverheadGas; }

        uint256 ethValue = Math.mulDiv(gasUsed * baseFee, rewardMultipleBps, BPS);
        if (ethValue == 0) return; // zero base fee — nothing to reimburse

        // ── Price ETH value → VGC via 2-hop DAX spot quote (no swap) ──
        uint256 vgcAmount = _quoteVgcForWeth(ethValue);
        if (vgcAmount == 0) return; // pool unseeded / rounded to zero

        _vgc.mint(keeper, vgcAmount);
        emit RewardPaid(msg.sender, keeper, gasUsed, ethValue, vgcAmount);
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

    /// @notice True once `vgc` is set and both quote pools are non-empty.
    function isPayoutReady() external view returns (bool) {
        if (address(vgc) == address(0)) return false;
        return _quoteVgcForWeth(1 ether) > 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADMIN
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Set VGC and (re)discover BOTH quote-pool ids on the main DAX in
     *         one scan — the WETH pool (`asset == weth`) and the VGC/VY pool
     *         (`asset == vgcAddr`). Call AFTER `VGC.setMinter(this)` and the
     *         VGC/VY pool seed. RE-RUNNABLE: call again any time the DAX is
     *         reindexed so both ids stay correct. Reverts if either pool is
     *         missing.
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

    /// @notice `v == 0` disables the base-fee cap.
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
