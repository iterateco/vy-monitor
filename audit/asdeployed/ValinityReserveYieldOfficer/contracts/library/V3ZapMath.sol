// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title V3ZapMath
 * @notice Closed-form zap split + min-out helpers shared by VLM and VRYO so
 *         both contracts agree on swap sizing and slippage bounds. Kept as a
 *         pure library to avoid duplicating the same logic in two large
 *         contracts (helps with the 24576-byte deploy limit).
 */
library V3ZapMath {
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Closed-form optimal V3 single-sided zap split at current price.
    /// @dev a = sqrtP, b = sqrtPU, c = sqrtPL (Q64.96).
    ///        num = b·(a−c)/Q96,  lhs = a·(b−a)/Q96,  den = num+lhs
    ///        deposit token0 → swap = amountIn · num / den
    ///        deposit token1 → swap = amountIn · lhs / den
    function computeSwapAmount(
        uint256 amountIn,
        bool tokenInIsToken0,
        uint160 sqrtP,
        uint160 sqrtPL,
        uint160 sqrtPU
    ) internal pure returns (uint256) {
        if (amountIn == 0) return 0;
        if (sqrtP <= sqrtPL) return tokenInIsToken0 ? 0 : amountIn;
        if (sqrtP >= sqrtPU) return tokenInIsToken0 ? amountIn : 0;

        uint256 a = uint256(sqrtP);
        uint256 b = uint256(sqrtPU);
        uint256 c = uint256(sqrtPL);

        uint256 num = Math.mulDiv(b, a - c, Q96);
        uint256 lhs = Math.mulDiv(a, b - a, Q96);
        uint256 den = num + lhs;
        if (den == 0) return amountIn / 2;

        return tokenInIsToken0
            ? Math.mulDiv(amountIn, num, den)
            : Math.mulDiv(amountIn, lhs, den);
    }

    /// @notice Expected exactIn output at sqrtP, minus pool fee, minus
    ///         caller-supplied slippage tolerance in bps. Mirrors the
    ///         conservative bound used by both VLM and VRYO.
    function computeMinOut(
        uint256 amountIn,
        bool tokenInIsToken0,
        uint160 sqrtP,
        uint24 fee,
        uint16 slippageBps
    ) internal pure returns (uint256) {
        uint256 expected;
        if (tokenInIsToken0) {
            uint256 tmp = Math.mulDiv(amountIn, uint256(sqrtP), Q96);
            expected = Math.mulDiv(tmp, uint256(sqrtP), Q96);
        } else {
            uint256 tmp = Math.mulDiv(amountIn, Q96, uint256(sqrtP));
            expected = Math.mulDiv(tmp, Q96, uint256(sqrtP));
        }
        uint256 afterFee = (expected * (1_000_000 - uint256(fee))) / 1_000_000;
        return (afterFee * (BPS_DENOMINATOR - uint256(slippageBps))) / BPS_DENOMINATOR;
    }

    /// @notice Closed-form rebalance zap: given an existing (bal0, bal1) on
    ///         the caller, compute the SINGLE swap (direction + amount in
    ///         native units of the source token) needed so the remaining
    ///         balances match the value split required by a V3 mint over
    ///         [sqrtPL, sqrtPU] at current `sqrtP`.
    /// @dev Never swaps both sides. Never converts 100% unless the new
    ///      range is entirely on one side of price (out-of-range cases).
    /// @return zeroForOne `true` → swap token0 → token1; `false` → token1 → token0.
    /// @return swapAmt    Native-unit amount of the source token to swap.
    function computeRebalanceSwap(
        uint256 bal0,
        uint256 bal1,
        uint160 sqrtP,
        uint160 sqrtPL,
        uint160 sqrtPU
    ) internal pure returns (bool zeroForOne, uint256 swapAmt) {
        // Out-of-range cases: range fully above (need only token0) or below
        // (need only token1) current price → swap the entire opposite side.
        if (sqrtP <= sqrtPL) return (false, bal1);
        if (sqrtP >= sqrtPU) return (true,  bal0);

        uint256 a = uint256(sqrtP);
        uint256 num = Math.mulDiv(uint256(sqrtPU), a - uint256(sqrtPL), Q96);
        uint256 lhs = Math.mulDiv(a, uint256(sqrtPU) - a, Q96);
        uint256 den = num + lhs;
        if (den == 0) return (false, 0);

        // Work in token0-value space. v1AsT0 = bal1 / price = bal1·Q96²/sqrtP².
        uint256 v1AsT0 = Math.mulDiv(Math.mulDiv(bal1, Q96, a), Q96, a);
        uint256 totalV = bal0 + v1AsT0;
        if (totalV == 0) return (false, 0);

        uint256 target0 = Math.mulDiv(totalV, lhs, den);
        if (bal0 > target0) return (true, bal0 - target0);
        if (bal0 < target0) {
            // Convert deficit (token0 value) → token1 native: ·price.
            uint256 s = Math.mulDiv(Math.mulDiv(target0 - bal0, a, Q96), a, Q96);
            return (false, s > bal1 ? bal1 : s);
        }
        return (false, 0);
    }
}
