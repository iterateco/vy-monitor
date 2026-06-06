// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ValinityToken} from "../token/ValinityToken.sol";
import {ValinityYieldTreasury} from "../treasury/ValinityYieldTreasury.sol";
import {ValinityReserveTreasury} from "../treasury/ValinityReserveTreasury.sol";
import {ValinityCapOfficer} from "../officer/ValinityCapOfficer.sol";
import {IValinityDAX} from "../dex/interfaces/IValinityDAX.sol";
import {IKeeperRewards} from "../interfaces/IKeeperRewards.sol";

/// @notice Minimal accessors on ValinityDAX not exposed by IValinityDAX.
interface IValinityDAXLookup {
    function hasPool(address asset) external view returns (bool);
    function assetToPoolId(address asset) external view returns (uint256);
}

/// @notice Permissionless rebalance entry on the Reserve Yield Officer.
interface IValinityReserveYieldOfficer {
    function execute() external;
}

/// @notice Minimal Uniswap V3 pool surface needed for the flash-donate trick.
/// @dev We call `flash(this, 0, 0, data)` with zero borrow; in the callback we
///      pay VGC to the pool. The pool credits the paid amount into
///      `feeGrowthGlobal{0|1}X128`, so in-range LPs collect it as if it were
///      swap fees. This is the only V3-native way to distribute tokens to LPs.
interface IUniswapV3Pool {
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;

    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title ValinityBuybackOfficer
 * @notice Closed-circuit, permissionless VY buyback through Valinity DAX.
 * @dev One button — `executeBuyback()` — takes no arguments. Caller pays gas.
 *
 *      Per-call flow (single atomic transaction):
 *        1. Read VY balance held by this contract.
 *        2. If balance < minVyToExecute → revert (BelowMinimum).
 *        3. If block.timestamp < lastExecuteAt + cooldown → revert (Cooldown).
 *        4. From VCO, pick the asset with the largest collateral cap (= the
 *           asset farthest from the effective floor, since the floor is
 *           uniform: max(assetCapFloor, maxCap / capSpreadDivisor)).
 *        5. headroom = cap − effectiveFloor.
 *        6. vyUse    = min(vyBalance, headroom).
 *        7. Send `vyUse` VY to VYT (burned from circulation).
 *        8. withdrawAmount = vyUse × reserve / cap   (exact on-chain LTV).
 *           Pull `withdrawAmount` of `asset` from VRT to this contract.
 *        9. vco.decreaseAssetCap(asset, vyUse)       (exact same amount).
 *       10. dax.swapExactIn(poolId, asset, withdrawAmount, 0, this).
 *           Slippage = 0 is safe — Valinity DAX is private (swap whitelist).
 *       11. Require asset balance == 0 after the swap (closed circuit).
 *       12. Call vryo.execute()                       (same transaction).
 *       13. Record lastExecuteAt = block.timestamp.
 *           The VY bought stays in this contract for the next cycle.
 *
 *      Hard-wired routing (no caller params, no router whitelist):
 *        VRT ── asset ──▶ this ── asset ──▶ Valinity DAX ── VY ──▶ this
 *
 *      VGC Liquidity-Staker Reward (configurable, default 1%, max 5%):
 *        Before the main buyback, `donationBps` of the contract's VY balance
 *        is swapped VY → VGC on Valinity DAX, and the resulting VGC is
 *        donated to the VGC/USDC Uniswap V3 pool via the
 *        `flash(this, 0, 0, data)` trick (paying VGC inside
 *        `uniswapV3FlashCallback` credits in-range LPs via
 *        `feeGrowthGlobal`). The donation step is best-effort: any failure
 *        (VGC token unset, no DAX pool, no V3 in-range liquidity, etc.) is
 *        caught and the main buyback continues with the unchanged VY balance.
 *
 *      Admin-only knobs:
 *        - `cooldown`            : minimum seconds between executions.
 *        - `minVyToExecute`      : minimum VY balance required to fire.
 *        - `donationBps`         : VGC LP donation cut, 0–500 bps (0–5%).
 *        - `setDax`              : update DAX reference (e.g., migration).
 *        - `setVryo`             : update VRYO reference.
 *        - `setPaused`           : kill switch.
 *        - `rescueToken`         : pull tokens stuck due to misconfiguration.
 *      Upgradeable via UUPS, admin-gated.
 */
contract ValinityBuybackOfficer is
    UUPSUpgradeable,
    AccessControl,
    ReentrancyGuardTransient,
    Initializable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLES / CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Hard upper bound on cooldown (24 h) to keep upgrades from
    ///         accidentally bricking the contract via a huge value.
    uint256 public constant MAX_COOLDOWN = 1 days;

