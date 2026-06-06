// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title V3PositionValue
 * @notice 0.8.27 port of the fee portion of Uniswap V3 periphery `PositionValue`.
 *         Computes uncollected fees owed to a position (= tokensOwed + pending
 *         since last poke) without mutating state.
 * @dev Adapted from @uniswap/v3-periphery/contracts/libraries/PositionValue.sol
 *      (GPL-2.0-or-later). Modular (wrapping) arithmetic on feeGrowth deltas is
 *      preserved via `unchecked` blocks — this matches V3 pool semantics.
 */

interface INPMPositions {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IV3PoolFees {
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
}

library V3PositionValue {
    uint256 private constant Q128 = 0x100000000000000000000000000000000; // 2**128

    struct FeeParams {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /**
     * @notice Total fees owed to a position, including pending fees since last poke.
     * @param npm  Uniswap V3 NonfungiblePositionManager.
     * @param pool The V3 pool corresponding to the position's (token0, token1, fee).
     * @param tokenId Position NFT id.
     */
    function fees(address npm, address pool, uint256 tokenId)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (
            ,
            ,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = INPMPositions(npm).positions(tokenId);

        (amount0, amount1) = _fees(
            pool,
            FeeParams({
                liquidity: liquidity,
                tickLower: tickLower,
                tickUpper: tickUpper,
                feeGrowthInside0LastX128: feeGrowthInside0LastX128,
                feeGrowthInside1LastX128: feeGrowthInside1LastX128,
                tokensOwed0: tokensOwed0,
                tokensOwed1: tokensOwed1
            })
        );
    }

    /**
     * @notice Gas-optimized variant: caller supplies already-read position fields so
     *         this library does not re-invoke `npm.positions()`. Used by VLM which
     *         consolidates the single positions() read across snapshot writing.
     */
    function feesFromParams(
        address pool,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _fees(
            pool,
            FeeParams({
                liquidity: liquidity,
                tickLower: tickLower,
                tickUpper: tickUpper,
                feeGrowthInside0LastX128: feeGrowthInside0LastX128,
                feeGrowthInside1LastX128: feeGrowthInside1LastX128,
                tokensOwed0: tokensOwed0,
                tokensOwed1: tokensOwed1
            })
        );
    }

    function _fees(address pool, FeeParams memory p)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            _feeGrowthInside(pool, p.tickLower, p.tickUpper);

        unchecked {
            amount0 = Math.mulDiv(
                feeGrowthInside0X128 - p.feeGrowthInside0LastX128,
                p.liquidity,
                Q128
            ) + p.tokensOwed0;
            amount1 = Math.mulDiv(
                feeGrowthInside1X128 - p.feeGrowthInside1LastX128,
                p.liquidity,
                Q128
            ) + p.tokensOwed1;
        }
    }

    function _feeGrowthInside(address pool, int24 tickLower, int24 tickUpper)
        private
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        IV3PoolFees p = IV3PoolFees(pool);
        (, int24 tickCurrent, , , , , ) = p.slot0();
        (, , uint256 lowerFG0, uint256 lowerFG1, , , , ) = p.ticks(tickLower);
        (, , uint256 upperFG0, uint256 upperFG1, , , , ) = p.ticks(tickUpper);

        if (tickCurrent < tickLower) {
            unchecked {
                feeGrowthInside0X128 = lowerFG0 - upperFG0;
                feeGrowthInside1X128 = lowerFG1 - upperFG1;
            }
        } else if (tickCurrent < tickUpper) {
            uint256 g0 = p.feeGrowthGlobal0X128();
            uint256 g1 = p.feeGrowthGlobal1X128();
            unchecked {
                feeGrowthInside0X128 = g0 - lowerFG0 - upperFG0;
                feeGrowthInside1X128 = g1 - lowerFG1 - upperFG1;
            }
        } else {
            unchecked {
                feeGrowthInside0X128 = upperFG0 - lowerFG0;
                feeGrowthInside1X128 = upperFG1 - lowerFG1;
            }
        }
    }
}
