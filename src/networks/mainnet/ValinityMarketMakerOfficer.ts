/**
 * VMMO — Valinity Market Maker Officer (0x4b77Afb489672B026b349368837E8a13a4939eaD).
 *
 * Custodian for every real-liquidity stake (USDC / WBTC / WETH / PAXG). This is
 * the authoritative per-asset source for the holdings table:
 *
 *   heldOf(asset)  — SYSTEM holdings of that asset, summed by VMMOCoverageLib:
 *                    VRT reserve + its DAX pool leg + VMMO's undeployed book +
 *                    the VDAO-DAX balance (+ our pair USDC share, USDC only).
 *                    The same five sources VBSO's _hardAssetsFull walks, which is
 *                    why the two agree.
 *
 *   debt = aggReservedAsset + aggWithdrawingAsset
 *                  — `reserved` is principal PLUS the full promised in-kind yield,
 *                    less anything already claimed. `withdrawing` catches stakes
 *                    mid-exit, which have left the first counter for the second.
 *
 * NOTE: promisedOf() is deliberately NOT used here — it reads principal (not
 * reserved), so it excludes the yield promise. For "principal + unclaimed yield"
 * the reserved basis is the correct one.
 */
export default [
  {
    type: 'function',
    name: 'heldOf',
    stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'aggReservedAsset',
    stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'aggWithdrawingAsset',
    stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
] as const;
