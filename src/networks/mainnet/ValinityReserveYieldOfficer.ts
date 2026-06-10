// VRYO V3 (VLM-free redesign, live impl 0xc8b848b9…0a241, upgraded at block
// 25275278). VRYO no longer runs Uniswap V3 concentrated LP via VLM; it drives
// each managed asset's deployed VY-cap share toward assetDeployRatioBps of its
// global cap, injecting the matching asset into the DAX pool reserve.
// NOTE: capVRYO_total is deprecated and now returns 0 — the real deployed total
// is Σ capVRYO(asset) across managed assets.
export default [
  {
    inputs: [],
    name: 'paused',
    outputs: [{ type: 'bool', name: '' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'dax',
    outputs: [{ type: 'address', name: '' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'capFloor',
    outputs: [{ type: 'uint256', name: '' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'getCirculatingVY',
    outputs: [{ type: 'uint256', name: '' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'keeperThresholdBps',
    outputs: [{ type: 'uint16', name: '' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ type: 'address', name: 'asset' }],
    name: 'capVRYO',
    outputs: [{ type: 'uint256', name: 'vyUnits' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ type: 'address', name: 'asset' }],
    name: 'deployedAsset',
    outputs: [{ type: 'uint256', name: 'nativeAmount' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ type: 'address', name: 'asset' }],
    name: 'assetDeployRatioBps',
    outputs: [{ type: 'uint16', name: 'ratioBps' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ type: 'address', name: 'asset' }],
    name: 'getGlobalCap',
    outputs: [{ type: 'uint256', name: '' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ type: 'address', name: 'asset' }],
    name: 'getInternalLTV',
    outputs: [{ type: 'uint256', name: '' }],
    stateMutability: 'view',
    type: 'function'
  }
] as const;
