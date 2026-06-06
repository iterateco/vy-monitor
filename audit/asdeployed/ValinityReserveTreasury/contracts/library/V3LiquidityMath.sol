// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title V3LiquidityMath
 * @notice 0.8.27 port of Uniswap V3 periphery `LiquidityAmounts` (MIT).
 *         Used by VLM (refreshSnapshot principals) and VRT (post-decrease recompute).
 * @dev Adapted from @uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol.
 *      FullMath.mulDiv replaced with OpenZeppelin `Math.mulDiv` (equivalent 512-bit).
 */
library V3LiquidityMath {
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2**96

    /// @notice Computes amount0 for a given liquidity range.
    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        amount0 = Math.mulDiv(
            uint256(liquidity) << 96,
            uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96),
            sqrtRatioBX96
        ) / sqrtRatioAX96;
    }

    /// @notice Computes amount1 for a given liquidity range.
    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        amount1 = Math.mulDiv(
            liquidity,
            uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96),
            Q96
        );
    }

    /// @notice Computes (amount0, amount1) for a position with the given liquidity at the
    ///         current sqrt price, and range [sqrtRatioAX96, sqrtRatioBX96].
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }

    /// @notice Computes the liquidity for a given amount of token0 in [a, b].
    function getLiquidityForAmount0(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = Math.mulDiv(uint256(sqrtRatioAX96), uint256(sqrtRatioBX96), Q96);
        uint256 l = Math.mulDiv(amount0, intermediate, uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96));
        require(l <= type(uint128).max, "L0");
        liquidity = uint128(l);
    }

    /// @notice Computes the liquidity for a given amount of token1 in [a, b].
    function getLiquidityForAmount1(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 l = Math.mulDiv(amount1, Q96, uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96));
        require(l <= type(uint128).max, "L1");
        liquidity = uint128(l);
    }

    /// @notice Computes the maximum liquidity NPM will mint given desired amounts
    ///         and the current pool tick relative to [a, b]. Mirrors V3 periphery.
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 l0 = getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 l1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }
}
