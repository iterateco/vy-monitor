export default [
  {
    "inputs": [{ "internalType": "address", "name": "user", "type": "address" }],
    "name": "getActiveStakes",
    "outputs": [{ "internalType": "uint8[]", "name": "", "type": "uint8[]" }],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [
      { "internalType": "address", "name": "user", "type": "address" },
      { "internalType": "uint8", "name": "stakeId", "type": "uint8" }
    ],
    "name": "pendingYield",
    "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [
      { "internalType": "address", "name": "user", "type": "address" },
      { "internalType": "uint256", "name": "stakeId", "type": "uint256" }
    ],
    "name": "pendingAssetYield",
    "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "totalPromisedYield",
    "outputs": [{ "internalType": "uint256", "name": "", "type": "uint256" }],
    "stateMutability": "view",
    "type": "function"
  }
] as const;
