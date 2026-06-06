// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// VAROReferralSettleLib
// ─────────────────────────────────────────────────────────────────────────────
//
// DELEGATECALL-linked library for VARO. It holds the heavy per-referee
// crediting engine (the PULL settle path shared by `settleMine` and the keeper
// `sweep`) PLUS the V-DAO buy/split/donate helpers (shared by the launch split,
// the claim payout, and partner registration) so that bytecode lives at the
// library's own address instead of counting against VARO's EIP-170 limit. The
// library has NO storage of its own — every function operates on VARO's storage
// via storage-reference params, so VARO's storage layout is untouched. Because
// the link is a DELEGATECALL, `address(this)` inside these functions is VARO, so
// token approvals/swaps/transfers all act with VARO's balances + allowances.
//
// Both settle entrypoints run the SAME `_settleOne` checkpoint logic, so
// crediting stays idempotent: each `(referee, source)` fee is credited exactly
// once regardless of whether the referrer's `settleMine` or a keeper `sweep`
// processes it first. Neither path pays a referrer — payout stays in VARO's
// `claimMine`. `_credit` returns the cut and the public functions return the
// summed `credited`; VARO folds that into `globalCreditedVY` after the call.
// ─────────────────────────────────────────────────────────────────────────────

interface IVEO_L { function cumulativeUserFeeVY(address user) external view returns (uint256); }
interface IVLO_L { function cumulativeInterestPaidVY(address borrower) external view returns (uint256); }
interface IVYO_L { function totalYieldClaimedVY(address user) external view returns (uint256); }

