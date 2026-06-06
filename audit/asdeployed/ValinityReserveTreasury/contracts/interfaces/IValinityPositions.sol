// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/**
 * @title IValinityPositions
 * @notice Canonical Uniswap V3 position snapshot struct and pair-key helper used
 *         by VRT (custody), VLM (authoring), and VRYO (reader). Defined in a single
 *         shared header so ABI ordering cannot drift between contracts.
 *
 * @dev Field ordering is CONSENSUS-CRITICAL. Do not reorder, insert, or remove
 *      fields without coordinated upgrades across VRT, VLM, and VRYO.
 */

struct PositionSnapshot {
    uint256 tokenId;            // 0 = no active position
    address token0;             // sorted (token0 < token1)
    address token1;
    address poolAddress;        // non-zero when tokenId != 0
    uint24  fee;                // pool fee tier (single source of truth)
    int24   tickLower;
    int24   tickUpper;
    uint128 liquidity;          // from npm.positions()
    uint160 sqrtPriceX96;       // pool.slot0() at write time
    uint160 sqrtRatioLowerX96;  // TickMath.getSqrtRatioAtTick(tickLower)
    uint160 sqrtRatioUpperX96;  // TickMath.getSqrtRatioAtTick(tickUpper)
    uint256 principal0;         // sizing field (LiquidityAmounts)
    uint256 principal1;         // sizing field
    uint256 feesOwed0;          // reporting-only (tokensOwed + pending)
    uint256 feesOwed1;
    bool    inRange;            // tickLower <= currentTick < tickUpper
    uint64  updatedAt;          // block.timestamp at write
}

/// @notice Canonical pair key: keccak256(abi.encodePacked(sorted(a, b))).
function pairKeyOf(address a, address b) pure returns (bytes32) {
    (address t0, address t1) = a < b ? (a, b) : (b, a);
    return keccak256(abi.encodePacked(t0, t1));
}

/// @notice Minimal VRT surface consumed by VLM.
interface IValinityReserveTreasury {
    /// @notice Pulls scoped amounts of the pair's token0/token1 from VRT into the caller (VLM).
    /// @dev VLM_ROLE gated. Transfers are capped at VRT balance; no revert on shortfall.
    ///      Returns the amounts actually transferred so VLM can size downstream mints.
    function fundLiquidityManager(bytes32 pairKey, uint256 amount0, uint256 amount1)
        external
        returns (uint256 sent0, uint256 sent1);

    /// @notice Registers a freshly-minted V3 NFT (owned by VRT) under `pairKey`.
    /// @dev Must be called by VLM immediately after `npm.mint(... recipient = vrt)` and
    ///      BEFORE `setPositionSnapshot`. Pins token0/token1 for the pair.
    function receiveV3Position(bytes32 pairKey, uint256 tokenId) external;

    /// @notice Full-struct snapshot write by VLM.
    function setPositionSnapshot(bytes32 pairKey, PositionSnapshot calldata snap) external;

    /// @notice Clears snapshot + activeTokenId + token pins for `pairKey`. Idempotent.
    /// @dev Must be called by VLM after `npm.burn(tokenId)` (including inside rebalance,
    ///      between the old burn and the new mint).
    function clearPositionSnapshot(bytes32 pairKey) external;
}
