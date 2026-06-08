# Valinity VRYO + VLM Liquidity-Staking System — Strategy Handoff

**Purpose:** Self-contained briefing for an external LP/strategy expert to optimize the
Valinity reserve-yield (Uniswap V3 liquidity) strategy.
**Network:** Ethereum mainnet (read via `https://api.valinity.io/rpc-proxy`).
**Snapshot date:** 2026-06-06. **Active period analyzed:** 2026-05-01 → 2026-06-06 (~36.6 days).
**Bottom line:** The WETH/WBTC LP has lost **~35% of the assets deployed into it vs. simply
holding** (~$9.5k), driven almost entirely by **impermanent loss amplified by a ±2% band**.
Swap fees/slippage are negligible (~$63). PAXG/USDC is fine (stable anchor). The fix is band
width / rebalance policy / pair selection.

---

## 1. What the two contracts are

| Contract | Address | Role |
|---|---|---|
| **VRYO** — ValinityReserveYieldOfficer | `0xA95749f52031dA2c4baB7cf38323B69A9E3415d3` | Capital allocator. Decides how much reserve to deploy into LPs and pulls/returns the assets from/to the treasury. |
| **VLM** — ValinityLiquidityManager | `0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0` | Position manager. Owns the Uniswap V3 range logic: mint, re-center ("snapback"), TWAP guard, slippage. |
| VLM (old, retired) | `0xfd2D528afAA5e7D58811ae859080E5e974Aa7392` | Prior VLM; a few historical positions. |
| VRT — ReserveTreasury | `0x06087789B7122fA92E7F9868B10A286Dd4e4C832` | Holds the reserve assets and the LP NFTs. Source/sink of all deployed capital. |
| VCO — CapOfficer | `0x2f02415989C3e02061a8e451EF64Dc59e5c0051C` | Tracks per-asset "caps" (VY backing). Deploys shift caps VCO→VRYO. |
| VAO — AcquisitionOfficer (price oracle) | `0x7a0E582479579e1423bc4f1DFD0750feA9282B01` | TWAP USD prices used throughout (`getAssetTwapPrice`). |
| Uniswap V3 NPM | `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` | NonfungiblePositionManager. |
| Uniswap V3 Factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` | |

**Tokens:** WETH `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (18d) · WBTC `0x2260fac5e5542a773aa44fbcfedf7c193bc2c599` (8d) · PAXG `0x45804880de22913dafe09f4980848ece6ecbaf78` (18d) · USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (6d).

---

## 2. How VRYO works (the capital allocator)

**Target.** On each permissionless `execute()` call, VRYO reads circulating VY and targets
deployed capital = `circulating × deployRatioBps`. Current `deployRatioBps = 8500` (**85%**).
It then deploys or recalls to close the gap to target. A drift gate
(`keeperThresholdBps = 250`, i.e. **2.5%**) skips work when circulating hasn't moved enough.

**Deploy mechanics (per unit of VY cap moved, `takeVY`):**
1. Picks the managed asset (WETH/WBTC/PAXG) with the most VCO headroom above the VCO floor.
2. Pulls `pullAmount = takeVY × VCO.getLTV(source)` of that asset from VRT.
   → In USD this equals **`takeVY × LTVF(source)`**, i.e. each VY of cap moved is funded with
   ~that asset's loan-to-value-floor of collateral (currently ~**$0.065–0.067 per VY**).
3. `VCO.decreaseAssetCap(source, takeVY)` and `capVRYO_total += takeVY`
   → **conservation: VCO caps + VRYO caps = circulating VY** (a deploy is *floor-neutral at the
   instant it happens*; the floor only moves afterward via fees (+) and IL (−)).
4. Zaps the single source asset into a balanced pair amount (one swap) and calls VLM to mint.

**Recall mechanics:** burns LP liquidity, optional reverse-zap, returns assets to VRT,
`capVRYO_total -= takeVY`.

**Settle:** after every cycle, `_settleAllToVRT` sweeps all managed tokens (and swaps any USDC
dust to PAXG) back to VRT, asserting a zero-balance invariant on VRYO.
→ **Collected LP fees end up in VRT as reserve** (this is why realized yield shows up on the
treasury/VCO side, not inside the LP position).

