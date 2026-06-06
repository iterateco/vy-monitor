# Audit: ValinityReserveYieldOfficer (VRYO) — contract 8

> **RECONCILED** with multi-agent adversarial workflow `wy9fa82g7` (22 agents; 11 findings → 5 survived / 6 refuted, severities corrected on refutation). **Verdict: CLOSED — no arbitrary-destination leak ANYWHERE (not even admin)**, exhaustively confirmed. **0 Critical / 0 High / 0 Medium / 1 Low** (bounded execute MEV) + Info. **Cap-accounting PASSED — no VLO-M1-style inflation bug** (deploy/recall symmetric in VY units; per-asset caps self-correcting + floor-bounded). All four preliminary "High/Medium" candidates were **downgraded** (the two handoff "High"s are admin-only governance-trust items; the MEV is Low; the cap-drift is a self-correcting Info). Produced **6 cross-contract obligations on VCO** (§ below).

- **Proxy:** `0xA95749f52031dA2c4baB7cf38323B69A9E3415d3` → **UUPS impl** `0x89f256f0035dea79584cbbdec4036dfd5e1fa2b3`
- **Source:** as-deployed `ValinityReserveYieldOfficer.sol` (1011 ln, commit `c4bfc30`) · solc 0.8.27 · UUPS + AccessControl + ReentrancyGuardTransient + Initializable. `V3ZapMath` inlined (no external/linked library, **no delegatecall anywhere**).
- **Role in flow:** the **reserve-yield officer** — deploys a fraction (`deployRatioBps`, live 85%) of VRT's reserves into **VRT-owned** Uniswap V3 positions (VLM authors the NFTs, VRT custodies, VRYO moves capital). Holds **VRYO_ROLE + OFFICER_ROLE on VRT** and **OFFICER_ROLE on VCO**. It is the 4th VRT role-holder (with VLO, VLM, VBBO).

## Gate 1 — Source == Live ✅ (metadata-hash proven)
The recorded artifact's `deployedBytecode`+`metadata` **== live** (bytediff: only the 2 UUPS `__self` immutables differ; ipfs `0c18431c…`). **But** the recorded `solcInputHash a50f3f1a` is **stale/inconsistent** (recompiles to `d3752a6a…`, NOT live — the VAO-style pointer bug; don't trust it). Reconstructing via the build-info closure + git: only commit **`c4bfc30`** of VRYO.sol recompiles to live metadata `0c18431c…` (the workspace `a89611b` "UPdates" compiles to `fff08e0f…` → 1 commit AHEAD, not deployed). As-deployed saved to `audit/asdeployed/ValinityReserveYieldOfficer/` (+ `_MANIFEST.json`). See [reference_recompile_stale_artifact].

## What it is — target-based reserve-yield deployer
`execute()` reads `circulatingVY` from VCO, computes `target = circulatingVY × 85%`, and deploys/recalls to converge `capVRYO_total` toward target across the 2 managed pairs (WETH/WBTC, PAXG/USDC).

| Function | Access | Effect |
|---|---|---|
| `execute()` | **PERMISSIONLESS**, nonReentrant | drift-gate (skip body if circ-VY moved <2.5%); deploy or recall loop; settle all to VRT; best-effort `vlm.snapbackHome` (try/catch, fires even on skip) |
| `reinitializeV2` | ADMIN, reinitializer(2) | already consumed |
| `setDeployRatio`(≤95%), `setSlippage`(≤5%), `setKeeperThreshold`(≤20%), `setVlm`, `setPairFee` (blocked while pair live), `setPaused`, `_authorizeUpgrade` | ADMIN | config / UUPS |
| `sweepUsdcDust()` | ADMIN, nonReentrant | settle balances **→ VRT** |
| `rescueTokens()` | ADMIN, nonReentrant | **NO ARGS** — unwind all positions + restore caps + settle **→ VRT** |
| `getCirculatingVY`/`getCapVRYOTotal`/`getPairPrincipal`/`getVcoHeadroom`/`getPairKey` | view/pure | — |

**Live state (mainnet):** paused=false; deployRatioBps=8500 (85%); **slippageBps=50 (0.5%, tight)**; keeperThresholdBps=250 (2.5%); vlm=`0x920abb09…` (=VLM ✅); vco=`0x2f024159…`; vrt=`0x06087789…`; swapRouter/npm = canonical Uniswap V3; weth/wbtc/paxg/usdc = canonical mainnet ✅; pairs = WETH/WBTC + PAXG/USDC (fee 500) = **exactly VLM's snapback set** ✅; capVRYO_total≈323k VY, lastCirculatingVY≈380k VY.