    /// @notice Hard upper bound on the VGC liquidity-staker donation cut
    ///         (= 5% of pre-execution VY). The runtime `donationBps` setter
    ///         is gated by ADMIN_ROLE and rejects values above this.
    uint256 public constant MAX_DONATION_BPS = 500;

    /// @notice Default VGC liquidity-staker donation cut applied at init
    ///         (= 1% of pre-execution VY). Admin can change via `setDonationBps`.
    uint256 public constant DEFAULT_DONATION_BPS = 100;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Transient flag set ONLY when this contract initiates a flash on
    ///      `vgcUniV3Pool`. Guards `uniswapV3FlashCallback` against arbitrary
    ///      external pool.flash() calls that target this contract.
    bytes32 private constant _FLASH_ACTIVE_SLOT =
        keccak256("valinity.bbo.flashActive");

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES (upgrade-safe layout)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice VY Token reference
    ValinityToken public vyToken;

    /// @notice VYT — VY sent here is burned from circulation
    ValinityYieldTreasury public vyt;

    /// @notice Reserve Treasury — assets withdrawn from
    ValinityReserveTreasury public vrt;

    /// @notice Cap Officer — chooses the asset & reduces its cap
    ValinityCapOfficer public vco;

    /// @notice Valinity DAX — the ONLY swap venue used by this contract
    IValinityDAX public dax;

    /// @notice Reserve Yield Officer — called at the end of every cycle
    IValinityReserveYieldOfficer public vryo;

    /// @notice Minimum VY balance required to call executeBuyback().
    uint256 public minVyToExecute;

    /// @notice Minimum seconds between successive executions.
    ///         Capped by MAX_COOLDOWN (1 days), fits easily in uint64.
    uint64 public cooldown;

    /// @notice Timestamp of the last successful execution.
    ///         uint64 covers timestamps for the next ~584 billion years.
    uint64 public lastExecuteAt;

    /// @notice Emergency pause flag
    bool public execPaused;
    // cooldown (8) + lastExecuteAt (8) + execPaused (1) = 17 bytes → 1 slot.

    /// @notice VGC token (Valinity Governance Coin). Address(0) disables donations.
    IERC20 public vgcToken;

    /// @notice VGC/USDC (or VGC/X) Uniswap V3 pool that receives donations.
    ///         Address(0) disables donations.
    IUniswapV3Pool public vgcUniV3Pool;

    /// @notice Keeper-reward engine (ValinityGasOfficerV3). Address(0) disables
    ///         keeper refunds — the buyback still works, the caller just eats gas.
    IKeeperRewards public vgo;

    /// @dev Legacy: previously held a per-job identifier. V3.1 keys reward
    ///      config off `msg.sender` on VGO, so this field is unused. Retained
    ///      to preserve storage layout.
    bytes32 private _legacyVgoJobId;

    /// @notice VGC liquidity-staker donation cut, in bps of pre-execution VY.
    ///         Settable by ADMIN_ROLE via `setDonationBps`, capped at
    ///         `MAX_DONATION_BPS` (5%). Defaults to `DEFAULT_DONATION_BPS`
    ///         (1%) at initialize() time. Set to 0 to disable the donation
    ///         step entirely (buyback still uses 100% of VY).
    uint256 public donationBps;