**Key VRYO parameters (live):** `deployRatioBps = 8500` (85%) · `slippageBps = 50` (0.5%, used
on VRYO's own zap swaps) · `keeperThresholdBps = 250` (2.5%).

---

## 3. How VLM works (the position manager)

**Per-pair config (`pairConfig[pairKey]`):** pool, fee tier, tickSpacing, `lowerRangeBps` /
`upperRangeBps` (band half-widths), mint/close/zap slippage caps, `minRefreshInterval`,
`minRebalanceInterval`, `managedReserve`, `needsZap`.

**Re-center ("snapbackHome") — permissionless, runs on every VRYO poke.** A position is
re-centered when **all** gates pass:
- **Cooldown:** `block.timestamp − lastRebalanceAt ≥ snapbackCooldown` (live = **21,600 s = 6 h**).
- **TWAP alignment:** slot0 tick vs TWAP within tolerance (anti-manipulation), else silent skip.
- **Eligibility (`V3SnapbackGate`):** `allow = (out-of-range) OR (near-band) OR (fees ≥ cost)`
  - *out-of-range:* TWAP tick outside [tickLower, tickUpper]
  - *near-band:* within `nearBandBps` of a band edge. Live `nearBandBps = 2500` = **25% of the
    half-width** ⇒ for a ±2% band, re-center triggers once price drifts **>1.5% from center**.
  - *economic:* accrued fees ≥ `(poolFee/100 + zapSlippageBps)` of position size.

On re-center it burns the old position, optionally zaps, and mints a fresh band centered on the
current price (`snapback defaultBps = 200` ⇒ re-mints at ±2%).

**Net effect:** the position is re-centered to ±2% roughly **whenever price drifts ~1.5–2%**,
no more than once per 6 h.

---

## 4. Live configuration (answers: pool/fee tier, band, rebalance rule)

### Pools & fee tiers — you are in the **0.05%** tier for both pairs

| Pair | Fee tier | Pool address | Pool TVL | In use? |
|---|---|---|---|---|
| WETH/WBTC | **0.05%** | `0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0` | **~$39.3M** | ✅ active |
| WETH/WBTC | 0.30% | `0xCBCdF9626bC03E24f779434178A73a0B4bad62eD` | ~$31.6M | alternative |
| PAXG/USDC | **0.05%** | `0x5aE13BAAEF0620FdaE1D355495Dc51a17adb4082` | **~$3.6M** | ✅ active |
| PAXG/USDC | 0.30% | `0xB431c70f800100D87554ac1142c4A94C5Fe4C0C4` | ~$1.2M | alternative |

Both active pools are the **deeper** of the two tiers. Depth is *not* a problem (see §7).
Note the trade-off for the expert: 0.05% maximizes depth/minimizes swap cost but earns the
**least fee income** — for an IL-heavy volatile/volatile pair you generally want the *higher*
fee tier to compensate for IL.

### Band & rebalance rule (confirmed)

| Param | WETH/WBTC | PAXG/USDC |
|---|---|---|
| Band (`lower/upperRangeBps`) | **±2%** (200/200) | **±2%** (200/200) |
| Fee tier | 0.05% | 0.05% |
| tickSpacing | 10 | 10 |
| mint / close / zap slippage cap | **5% / 5% / 5%** | **5% / 5% / 5%** |
| `minRebalanceInterval` | 300 s | 300 s |
| `managedReserve` | both managed | PAXG (USDC unmanaged, `needsZap=true`) |
| Re-center cooldown (`snapbackCooldown`) | 6 h | 6 h |
| `nearBandBps` | 2500 (25% of half-width) | 2500 |
| VRYO deploy slippage | 0.5% | 0.5% |

**Rebalance rule is NOT pure rebalance-on-touch.** It's **re-center when out-of-range OR within
25% of a band edge (i.e. >1.5% drift) OR fees≥cost, throttled to once / 6 h.** In practice this
behaves close to "rebalance on ~±1.5–2% drift."

⚠️ The **5% slippage caps** on VLM mint/close/zap are loose. Currently harmless (deep pool ⇒
realized impact ~0.05%), but they are the MEV/manipulation ceiling if depth ever drops.

### Actual rebalance frequency (over 36.6 days)

| Pair | Rebalances | Per week |
|---|---|---|
| WETH/WBTC | 27 | **5.2 / week** |
| PAXG/USDC | 26 | 5.0 / week |

---

## 5. Position sizes (current)

| Pair | Composition | USD value | VRYO principal (VY cap) |
|---|---|---|---|
| WETH/WBTC | 0.1007 WBTC + 5.938 WETH | **~$15,360** | 293,162 VY |
| PAXG/USDC | 0.362 PAXG + 683 USDC | **~$2,237** | 28,820 VY |
| **Total LP** | | **~$17,600** | **`capVRYO_total` = 321,982 VY** |
| Residual (VLM) | 11.9 USDC + 0.00087 WBTC dust | ~$64 | — |

Context: total circulating VY ≈ 386,506, so VRYO holds **~83% of all VY caps** — the LP leg
dominates the system's floor/backing.

---

## 6. Swap cost per rebalance (answer: it's tiny)

Lifetime system swaps (deploys + rebalances): WETH/WBTC ≈ 54 swaps, $101k input volume;
PAXG/USDC ≈ 39 swaps, $25k volume. **Total swap fees paid ≈ $63** (0.05% tier).

Measured cost (fee + price impact) on the **last 6 WETH/WBTC rebalances** (exec price vs.
post-swap mid):

| Tx (prefix) | Block | Swap input | Cost (fee+impact) |
|---|---|---|---|
| 0x76073a5e… | 25232931 | ~$59,157 | 0.028% |
| 0xd8786e6c… | 25232931 | ~$7,143 | 0.047% |
| 0x24e5104f… | 25243831 | ~$27,716 | 0.041% |
| 0xc0414cd0… | 25249913 | ~$7,549 | 0.046% |
| 0xb04f8d07… | 25254001 | ~$12,221 | 0.044% |
| 0x1ef3cf11… | 25256496 | ~$5,186 | 0.046% |

**Per-rebalance swap cost ≈ 0.03–0.05%.** This is *not* where the money goes.

---

## 7. Past performance — the actual P&L (asset-first)

> The treasury's goal is to **grow asset quantities**, not USD. The numbers below are computed
> **vs. holding the same assets** (HODL), so USD price moves cancel out. A loss vs. HODL is
> **denomination-invariant** — identical % in USD, WETH, WBTC, or PAXG.

**Method:** net assets VRYO pulled from VRT and never returned (on-chain `Transfer` VRT↔VRYO,
which nets out recalls *and* fee sweeps) vs. value still inside the staking system (LP positions
priced with exact integer tick math + residual balances).

### Net staking P&L vs HODL

| | |
|---|---|
| Net assets consumed from VRT | 8.774 WETH + 0.187 WBTC + 0.487 PAXG = **$27,128** (current prices) |
| Value still in staking (LP + residual) | **$17,664** |
| **Net P&L vs holding** | **−$9,463  (−34.9%)** |
| Annualized bleed rate | **~350% / yr** (−35% over 36.6 days) |

Numéraire-invariance check (same −34.9% in every unit): −$9,476 USD = −6.07 WETH = −0.156 WBTC = −2.20 PAXG.

### In pure asset units

| Asset | Consumed (net) | Held now | Δ |
|---|---|---|---|
| WETH | 8.774 | 5.938 | **−2.84 (−32%)** |
| WBTC | 0.187 | 0.102 | **−0.086 (−46%)** |
| PAXG | 0.487 | 0.362 | −0.125 |
| USDC | 0 | 694.8 | +694.8 |

- **WETH/WBTC pool: fewer of BOTH assets** (−2.84 WETH and −0.086 WBTC). Even after accounting
  for internal WETH↔WBTC zap swaps, both legs are down — value genuinely left the position to
  IL. This is the entire loss (~−$9.6k).
- **PAXG/USDC pool: roughly flat / slightly accretive.** Gave up 0.125 PAXG, received 695 USDC
  (= 0.16 PAXG-equiv) ⇒ **+0.037 PAXG-equivalent**. The stable USDC anchor bounds the IL.

### Fees
LP trading fees are real but small (~$27/day on the current WETH/WBTC position at 0.05%) and are
already credited in the figures above (compounded into position value or swept to VRT). They are
**nowhere near** offsetting the IL.

---

## 8. Root cause — IL amplified by the tight band (not fees, not slippage, not the pool)

**Ruled out:** swap fees (~$63), slippage/MEV (deep $39M pool, ~0.05% realized impact), pool
choice (you're in the deeper tier).

**The mechanism:** a Uniswap V3 LP is forced to sell whichever asset rises and buy whichever
falls. For two *independently volatile* assets (WETH/WBTC) that produces impermanent loss, and a
**±2% band concentrates liquidity ~50–100× vs. full range**, amplifying IL by the same factor.

IL bleed rate ≈ `(volatility²) × (concentration factor)`. This cleanly reconciles the numbers:

| Strategy on the **actual** WETH/WBTC price path | Loss vs HODL |
|---|---|
| Static full-range, never rebalance | **−0.36%** (inherent IL of the 15% ratio move — tiny) |
| static ±50%, no rebalance | −1.4% |
| ±20% re-center | −1.1% |
| ±10% re-center | −1.8% |
| ±5% re-center | −3.4% |
| **±2% re-center (current, path-undersampled lower bound)** | **−6.5%** |
| **±2% re-center, continuous (realized on-chain)** | **≈ −35%** |

The discrete simulation (−6.5%) uses only the 27 recorded re-center points and is a **lower
bound**; the continuous reality (−35%) reflects high-frequency churn at WETH/WBTC's realized
volatility. The key, robust takeaway: **loss scales ~inversely with band width — widen the band
N× and the IL bleed drops ~N×.**

**Price path (context):** WETH/WBTC ratio moved 33.59 → 38.68 WETH-per-WBTC = **+15.1%** over the
period, oscillating (16 up-steps / 11 down-steps across re-centers) — i.e. a moderate trend with
chop, the worst case for a tight re-centered band.

**Critical nuance:** re-centering **converts impermanent loss into permanent loss.** A
never-touched position recovers its IL if the ratio returns to entry; each of the 27 re-centers
*crystallizes* the loss. Most of the −2.84 WETH / −0.086 WBTC is permanently gone, not waiting to
mean-revert.

**Why PAXG/USDC survives the same ±2% config:** one leg is a stable anchor, so the pair price is
just PAXG/USD (far less volatile than BTC/ETH) and half the position never moves — IL is bounded.

---

## 9. Levers for the expert (in rough order of impact)

1. **Widen the WETH/WBTC band a lot.** ±2% → ±15–25%+. Biggest single lever; IL bleed falls
   roughly proportionally to width.
2. **Re-center far less aggressively.** Current rule fires at ~1.5% drift (nearBandBps=2500) every
   6 h. Consider: out-of-range-only trigger, lower `nearBandBps`, longer cooldown, or a wider
   re-mint width (`snapback defaultBps`). Fewer re-centers = less crystallized IL.
3. **Prefer stable-anchored pairs for volatile assets.** WETH/USDC and WBTC/USDC behave like the
   healthy PAXG/USDC pool (bounded IL) instead of volatile/volatile.
4. **Reconsider whether WETH/WBTC should be LP'd at all.** Held as VCO collateral it has *zero*
   IL and keeps every unit. LPing it only makes sense if expected fees > expected IL — currently
   the opposite by ~100×.
5. **If keeping a volatile/volatile pair, move to the 0.3% fee tier** (still deep at ~$31.6M) to
   ~6× the fee income that offsets IL. Trade-off vs. slightly less depth / less volume.
6. **Tighten the 5% VLM slippage caps** (mint/close/zap) — currently moot but a latent MEV
   ceiling.
7. **Fee tier vs. PAXG/USDC depth:** the 0.3% PAXG/USDC pool is only ~$1.2M; keep PAXG/USDC at
   0.05% unless position size stays small.

---

## 10. Reproduce / data sources

All figures are live on-chain reads via `https://api.valinity.io/rpc-proxy`. Scripts (in
`audit/`, run with `node audit/<file>` from the repo root; viem is a project dep):

| Script | Produces |
|---|---|
| `staking-pnl.mjs` | Net-consumed vs current value, the −35% P&L, exact-tick LP value |
| `asset-terms.mjs` | Asset-unit P&L + numéraire-invariance proof |
| `staking-forensic.mjs` | Config, timeline, cadence, swap-fee attribution |
| `staking-fees.mjs` | Rebalance counts, fee recipients, lifetime fee scan |
| `price-path.mjs` | WETH/WBTC ratio path from rebalance tick centers |
| `band-sim.mjs` | Band-width sensitivity simulation over the actual path |
| `strategy-data.mjs` | Pool depth per fee tier, live config, cadence, per-rebalance cost |
| `lp-value.mjs`, `lp-live-fees.mjs` | LP mark-to-market and live (feeGrowth) unclaimed fees |

Key events for history: VRYO `Deployed(asset, vyTake, pairKey, pullAmount, liquidityMinted)` and
`Recalled(asset, vyReduced, pairKey, liquidityBurned, amount0Out, amount1Out)`; VLM
`PositionMinted` / `PositionRebalanced` / `SnapbackExecuted`. As-deployed contract source is in
`audit/asdeployed/ValinityReserveYieldOfficer/` and `audit/asdeployed/ValinityLiquidityManager/`.

---

## 11. One-paragraph summary for the expert

Valinity deploys ~85% of its VY-backed reserves into two Uniswap V3 positions managed by VRYO
(allocator) + VLM (range manager). Both run a **±2% band, 0.05% fee tier, re-centered on ~1.5%
drift (≤ once / 6 h)**. Over 36.6 days the **WETH/WBTC** position lost **~35% of the assets vs.
holding (~$9.5k; −2.84 WETH and −0.086 WBTC)** — essentially all **impermanent loss amplified by
the tight band** (swap fees were ~$63; the pool is deep so slippage is ~0.05%). Re-centering has
**crystallized** most of that loss permanently. The **PAXG/USDC** position with the identical
config is fine because USDC is a stable anchor. The optimization problem: choose band width,
re-center policy, fee tier, and pair composition so that a volatile/volatile reserve pair either
stops bleeding assets to IL or isn't LP'd that way at all.