## Gate 0 — Atomic fund flow / CLOSED-CIRCUIT — my read: CLOSED, no arbitrary-destination leak ANYWHERE
Every token movement (permissionless **and admin**) has a hardcoded destination:

| Edge (line) | Token | Destination | Class |
|---|---|---|---|
| zap swap (804) | token | **address(this)** (VRYO) | fixed-self |
| reverse-zap swap (705) | token | **address(this)** | fixed-self |
| USDC→PAXG swap (864) | PAXG | **address(this)** | fixed-self |
| deployForYield recipient (555) | source asset | **address(this)** (pull from VRT) | fixed-self |
| increaseLiquidity (825) | token0/1 | **VRT's NFT** (VRT owns) | fixed-internal |
| decreasePositionLiquidity (686) | token0/1 | **VRYO** (then settled to VRT) | fixed-internal |
| `_settleAllToVRT` (382,387,392) | WETH/WBTC/PAXG | **address(vrt)** + zero-balance `InvariantViolation` checks | fixed-internal |
| forceApprove (698,798,818-19,858) | — | swapRouter / npm only | bounded |

→ **There is NO arbitrary-`to` transfer anywhere in VRYO — not even for admin.** `rescueTokens()` takes **no destination argument**; it unwinds to VRT. This is **stronger than VLM** (whose `rescueTokens` had an arbitrary `to`). Closed circuit holds by construction.