    /// @dev Reserved storage for future upgrades.
    ///      Reduced from 45 to 44 to make room for `donationBps`.
    uint256[44] private __gap;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event MinVyToExecuteUpdated(uint256 newMinVy);
    event CooldownUpdated(uint256 newCooldownSeconds);
    event DonationBpsUpdated(uint256 newDonationBps);
    event DaxUpdated(address indexed newDax);
    event VryoUpdated(address indexed newVryo);
    event VgcTokenUpdated(address indexed newVgcToken);
    event VgcUniV3PoolUpdated(address indexed newVgcUniV3Pool);
    event VgoUpdated(address indexed newVgo);
    event KeeperRewardFailed(bytes reason);
    event Paused(bool execPaused);
    event VgcDonated(uint256 vyIn, uint256 vgcOut);
    event DonationSkipped(uint256 vyAttempted, bytes reason);
    event BuybackExecuted(
        address indexed caller,
        address indexed asset,
        uint256 vyBurned,
        uint256 assetWithdrawn,
        uint256 vyBought,
        uint256 timestamp
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidAddress();
    error InvalidAmount();
    error CooldownNotElapsed(uint256 readyAt);
    error BelowMinimum(uint256 balance, uint256 required);
    error ExecutionPaused();
    error NoHeadroom();
    error NoDaxPool(address asset);
    error TokenBalanceNotZero(address token);
    error CooldownTooLong();
    error DonationBpsTooHigh();
    error UnexpectedFlashCallback();
    error InvalidFlashSender();
    error OnlySelf();
    error DonationNotConfigured();
    error VgcNotInPool();

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZER / UPGRADE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vyTokenAddress,
        address vytAddress,
        address vrtAddress,
        address vcoAddress,
        address daxAddress,
        address vryoAddress,
        uint256 minVyToExecute_,
        uint256 cooldownSeconds_,
        address adminAddress
    ) public initializer {
        if (vyTokenAddress == address(0)) revert InvalidAddress();
        if (vytAddress == address(0)) revert InvalidAddress();
        if (vrtAddress == address(0)) revert InvalidAddress();
        if (vcoAddress == address(0)) revert InvalidAddress();
        if (daxAddress == address(0)) revert InvalidAddress();
        if (vryoAddress == address(0)) revert InvalidAddress();
        if (adminAddress == address(0)) revert InvalidAddress();
        if (cooldownSeconds_ > MAX_COOLDOWN) revert CooldownTooLong();

        vyToken = ValinityToken(vyTokenAddress);
        vyt = ValinityYieldTreasury(vytAddress);
        vrt = ValinityReserveTreasury(vrtAddress);
        vco = ValinityCapOfficer(vcoAddress);
        dax = IValinityDAX(daxAddress);
        vryo = IValinityReserveYieldOfficer(vryoAddress);
        minVyToExecute = minVyToExecute_;
        cooldown = uint64(cooldownSeconds_);
        donationBps = DEFAULT_DONATION_BPS;

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
    }

    /// @dev Only ADMIN_ROLE can push a new implementation through the proxy.
    function _authorizeUpgrade(address)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {}

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW / PREVIEW
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the asset the next buyback would target and the deployable VY.
     * @return bestAsset    Asset with the largest cap on VCO.
     * @return headroom     cap − effectiveFloor for bestAsset (VY units).
     * @return vyUse        min(currentVyBalance, headroom).
     */
    function previewBuyback()
        external
        view
        returns (address bestAsset, uint256 headroom, uint256 vyUse)
    {
        (bestAsset, headroom, ) = _findBestAsset();
        if (bestAsset == address(0) || headroom == 0) {
            return (bestAsset, 0, 0);
        }
        uint256 bal = vyToken.balanceOf(address(this));
        // Mirror on-chain donation step: `donationBps` is consumed before buyback.
        uint256 postDonate;
        unchecked { postDonate = bal - (bal * donationBps) / BPS_DENOMINATOR; }
        vyUse = postDonate < headroom ? postDonate : headroom;
    }

    /// @notice Timestamp at which the next execution becomes eligible.
    function nextExecuteAt() external view returns (uint256) {
        return uint256(lastExecuteAt) + uint256(cooldown);
    }