interface IDAX_L {
    function swapExactIn(uint256 poolId, address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external returns (uint256 amountOut);
    function assetToPoolId(address asset) external view returns (uint256);
    function hasPool(address asset) external view returns (bool);
}
interface IVDAODAX_L { function donate(uint256 poolId, address token, uint256 amount) external; }

library VAROReferralSettleLib {
    using SafeERC20 for IERC20;
    // Mirrors VARO's source IDs + bps denominator (kept in sync by value).
    uint8  internal constant SRC_VEO_TRADING  = 1;
    uint8  internal constant SRC_VLO_INTEREST = 2;
    uint8  internal constant SRC_VYO_YIELD    = 5;
    uint16 internal constant BPS_DENOMINATOR  = 10_000;

    /// @dev Mirrors VARO's `Credited`. Same name+args ⇒ same topic0, so the log
    ///      (emitted under VARO's address via DELEGATECALL) is indistinguishable
    ///      from one VARO emits directly (e.g. the VPO push path).
    event Credited(
        address indexed referrer,
        address indexed referree,
        uint8 indexed sourceId,
        uint256 vyDelta,
        uint256 vyCredited
    );

    error SweepBatchTooSmall();
    error PoolNotFound();

    /// @dev Snapshot of VARO's bps schedule + source officer addresses, built by
    ///      VARO from its own storage and passed by value each call. Only the
    ///      three PULL sources live here — the VPO HL-builder source is push-only
    ///      (credited directly in VARO.notifyReferrerPerpCredit) and is never
    ///      settled on this path, so its bps are intentionally omitted.
    struct Cfg {
        address veo;
        address vlo;
        address vyo;
        uint16 veoBps;   uint16 vloBps;   uint16 vyoBps;    // STANDARD (T2/T3)
        uint16 veoBpsV;  uint16 vloBpsV;  uint16 vyoBpsV;   // VDAO (T4)
    }

    function _bps(uint8 t, Cfg memory cfg, uint8 src) private pure returns (uint16) {
        if (t < 2) return 0;
        bool v = t >= 4;
        if (src == SRC_VEO_TRADING)  return v ? cfg.veoBpsV  : cfg.veoBps;
        if (src == SRC_VLO_INTEREST) return v ? cfg.vloBpsV  : cfg.vloBps;
        if (src == SRC_VYO_YIELD)    return v ? cfg.vyoBpsV  : cfg.vyoBps;
        return 0; // unreachable on the PULL path (only the 3 sources above settle here)
    }

    function _credit(
        mapping(address => uint256) storage pendingVY,
        uint8 refTier,
        Cfg memory cfg,
        address referrer,
        address referree,
        uint8 src,
        uint256 delta
    ) private returns (uint256 cut) {
        if (delta == 0) return 0;
        uint16 bps = _bps(refTier, cfg, src);
        if (bps == 0) return 0;
        cut = (delta * bps) / BPS_DENOMINATOR;
        if (cut == 0) return 0;
        pendingVY[referrer] += cut;
        emit Credited(referrer, referree, src, delta, cut);
    }

    /// @dev Pull VEO/VLO/VYO deltas for one referee and credit its referrer.
    ///      Mirrors VARO's former `_settleOne`: when the referrer just crossed
    ///      a tier boundary (`needsReset`), baseline checkpoints to "now" with
    ///      zero credit (forward-only earning). Returns VY credited.
    function _settleOne(
        mapping(address => address) storage referredBy,
        mapping(address => bool) storage needsReset,
        mapping(address => mapping(uint8 => uint256)) storage checkpoints,
        mapping(address => uint256) storage pendingVY,
        mapping(address => uint8) storage tier,
        Cfg memory cfg,
        address referree
    ) private returns (uint256 credited) {
        address ref = referredBy[referree];
        if (ref == address(0)) return 0;

        if (needsReset[ref]) {
            checkpoints[referree][SRC_VEO_TRADING]  = IVEO_L(cfg.veo).cumulativeUserFeeVY(referree);
            checkpoints[referree][SRC_VLO_INTEREST] = IVLO_L(cfg.vlo).cumulativeInterestPaidVY(referree);
            checkpoints[referree][SRC_VYO_YIELD]    = IVYO_L(cfg.vyo).totalYieldClaimedVY(referree);
            return 0;
        }

        uint8 t = tier[ref];

        uint256 nowCum = IVEO_L(cfg.veo).cumulativeUserFeeVY(referree);
        uint256 lastCum = checkpoints[referree][SRC_VEO_TRADING];
        if (nowCum > lastCum) {
            checkpoints[referree][SRC_VEO_TRADING] = nowCum;
            credited += _credit(pendingVY, t, cfg, ref, referree, SRC_VEO_TRADING, nowCum - lastCum);
        }

        nowCum = IVLO_L(cfg.vlo).cumulativeInterestPaidVY(referree);
        lastCum = checkpoints[referree][SRC_VLO_INTEREST];
        if (nowCum > lastCum) {
            checkpoints[referree][SRC_VLO_INTEREST] = nowCum;
            credited += _credit(pendingVY, t, cfg, ref, referree, SRC_VLO_INTEREST, nowCum - lastCum);
        }

        nowCum = IVYO_L(cfg.vyo).totalYieldClaimedVY(referree);
        lastCum = checkpoints[referree][SRC_VYO_YIELD];
        if (nowCum > lastCum) {
            checkpoints[referree][SRC_VYO_YIELD] = nowCum;
            credited += _credit(pendingVY, t, cfg, ref, referree, SRC_VYO_YIELD, nowCum - lastCum);
        }
    }

    /// @notice `settleMine` engine: walk one referrer's own subtree from `start`,
    ///         up to `maxPerCall` referees.
    /// @return newCursor 0 when the full subtree is covered, else the next index.
    /// @return credited  Total VY credited this call (VARO adds to globalCreditedVY).
    /// @return finished  True when the subtree is fully walked this call.
    function settleSubtree(
        mapping(address => address) storage referredBy,
        mapping(address => bool) storage needsReset,
        mapping(address => mapping(uint8 => uint256)) storage checkpoints,
        mapping(address => uint256) storage pendingVY,
        mapping(address => uint8) storage tier,
        address[] storage subtree,
        Cfg memory cfg,
        uint256 start,
        uint256 maxPerCall
    ) public returns (uint256 newCursor, uint256 credited, bool finished) {
        uint256 n = subtree.length;
        if (start >= n) return (0, 0, true); // empty or already complete

        uint256 end = start + maxPerCall;
        if (end > n) end = n;

        // `end <= n = subtree.length`, so `i` cannot overflow → unchecked bump.
        for (uint256 i = start; i < end; ) {
            credited += _settleOne(referredBy, needsReset, checkpoints, pendingVY, tier, cfg, subtree[i]);
            unchecked { ++i; }
        }

        if (end == n) { newCursor = 0; finished = true; }
        else          { newCursor = end; finished = false; }
    }

    /// @notice Keeper `sweep` engine: walk the GLOBAL referee list from `cursor`,
    ///         up to `count` referees. Referees whose referrer is mid-tier-upgrade
    ///         (`needsReset`) are SKIPPED — that referrer's own `settleMine` owns
    ///         the forward-only baseline and is what clears the flag. A call must
    ///         cover >= `minBatch` referees unless it completes the lap (anti-farm).
    /// @return newCursor 0 when the lap completes, else the next index.
    /// @return credited  Total VY credited this call (VARO adds to globalCreditedVY).
    /// @return finished  True when this call completes the lap.
    function sweepRange(
        mapping(address => address) storage referredBy,
        mapping(address => bool) storage needsReset,
        mapping(address => mapping(uint8 => uint256)) storage checkpoints,
        mapping(address => uint256) storage pendingVY,
        mapping(address => uint8) storage tier,
        address[] storage allRefs,
        Cfg memory cfg,
        uint256 cursor,
        uint256 count,
        uint256 minBatch
    ) public returns (uint256 newCursor, uint256 credited, bool finished) {
        uint256 n = allRefs.length;                 // caller guarantees n > 0 and cursor < n
        uint256 remaining = n - cursor;
        uint256 take = count < remaining ? count : remaining;
        uint256 end = cursor + take;
        finished = end == n;
        if (take < minBatch && !finished) revert SweepBatchTooSmall();

        // `end <= n = allRefs.length`, so `i` cannot overflow → unchecked bump.
        for (uint256 i = cursor; i < end; ) {
            address referree = allRefs[i];
            address ref = referredBy[referree];
            unchecked { ++i; }
            if (ref == address(0)) continue;
            if (needsReset[ref]) continue;          // skip — owner's settleMine owns the baseline
            credited += _settleOne(referredBy, needsReset, checkpoints, pendingVY, tier, cfg, referree);
        }

        newCursor = finished ? 0 : end;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // V-DAO BUY / SPLIT / DONATE (shared by launch split, claim, partner)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Mirrors VARO's `VDAODonated` (same name+args ⇒ same topic0), emitted
    ///      under VARO's address via DELEGATECALL.
    event VDAODonated(address indexed vdao, address indexed vdaoDax, uint256 amount);

    /// @notice Buy `vdaoToken` with `vyAmount` VY on its main-VDAX VY/V-DAO pool,
    ///         returning the amount received (balance delta; VARO is fee-exempt on
    ///         every V-DAO so it receives the gross output). VY is pre-approved to
    ///         the VDAX by VARO at init.
    function buyVdaoWithVy(
        address vdax,
        address vy,
        address vdaoToken,
        uint256 vyAmount,
        uint256 minOut
    ) public returns (uint256 received) {
        // Resolve the VY/V-DAO pool id LIVE (ids are re-indexed on removal); the
        // hasPool guard disambiguates the valid pool-id-0 case from "not listed".
        if (!IDAX_L(vdax).hasPool(vdaoToken)) revert PoolNotFound();
        uint256 poolId = IDAX_L(vdax).assetToPoolId(vdaoToken);
        uint256 bal0 = IERC20(vdaoToken).balanceOf(address(this));
        IDAX_L(vdax).swapExactIn(poolId, vy, vyAmount, minOut, address(this));
        received = IERC20(vdaoToken).balanceOf(address(this)) - bal0;
    }

    /// @notice Donate `amount` of a V-DAO into its second leg on the VDAO DAX.
    ///         The V-DAO was max-approved to the VDAO DAX at its launch, so no
    ///         per-call approval is needed.
    function donateToVdaoDax(
        address vdaoDax,
        mapping(address => uint256) storage secondPoolId,
        address vdaoToken,
        uint256 amount
    ) public {
        if (amount == 0) return;
        IVDAODAX_L(vdaoDax).donate(secondPoolId[vdaoToken], vdaoToken, amount);
        emit VDAODonated(vdaoToken, vdaoDax, amount);
    }

    /// @notice Buy `vdaoToken` with VY, then either donate 100% to its VDAO DAX
    ///         leg (`donateAll`, e.g. VGC) or split 50% to `beneficiary` (in the
    ///         token) + 50% donated. Shared by the claim payout and partner buy-in.
    function buyAndSplit(
        address vdax,
        address vdaoDax,
        address vy,
        mapping(address => uint256) storage secondPoolId,
        address vdaoToken,
        uint256 vyAmount,
        uint256 minOut,
        address beneficiary,
        bool    donateAll
    ) public {
        uint256 got = buyVdaoWithVy(vdax, vy, vdaoToken, vyAmount, minOut);
        if (donateAll) {
            donateToVdaoDax(vdaoDax, secondPoolId, vdaoToken, got);
        } else {
            uint256 toBen = got / 2;
            if (toBen != 0) IERC20(vdaoToken).safeTransfer(beneficiary, toBen);
            donateToVdaoDax(vdaoDax, secondPoolId, vdaoToken, got - toBen);
        }
    }
}