## Findings (reconciled): 0 Critical, 0 High, 0 Medium, 1 Low, rest Info
| ID | Sev | Finding |
|---|---|---|
| **VRYO-L1** | **Low** | **Bounded execute() zap MEV (sandwich).** `_zapIntoV3`/`_recallFromPair` reverse-zap/`_swapAllUsdcToPaxg` all compute `minOut` from **live slot0** (`V3ZapMath.computeMinOut`, `sqrtPriceLimitX96:0`); the `vlm.assertTwapAligned` guard is a **band check** (reverts only beyond ±3% slot0-vs-TWAP) — so a front-run nudging slot0 to the ±3% edge passes, and minOut is computed at that adversarial price. **Confirmed** but **bounded:** ±3% TWAP band + **0.5%** live slippage + **2.5% circulating-VY drift gate** (attacker can't trigger `execute()` at will — body runs only on organic ≥2.5% supply drift), take sliced to gap/3, per-event notional tiny (~few-k VY vs ~323k book). Net of attacker's own round-trip Uniswap fees + pool price-impact, extraction is small. **Value-leak-no-redirect** (attacker profits via own pool trades, not a VRYO transfer). Same accepted pattern as VLM-L1. |
| **VRYO-cap** | **PASS (no bug)** | **Cap-accounting verified sound — no VLO-M1 inflation.** Deploy `decreaseAssetCap(source, takeVY)`+`capVRYO_total+=takeVY`+`pairPrincipal+=takeVY`; recall the exact inverse; rollback on zap-fail (L561). Always `capVRYO_total == Σ pairPrincipal`; no path moves cap/principal by more than the VY actually moved. **Per-asset WETH/WBTC cap is non-invariant but SELF-CORRECTING:** deploy picks highest-headroom side, recall restores lowest-cap side → a *stabilizing* loop toward equalization (not a runaway), and `decreaseAssetCap` reverts below VCO `effectiveFloor` → no collapse. The `(0,0)` liquidity mins on increase/decrease are SAFE (value bounded by the swap's `amountOutMinimum` + the zero-balance settle invariant). |
| **VRYO-I-grief** | Info | **Spam `execute()` below the 2.5% drift gate** = pure no-op (body bypassed, zero state writes), and the snapback hook is throttled by VLM's own cooldown + VGO reward disabled for `msg.sender==vryo` → attacker earns nothing, harms only own gas. No protocol cost. |
| **VRYO-I-handoff** | Info | `slippageBps` (≤5%) and the `vlm` address become permanent governance-mutable params at Fase 4 (both admin-only; can't redirect funds; subsumed by governance's UUPS upgrade power). Watchlist, not a vulnerability. |
| **VRYO-I-snapback** | Info | `vlm.snapbackHome` fires on every `execute()` (even paused/skipped) — gas-bounded (1.5M) + try/catch; throttling owned by VLM's 6h cooldown. |
| **VRYO-I-decimals** | Info | `_scaleFromWad` (WBTC 8dp): tiny `pullAmount18` can round to 0 → deploy skipped (return 0), no corruption. |
| **VRYO-I-rescue** | Info | No arbitrary-dest rescue (`rescueTokens()`/`sweepUsdcDust()` have no `to`) — strictly to VRT. Stronger than VLM. |

## Cap-accounting verdict — PASS (no inflation; conserved aggregate; self-correcting per-asset)
- **Symmetric in VY units.** Deploy (`_deployIntoPair`): `vco.decreaseAssetCap(source, takeVY)` (549) + `capVRYO_total += takeVY` (566) + `pairPrincipal[pair] += takeVY` (567). Recall (`_recallFromPair`): exact inverse (716-719). Invariant `capVRYO_total == Σ pairPrincipal` always holds; no path moves more than the VY actually moved. Zap-fail rolls back `increaseAssetCap(source, takeVY)` (561).
- **Per-asset WETH/WBTC cap non-invariant but SELF-CORRECTING.** Deploy picks highest-headroom side; recall restores lowest-cap side (`_pickWWRecall`, 657) → stabilizing toward equalization (the *opposite* of a runaway). Downward drift hard-bounded by VCO `decreaseAssetCap` reverting below `effectiveFloor` → no collapse. `getLTV(source)` feedback into `pullAmount` is economically neutral, deterministic, floor-bounded.
- **`rescueTokens` cap restoration symmetric** (966-976): restore per-pair principal → VCO, zero ledgers. No double-count.
- **`(0,0)` liquidity mins SAFE:** increase value protected by the prior swap's `amountOutMinimum` + zero-balance settle invariant; burn proceeds proportionate + invariant-checked.

## Cross-contract dependencies
- **VRT (VRYO_ROLE + OFFICER_ROLE):** `deployForYield`, `decreasePositionLiquidity`, `getPositionSnapshot` — VRT audited (closed relative to roles) ✅.
- **VLM:** `refreshSnapshot`/`assertTwapAligned`/`snapbackHome` (the ±3% TWAP guard VRYO relies on) — VLM audited ✅.
- **Shared admin key** across the officer set.

## ⚠️ Cross-contract obligations VRYO places on VCO (carry into the VCO audit)
VRYO's cap-integrity + closed-circuit guarantees are conditional on VCO honoring these — **verify each when auditing VCO:**
1. `decreaseAssetCap`/`increaseAssetCap` are exactly additive/symmetric in VY units and **OFFICER_ROLE-gated** (so `decrease(x)` then `increase(x)` round-trips with no internal scaling/rounding drift).
2. `decreaseAssetCap` **reverts below `effectiveFloor()`** — this is the *only* bound preventing per-asset cap collapse under VRYO's deploy loop. Confirm the floor can't be set to 0 / bypassed.
3. `getLTV(asset) = reserveOf/cap × WAD` is a faithful, non-manipulable attribution (it's VRYO's `pullAmount` multiplier — no permissionless path may inflate `reserveOf` or deflate `cap`).
4. **`getTotalCirculatingVY()` is NOT permissionlessly manipulable intra-tx** — it drives VRYO's target + drift gate; manipulating it would be the attacker's missing "trigger `execute()` at will" lever for VRYO-L1.
5. `getAssetCap`/`effectiveFloor` are consistent with the mutators (VRYO reads them in the pickers + rescue restore).
6. **OFFICER_ROLE on VCO** stays correctly assigned to VRYO post-handoff and grants no cap mutation beyond the symmetric increase/decrease pair.

## Check-off
- [x] Source == live (metadata-hash proven; live = `c4bfc30`; solcInputHash stale; workspace 1 commit ahead)
- [x] Fund-flow mapped — CLOSED, no arbitrary-destination leak anywhere (my read)
- [x] Live-state read (ratios, slippage, threshold, roles, pairs — all consistent)
- [x] Multi-agent adversarial workflow `wy9fa82g7` reconciled (22 agents; 5 survived / 6 refuted; severities corrected)
- [x] **User agrees → checked off 2026-06-02**

## Final tally (reconciled): 0 Critical, 0 High, 0 Medium, **1 Low** (VRYO-L1 bounded execute zap MEV — no redirect, opportunistic/drift-gated, tiny notional), rest Info.
**The closed circuit HOLDS for ALL callers including admin** — no arbitrary-`to` transfer exists anywhere in VRYO (every sink hardcoded: swaps→self, deploy-pull→self, increaseLiquidity→VRT NFT, settle→VRT with zero-balance `InvariantViolation` checks; `rescueTokens()`/`sweepUsdcDust()` have no destination arg). **Cap-accounting is sound — no VLO-M1 inflation bug** (symmetric in VY units; per-asset caps self-correcting + floor-bounded). The single residual is bounded no-redirect MEV (Low), identical in kind to the accepted VLM-L1. **VRYO is cleared from its own side for the irreversible DEFAULT_ADMIN_ROLE handoff, conditional on the VCO audit confirming the 6 cross-contract obligations above.**
