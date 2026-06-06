// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMathWrapper as TickMath} from "./TickMathWrapper.sol";
import {V3LiquidityMath} from "./V3LiquidityMath.sol";
import {V3PositionValue} from "./V3PositionValue.sol";

interface IV3Pool {
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IV3NPM {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96, address, address, address, uint24,
            int24, int24, uint128, uint256, uint256, uint128, uint128
        );
}

/**
 * @title V3SnapbackGate
 * @notice External library deployed once and DELEGATECALLed by VLM to keep
 *         the VLM implementation bytecode under the 24 KiB Spurious-Dragon
 *         limit. All inputs are passed explicitly so the library shares no
 *         storage with the caller — safe to upgrade VLM without touching
 *         this library.
 *
 *         Math:
 *           Y = (fee0 + fee1) normalized to managed reserve at TWAP price
 *           S ≈ |v0_mgd − v1_mgd| / 2     // half the LP value-imbalance at TWAP
 *           C = S × (poolFeeBps + zapSlippageBps) / 10_000
 *           allow = !inRange || nearBand || (Y ≥ C)
 *
 *         The S approximation is exact when the new range is centered on
 *         TWAP price (the snapback default), where the optimal V3 zap
 *         collapses to a 50/50-by-value rebalance.
 */
library V3SnapbackGate {
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant Q96 = 1 << 96;

    error TwapDeviation(int24 spotTick, int24 twapTick);

    /// @notice Revert if pool spot has drifted from TWAP by more than
    ///         `maxTickDeviationBps`. `maxTickDeviationBps == 0` disables
    ///         the guard. 1 tick ≈ 1 bp of price so we compare |Δtick|
    ///         directly to the bps threshold.
    function assertTwapAligned(
        address pool,
        uint32 twapInterval,
        uint16 maxTickDeviationBps
    ) external view {
        if (maxTickDeviationBps == 0) return;
        (, int24 spotTick, , , , , ) = IV3Pool(pool).slot0();
        int24 twap = _twapTick(pool, twapInterval);
        int24 diff = spotTick > twap ? spotTick - twap : twap - spotTick;
        if (uint256(uint24(diff)) > uint256(maxTickDeviationBps)) {
            revert TwapDeviation(spotTick, twap);
        }
    }

    struct Inputs {
        address npm;
        address pool;
        uint256 tokenId;
        bool    managedIsT0;     // true if managed reserve is token0 OR pair is dual-managed
        uint24  poolFee;         // pool fee in 1e-6 (500 = 0.05%)
        uint16  zapSlippageBps;
        uint16  nearBandBps;
        uint32  twapInterval;
    }

    /// @notice Compute eligibility for a snapback re-center.
    /// @dev Reads pool TWAP + position state via the passed addresses. No
    ///      storage access on the calling contract. `tokenId == 0` short-
    ///      circuits to "not eligible" so the caller can pass a missing
    ///      position without reverting.
    function check(Inputs memory i)
        external
        view
        returns (bool allow, uint256 yieldMgd, uint256 costMgd, bool nearBand, bool inRange)
    {
        if (i.tokenId == 0) return (false, 0, 0, false, false);

        int24 twapTick = _twapTick(i.pool, i.twapInterval);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(twapTick);

        // Single positions() read — reuse for both fee compute and the
        // liquidity-imbalance compute below (saves ~3k gas vs the
        // `V3PositionValue.fees(npm, pool, tokenId)` overload that
        // re-reads positions internally).
        (
            , , , , ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 fgInside0LastX128,
            uint256 fgInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = IV3NPM(i.npm).positions(i.tokenId);

        inRange = (twapTick >= tickLower && twapTick <= tickUpper);
        if (inRange) {
            int24 dLower = twapTick - tickLower;
            int24 dUpper = tickUpper - twapTick;
            int24 dist   = dLower < dUpper ? dLower : dUpper;
            int24 halfW  = (tickUpper - tickLower) / 2;
            if (i.nearBandBps != 0 && halfW > 0) {
                int24 tol = int24(int256(
                    (uint256(uint24(halfW)) * uint256(i.nearBandBps)) / BPS_DENOMINATOR
                ));
                nearBand = dist <= tol;
            }
        }

        // Y: pending fees in managed units (uses pre-read params).
        (uint256 fee0, uint256 fee1) = V3PositionValue.feesFromParams(
            i.pool,
            liquidity,
            tickLower,
            tickUpper,
            fgInside0LastX128,
            fgInside1LastX128,
            tokensOwed0,
            tokensOwed1
        );
        yieldMgd = _toManaged(i.managedIsT0, fee0, fee1, sqrtP);

        // S: half LP-value imbalance at TWAP price.
        (uint256 bal0, uint256 bal1) = V3LiquidityMath.getAmountsForLiquidity(
            sqrtP,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
        uint256 v0Mgd = _toManaged(i.managedIsT0, bal0 + fee0, 0,           sqrtP);
        uint256 v1Mgd = _toManaged(i.managedIsT0, 0,           bal1 + fee1, sqrtP);
        uint256 sMgd  = (v0Mgd > v1Mgd ? v0Mgd - v1Mgd : v1Mgd - v0Mgd) / 2;

        // C = S × (poolFeeBps + zapSlippageBps) / 10_000.
        uint256 costBps = (uint256(i.poolFee) / 100) + uint256(i.zapSlippageBps);
        costMgd = (sMgd * costBps) / BPS_DENOMINATOR;

        allow = (!inRange) || nearBand || (yieldMgd >= costMgd);
    }

    function _twapTick(address pool, uint32 secondsAgo) private view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;
        (int56[] memory cums, ) = IV3Pool(pool).observe(secondsAgos);
        int56 delta = cums[1] - cums[0];
        int24 avg = int24(delta / int56(uint56(secondsAgo)));
        if (delta < 0 && (delta % int56(uint56(secondsAgo)) != 0)) avg--;
        return avg;
    }

    /// @dev Convert (a0, a1) to managed-reserve units at the given sqrtP.
    ///      `managedIsT0 == true` covers both single-managed (managed ==
    ///      token0) and dual-managed pairs (normalized to token0).
    function _toManaged(bool managedIsT0, uint256 a0, uint256 a1, uint160 sqrtP)
        private
        pure
        returns (uint256)
    {
        if (managedIsT0) {
            uint256 tmp = Math.mulDiv(a1, Q96, uint256(sqrtP));
            uint256 a1InT0 = Math.mulDiv(tmp, Q96, uint256(sqrtP));
            return a0 + a1InT0;
        } else {
            uint256 tmp = Math.mulDiv(a0, uint256(sqrtP), Q96);
            uint256 a0InT1 = Math.mulDiv(tmp, uint256(sqrtP), Q96);
            return a1 + a0InT1;
        }
    }
}
