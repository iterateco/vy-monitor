export default [
  {
    inputs: [],
    name: 'PAIR_PAXG_USDC',
    outputs: [{ type: 'bytes32', name: '' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'PAIR_WETH_WBTC',
    outputs: [{ type: 'bytes32', name: '' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'capVRYO_total',
    outputs: [{ type: 'uint256', name: '' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ type: 'bytes32', name: 'pairKey' }],
    name: 'pairPrincipal',
    outputs: [{ type: 'uint256', name: 'vyUnits' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'getStakedVY',
    outputs: [{ type: 'uint256', name: '' }],
    stateMutability: 'view',
    type: 'function'
  }
] as const;