    /**
     * @dev Asset with the largest collateral cap on VCO. Since the effective
     *      floor is uniform — max(assetCapFloor, maxCap / capSpreadDivisor) —
     *      "largest cap" is equivalent to "largest headroom".
     */
    function _findBestAsset()
        internal
        view
        returns (address bestAsset, uint256 bestHeadroom, uint256 bestCap)
    {
        ValinityCapOfficer _vco = vco;
        address[] memory assets_ = _vco.getAssets();
        uint256 floor = _vco.effectiveFloor();
        uint256 len = assets_.length;
        for (uint256 i; i < len; ) {
            address a = assets_[i];
            uint256 c = _vco.getAssetCap(a);
            if (c > floor) {
                uint256 h;
                unchecked { h = c - floor; }
                if (h > bestHeadroom) {
                    bestHeadroom = h;
                    bestAsset = a;
                    bestCap = c;
                }
            }
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN BUYBACK FUNCTION — PERMISSIONLESS, NO ARGS, CLOSED CIRCUIT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Execute one buyback cycle. Anyone can call. Caller pays gas.
    /// @dev    Brackets the work with `vgo.beginReward()` and
    ///         `vgo.payReward(msg.sender)`: VGO measures the actual gas
    ///         consumed itself (transient storage + `tx.gasprice`) and
    ///         refunds the keeper in ETH plus a flat admin-configured
    ///         bonus. `payReward` is wrapped in try/catch so a paused/
    ///         empty/buggy VGO never bricks the buyback. `beginReward` is
    ///         NOT wrapped: if VGO is mis-set the buyback fails fast at
    ///         the gate, which is the correct behavior.
    function executeBuyback() external nonReentrant {
        // ---- 0. Gates ----
        if (execPaused) revert ExecutionPaused();

        // Snapshot gas in VGO BEFORE any work. If VGO is unset, skip.
        IKeeperRewards _vgo = vgo;
        if (address(_vgo) != address(0)) {
            _vgo.beginReward();
        }

        uint256 _last = lastExecuteAt;
        uint256 _cooldown = cooldown;
        if (_last != 0 && block.timestamp < _last + _cooldown) {
            revert CooldownNotElapsed(_last + _cooldown);
        }
        // Cache state references once (saves ~5 warm SLOADs).
        ValinityToken _vyToken = vyToken;
        ValinityYieldTreasury _vyt = vyt;
        ValinityReserveTreasury _vrt = vrt;
        ValinityCapOfficer _vco = vco;

        uint256 vyBal = _vyToken.balanceOf(address(this));
        uint256 _minVy = minVyToExecute;
        if (vyBal < _minVy) revert BelowMinimum(vyBal, _minVy);

        // ---- 1. Donate `donationBps` of pre-execution VY to VGC/USDC Uni V3 LPs ----
        //         Best-effort: any failure is absorbed, buyback continues
        //         with whatever VY remains in the contract.
        uint256 donateVy = (vyBal * donationBps) / BPS_DENOMINATOR;
        if (donateVy > 0) {
            try this.__donateVGCStep(donateVy) {
                // Success: VY balance dropped by donateVy. Re-read.
                vyBal = _vyToken.balanceOf(address(this));
            } catch (bytes memory reason) {
                emit DonationSkipped(donateVy, reason);
                // No state change — vyBal still valid, continue with 100%.
            }
        }

        // ---- 2. Pick asset with largest cap (farthest from floor) ----
        (address asset, uint256 headroom, uint256 cap) = _findBestAsset();
        if (asset == address(0) || headroom == 0) revert NoHeadroom();

        // ---- 3. Size the cycle: clamp VY to the headroom ----
        uint256 vyUse = vyBal < headroom ? vyBal : headroom;
        if (vyUse == 0) revert InvalidAmount();

        // ---- 4. Compute exact LTV withdrawal & snapshot pre-asset balance ----
        if (cap == 0) revert InvalidAmount();
        uint256 reserve = IERC20(asset).balanceOf(address(_vrt));
        uint256 withdrawAmount = (vyUse * reserve) / cap;
        if (withdrawAmount == 0) revert InvalidAmount();
        uint256 preAssetBal = IERC20(asset).balanceOf(address(this));

        // ---- 5. Burn vyUse to VYT ----
        IERC20(address(_vyToken)).safeTransfer(address(_vyt), vyUse);

        // ---- 6. Withdraw asset from VRT ----
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = asset;
        amounts[0] = withdrawAmount;
        _vrt.withdrawForBuyback(assets, amounts, address(this));

        // ---- 7. Decrease cap on VCO by exactly vyUse ----
        _vco.decreaseAssetCap(asset, vyUse);

        // ---- 8. Swap asset -> VY on Valinity DAX (the ONLY venue) ----
        uint256 vyBought = _swapAssetForVY(asset, withdrawAmount);

        // ---- 9. Closed-circuit invariant: no NEW residual asset ----
        //         Compare against pre-swap balance (delta semantics) so a
        //         griefer pre-dusting the contract cannot DoS the buyback.
        if (IERC20(asset).balanceOf(address(this)) > preAssetBal) {
            revert TokenBalanceNotZero(asset);
        }

        // ---- 10. Trigger VRYO rebalance in the same transaction ----
        vryo.execute();

        // ---- 11. Stamp the cooldown ----
        lastExecuteAt = uint64(block.timestamp);

        emit BuybackExecuted(
            msg.sender,
            asset,
            vyUse,
            withdrawAmount,
            vyBought,
            block.timestamp
        );

        // ---- 12. Keeper reward (best-effort, never blocks the buyback) ----
        if (address(_vgo) != address(0)) {
            try _vgo.payReward(msg.sender) {
                // paid — keeper got gas refund + flat bonus
            } catch (bytes memory reason) {
                emit KeeperRewardFailed(reason);
            }
        }
    }

    /**
     * @dev Swap `amountIn` of `asset` for VY on the asset's Valinity DAX pool.
     *      `minAmountOut = 0`: Valinity DAX is permissioned via
     *      `swapWhitelist`, so no external trader can sandwich us — slippage
     *      is purely the deterministic constant-product price move caused
     *      by this exact trade.
     */
    function _swapAssetForVY(address asset, uint256 amountIn)
        internal
        returns (uint256 vyOut)
    {
        IValinityDAX _dax = dax;
        IValinityDAXLookup _lookup = IValinityDAXLookup(address(_dax));

        if (!_lookup.hasPool(asset)) revert NoDaxPool(asset);
        uint256 poolId = _lookup.assetToPoolId(asset);

        IERC20(asset).forceApprove(address(_dax), amountIn);
        vyOut = _dax.swapExactIn(poolId, asset, amountIn, 0, address(this));
    }

    // ══════════════════════════════════════════════════════════════════════════════════
    // VGC DONATION (best-effort, self-callable, NOT nonReentrant)
    // ═════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Swap `vyAmount` VY → VGC on the Valinity DAX, then donate the
     *         resulting VGC to `vgcUniV3Pool` via a zero-borrow flash call.
     * @dev    External + self-only so it can be wrapped in `try/catch` from
     *         `executeBuyback()`. NOT `nonReentrant` to avoid tripping the
     *         transient reentrancy guard during the self-call. Safe because
     *         (a) only the contract can call it, and (b) the flash callback
     *         is guarded by both `msg.sender` and a transient flag.
     */
    function __donateVGCStep(uint256 vyAmount) external {
        if (msg.sender != address(this)) revert OnlySelf();

        IERC20 _vgc = vgcToken;
        IUniswapV3Pool _pool = vgcUniV3Pool;
        if (address(_vgc) == address(0) || address(_pool) == address(0)) {
            revert DonationNotConfigured();
        }
        if (vyAmount == 0) revert InvalidAmount();

        // ---- 1. VY → VGC on Valinity DAX ----
        IValinityDAX _dax = dax;
        IValinityDAXLookup _lookup = IValinityDAXLookup(address(_dax));
        if (!_lookup.hasPool(address(_vgc))) revert NoDaxPool(address(_vgc));
        uint256 poolId = _lookup.assetToPoolId(address(_vgc));

        uint256 vgcBefore = _vgc.balanceOf(address(this));
        IERC20(address(vyToken)).forceApprove(address(_dax), vyAmount);
        _dax.swapExactIn(
            poolId,
            address(vyToken),
            vyAmount,
            0,
            address(this)
        );
        uint256 vgcOut = _vgc.balanceOf(address(this)) - vgcBefore;
        if (vgcOut == 0) revert InvalidAmount();

        // ---- 2. Sanity: VGC must actually be one side of the pool ----
        address t0 = _pool.token0();
        address t1 = _pool.token1();
        if (t0 != address(_vgc) && t1 != address(_vgc)) revert VgcNotInPool();

        // ---- 3. Flash with amount0=amount1=0 — we pay VGC in callback.
        //         Pool credits paid amount into feeGrowthGlobal of VGC side,
        //         distributing to in-range LPs (reverts if liquidity == 0).
        bytes32 slot = _FLASH_ACTIVE_SLOT;
        assembly { tstore(slot, 1) }
        _pool.flash(address(this), 0, 0, abi.encode(vgcOut));
        assembly { tstore(slot, 0) }

        emit VgcDonated(vyAmount, vgcOut);
    }

    /**
     * @notice Uniswap V3 flash callback. Pays the donation amount of VGC
     *         to the pool. The pool's accounting then distributes it to
     *         in-range LPs via `feeGrowthGlobal{0|1}X128`.
     */
    function uniswapV3FlashCallback(
        uint256 /* fee0 */,
        uint256 /* fee1 */,
        bytes calldata data
    ) external {
        bytes32 slot = _FLASH_ACTIVE_SLOT;
        uint256 active;
        assembly { active := tload(slot) }
        if (active == 0) revert UnexpectedFlashCallback();
        if (msg.sender != address(vgcUniV3Pool)) revert InvalidFlashSender();

        uint256 amount = abi.decode(data, (uint256));
        IERC20(address(vgcToken)).safeTransfer(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Set the minimum VY balance required to call executeBuyback().
    function setMinVyToExecute(uint256 newMinVy)
        external
        onlyRole(ADMIN_ROLE)
    {
        minVyToExecute = newMinVy;
        emit MinVyToExecuteUpdated(newMinVy);
    }

    /// @notice Set the cooldown (seconds) between successive executions.
    function setCooldown(uint256 newCooldownSeconds)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (newCooldownSeconds > MAX_COOLDOWN) revert CooldownTooLong();
        cooldown = uint64(newCooldownSeconds);
        emit CooldownUpdated(newCooldownSeconds);
    }

    /// @notice Set the VGC liquidity-staker donation cut in bps.
    ///         Capped at MAX_DONATION_BPS (= 5%). Set to 0 to disable the
    ///         donation step entirely (buyback uses 100% of VY).
    function setDonationBps(uint256 newDonationBps)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (newDonationBps > MAX_DONATION_BPS) revert DonationBpsTooHigh();
        donationBps = newDonationBps;
        emit DonationBpsUpdated(newDonationBps);
    }

    function setDax(address newDax) external onlyRole(ADMIN_ROLE) {
        if (newDax == address(0)) revert InvalidAddress();
        dax = IValinityDAX(newDax);
        emit DaxUpdated(newDax);
    }

    function setVryo(address newVryo) external onlyRole(ADMIN_ROLE) {
        if (newVryo == address(0)) revert InvalidAddress();
        vryo = IValinityReserveYieldOfficer(newVryo);
        emit VryoUpdated(newVryo);
    }

    /// @notice Set the VGC token. Pass address(0) to disable donations.
    function setVgcToken(address newVgcToken) external onlyRole(ADMIN_ROLE) {
        vgcToken = IERC20(newVgcToken);
        emit VgcTokenUpdated(newVgcToken);
    }

    /// @notice Set the VGC/USDC Uniswap V3 pool. Pass address(0) to disable.
    function setVgcUniV3Pool(address newPool) external onlyRole(ADMIN_ROLE) {
        vgcUniV3Pool = IUniswapV3Pool(newPool);
        emit VgcUniV3PoolUpdated(newPool);
    }

    /// @notice Configure the keeper-reward engine. Pass `newVgo = address(0)`
    ///         to disable keeper refunds (buyback still works, caller eats gas).
    function setVgo(address newVgo) external onlyRole(ADMIN_ROLE) {
        vgo = IKeeperRewards(newVgo);
        emit VgoUpdated(newVgo);
    }

    function setPaused(bool paused) external onlyRole(ADMIN_ROLE) {
        execPaused = paused;
        emit Paused(paused);
    }

    /**
     * @notice Admin rescue for tokens stranded in the contract.
     * @dev The buyback path itself never leaves residual assets (closed
     *      circuit + invariant check). This exists for misconfiguration
     *      (e.g., wrong DAX, paused state, or stray transfers).
     */
    function rescueToken(address token, address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        // VY must never leave this contract via admin path — it is
        // reserved for the next buyback cycle (sent to VYT only).
        if (token == address(vyToken)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
    }
}
