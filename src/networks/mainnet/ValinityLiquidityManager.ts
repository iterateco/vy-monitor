export default [
  {
    type: 'function',
    name: 'pairConfig',
    stateMutability: 'view',
    inputs: [{ type: 'bytes32', name: 'pairKey' }],
    outputs: [
      { type: 'address', name: 'pool' },
      { type: 'uint24', name: 'fee' },
      { type: 'int24', name: 'tickSpacing' },
      { type: 'uint16', name: 'lowerRangeBps' },
      { type: 'uint16', name: 'upperRangeBps' },
      { type: 'address', name: 'token0' },
      { type: 'uint32', name: 'minRefreshInterval' },
      { type: 'uint32', name: 'minRebalanceInterval' },
      { type: 'uint16', name: 'mintSlippageBps' },
      { type: 'uint16', name: 'closeSlippageBps' },
      { type: 'address', name: 'token1' },
      { type: 'uint256', name: 'seedAmount0' },
      { type: 'uint256', name: 'seedAmount1' },
      { type: 'address', name: 'managedReserve' },
      { type: 'bool', name: 'needsZap' },
      { type: 'uint16', name: 'zapSlippageBps' }
    ]
  },
  {
    type: 'function',
    name: 'activeTokenId',
    stateMutability: 'view',
    inputs: [{ type: 'bytes32', name: 'pairKey' }],
    outputs: [{ type: 'uint256', name: '' }]
  },
  {
    type: 'function',
    name: 'lastRebalanceAt',
    stateMutability: 'view',
    inputs: [{ type: 'bytes32', name: 'pairKey' }],
    outputs: [{ type: 'uint64', name: '' }]
  },
  {
    type: 'function',
    name: 'lastRefreshAt',
    stateMutability: 'view',
    inputs: [{ type: 'bytes32', name: 'pairKey' }],
    outputs: [{ type: 'uint64', name: '' }]
  },
  {
    type: 'function',
    name: 'npm',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address', name: '' }]
  },
  {
    type: 'function',
    name: 'paused',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'bool', name: '' }]
  }
] as const;
