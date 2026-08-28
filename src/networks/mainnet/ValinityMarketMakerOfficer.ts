/**
 * VMMO — Valinity Market Maker Officer (0x4b77Afb489672B026b349368837E8a13a4939eaD).
 *
 * Custodian for every real-liquidity stake (USDC / WBTC / WETH / PAXG). This is
 * the authoritative per-asset source for the holdings table:
 *
 *   heldOf(asset)  — SYSTEM holdings of that asset, summed by VMMOCoverageLib:
 *                    VCT reserve + its DAX pool leg + VMMO's undeployed book +
 *                    the VDAO-DAX balance (+ our pair USDC share, USDC only).
 *
 *                    ⚠️ These are NOT identical to VBSO._hardAssetsFull, despite
 *                    both contracts' NatSpec claiming so. Four of the five terms
 *                    match to the wei; the pair USDC share does not. VBSO clamps
 *                    that leg to the VY side at a HARD minimum and keeps the
 *                    permanent 1% LP lock; VMMO allows uniBandBps (2000 = 20%)
 *                    of slack on the clamp and subtracts the lock. Measured
 *                    2026-08-25: $14,726.09 vs $14,609.36, a $116.73 gap on an
 *                    $80k sheet. Neither is wrong — VBSO answers "what survives
 *                    a manipulated pair", VMMO answers "what can we reach".
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
  {
    // The per-asset book. `held` is the undeployed inventory custodied on the
    // officer itself — verified equal to balanceOf(VMMO, asset) to the wei on all
    // four assets. `available` is the STORED accrual and goes stale between
    // pokes; read pendingDeploy() instead for what may actually deploy now.
    type: 'function',
    name: 'books',
    stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }],
    outputs: [
      { name: 'held', type: 'uint256' },
      { name: 'available', type: 'uint256' },
      { name: 'lastAccrual', type: 'uint64' },
    ],
  },
  {
    // LIVE deployable amount: banked `available` plus the accrual earned since
    // `lastAccrual`. This is the figure to show — the stored field alone reads
    // as zero for an asset that simply has not been poked recently.
    type: 'function',
    name: 'pendingDeploy',
    stateMutability: 'view',
    inputs: [{ name: 'asset', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    // The pacing TIME CONSTANT, in seconds — explicitly NOT a drain time. Its own
    // NatSpec: "pendingDeploy accrues against what is LEFT, not against the whole
    // book, so the release curve is held × (1 − e^(−t/W)): ~63% cleared after one
    // window, ~95% after three, never quite 100%."
    //
    // ⚠️ VBSO.projectedVyPrice returns this same value alongside a FULLY-deployed
    // price and documents it as "VMMO releases the book linearly over that window".
    // That is wrong, and the two contracts contradict each other. Never render this
    // as the time the ammo takes to deploy — derive the real horizon instead.
    type: 'function',
    name: 'deployWindow',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    // Slow end of the dial (VSR's longest stake lock). The live window scales
    // between minWindow and this with the book/depth ratio, so a draining book
    // shortens its own window and the tail deploys faster than a fixed-W curve.
    type: 'function',
    name: 'maxWindow',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
] as const;
