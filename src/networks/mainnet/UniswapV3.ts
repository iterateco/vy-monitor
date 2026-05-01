export const NonfungiblePositionManager = [
  {
    type: 'function',
    name: 'positions',
    stateMutability: 'view',
    inputs: [{ type: 'uint256', name: 'tokenId' }],
    outputs: [
      { type: 'uint96', name: 'nonce' },
      { type: 'address', name: 'operator' },
      { type: 'address', name: 'token0' },
      { type: 'address', name: 'token1' },
      { type: 'uint24', name: 'fee' },
      { type: 'int24', name: 'tickLower' },
      { type: 'int24', name: 'tickUpper' },
      { type: 'uint128', name: 'liquidity' },
      { type: 'uint256', name: 'feeGrowthInside0LastX128' },
      { type: 'uint256', name: 'feeGrowthInside1LastX128' },
      { type: 'uint128', name: 'tokensOwed0' },
      { type: 'uint128', name: 'tokensOwed1' }
    ]
  }
] as const;

export const UniswapV3Pool = [
  {
    type: 'function',
    name: 'slot0',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { type: 'uint160', name: 'sqrtPriceX96' },
      { type: 'int24', name: 'tick' },
      { type: 'uint16', name: 'observationIndex' },
      { type: 'uint16', name: 'observationCardinality' },
      { type: 'uint16', name: 'observationCardinalityNext' },
      { type: 'uint8', name: 'feeProtocol' },
      { type: 'bool', name: 'unlocked' }
    ]
  }
] as const;
