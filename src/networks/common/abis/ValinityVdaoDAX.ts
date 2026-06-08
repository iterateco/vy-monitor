// VDAO DAX — a second arbitrage-exchange contract whose pools pair a VDAO token
// (e.g. VGC, launched on top of VY) with an external asset (e.g. WBTC), rather
// than pairing VY with an asset like the original ValinityDAX. Its getPoolReserves
// therefore returns BOTH token addresses and reserves, and it has no VY-denominated
// total-reserves accessor.
export default [
  {
    "inputs": [],
    "name": "getNumPools",
    "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [{ "internalType": "uint256", "name": "poolId", "type": "uint256" }],
    "name": "getPoolReserves",
    "outputs": [
      { "internalType": "address", "name": "asset", "type": "address" },
      { "internalType": "address", "name": "vdaoToken", "type": "address" },
      { "internalType": "uint256", "name": "reserveAsset", "type": "uint256" },
      { "internalType": "uint256", "name": "reserveVdao", "type": "uint256" }
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "swapsPaused",
    "outputs": [{ "internalType": "bool", "name": "", "type": "bool" }],
    "stateMutability": "view",
    "type": "function"
  }
] as const;
