/**
 * VBSO — Valinity Balance Sheet Officer (proxy 0xDFd145401122d62987c6a363e370F4DB759BE1b4).
 *
 * The company balance sheet, all USD at 1e18. This is now the authoritative
 * backing source: the hard assets moved out of the VRT into the DAX, so any
 * panel that reads treasury balances for backing reads ~0 and is lying by
 * omission. Read sheet() instead.
 *
 * NOTE ON THE LIVE IMPLEMENTATION (0x9bcf0c21):
 * floorFullUsd() / floorHardUsd() / circulatingVY() exist in the VBSO source but
 * are NOT in the deployed implementation — all three revert on-chain (verified).
 * The dashboard therefore derives the per-VY floors off-chain from equityUsd(),
 * hardEquityUsd() and the circulating supply. If VBSO is ever upgraded to expose
 * them, switch to the direct calls and delete the local division.
 */
export default [
  {
    type: 'function',
    name: 'sheet',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'hardAssetsUsd', type: 'uint256' },
      { name: 'coveredLoansUsd', type: 'uint256' },
      { name: 'loansFaceUsd', type: 'uint256' },
      { name: 'stakerDebtUsd', type: 'uint256' },
      { name: 'equityUsd', type: 'int256' },
      { name: 'fuelUsd', type: 'uint256' },
      { name: 'demandUsd', type: 'uint256' },
      { name: 'masterRateBps', type: 'uint256' },
      { name: 'eraMaxBps', type: 'uint256' },
      { name: 'era', type: 'uint8' },
      { name: 'mcapUsd', type: 'uint256' },
      { name: 'usdPerVy', type: 'uint256' },
      { name: 'custodyCollateralUsd', type: 'uint256' },
      { name: 'custodyEarnedUsd', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'equityUsd',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'int256' }],
  },
  {
    type: 'function',
    name: 'hardEquityUsd',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'int256' }],
  },
  {
    type: 'function',
    name: 'coveredLoansUsd',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'counted', type: 'uint256' },
      { name: 'faceTotal', type: 'uint256' },
    ],
  },
  {
    // The market-making forecast: where VY prices out once VMMO has deployed its
    // whole book. Returned WITH the inputs that produce it (ammo / window /
    // multiple) because the contract's own NatSpec forbids quoting the price
    // alone — it assumes zero opposing flow for the entire window, and much of
    // the liquidity it buys from is protocol-owned.
    // Reverts VmmoNotWired() if VMMO is unset, rather than returning a zero that
    // would read as "no upside".
    type: 'function',
    name: 'projectedVyPrice',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'vyPriceUsd', type: 'uint256' },
          { name: 'ammoUsd', type: 'uint256' },
          { name: 'deployWindowSec', type: 'uint256' },
          { name: 'multipleX', type: 'uint256' },
          { name: 'livePriceUsd', type: 'uint256' },
        ],
      },
    ],
  },
  {
    // The premium anchor the era ladder scales, read live rather than hardcoded:
    // if governance ever moves it, every rung's rate follows.
    type: 'function',
    name: 'PREMIUM_ANCHOR_BPS',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint16' }],
  },
  {
    // USD per whole token, 1e18 — the same marks the sheet values everything at,
    // so the holdings table cannot drift from the sheet by using another oracle.
    type: 'function',
    name: 'assetUsdPrice',
    stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'vyOracle',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  // ── Custom errors ────────────────────────────────────────────────────────
  // Declared so viem decodes a revert to its NAME instead of a bare selector.
  // The view surface funnels everything through PriceUnavailable(): VAO's own
  // reverts (UniV3 'OLD', stale observation, PoolDoesNotExist) are all remapped
  // to it, so a sheet() failure with this selector means an oracle is refusing
  // to price an asset — not that the sheet is wrong.
  { type: 'error', name: 'PriceUnavailable', inputs: [] },
  { type: 'error', name: 'VmmoNotWired', inputs: [] },
  { type: 'error', name: 'AccumulatorsNotLive', inputs: [] },
  { type: 'error', name: 'LegacyMigrationPending', inputs: [] },
] as const;
