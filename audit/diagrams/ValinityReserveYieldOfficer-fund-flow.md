# ValinityReserveYieldOfficer (VRYO) — Atomic Fund-Flow Circuit · **ValinityDAX edition (V3 redesign, VLM-free)**

> ⚠️ **This OVERWRITES the prior VRYO audit** (Uniswap-V3-LP-via-VLM model, impl `0x89f256f0`). That design is **eliminated** — VLM is fully disconnected (zero roles). The live impl is now `0xc8b848b9` (upgraded 2026-06-08, block 25275278).

Proxy `0xA95749f5…` → UUPS impl `0xc8b848b9…` (12,419 B). Source==live **PROVEN** (live impl metadata-IPFS == hardhat artifact == build-info `c3d525c0` compile of workspace `ValinityReserveYieldOfficer.sol`, 619 ln, keccak match; HEAD `1aa24be`). solc 0.8.27 / runs=100 / cancun.

The **reserve-yield officer, redesigned**: instead of earning Uniswap-V3 fees, it deploys a per-asset fraction of VRT's reserves into the protocol's **own ValinityDAX VY/asset pools** as one-sided, protocol-owned asset **depth**, and recalls it as caps move. A **CLOSED LEG of VRT**: it shuffles cap-units between VCO and its own `capVRYO` ledger — `globalCap(A) = vco.getAssetCap(A) + capVRYO[A]` is **conserved** — and never mints or moves circulating VY.

> **Convention:** non-admin paths only; admin in the box below. **Every token destination is hardcoded {DAX, VRT} — no caller-supplied recipient exists anywhere.**

## Operational circuit (permissionless — single entry)

```
 Anyone ──execute()── [nonReentrant; revert if dax==0; no-op if paused]
   │  per managed asset A ∈ {WETH, WBTC, PAXG}:  _rebalanceAsset(A)
   │     globalCap = vco.getAssetCap(A) + capVRYO[A]      target = globalCap × assetDeployRatioBps[A]/10000 (live 60%)
   │     delta = |target − capVRYO[A]| ;  BAND GATE: skip if delta/globalCap < keeperThresholdBps (2.5%)
   │     poolId = dax.assetToPoolId(A)
   │
   ├─ target > capVRYO  ──try this.deployStep(A, Δ, vcoCap, poolId)── [self-only; try/catch ⇒ per-asset fault isolation]
   │     clamp Δ to VCO headroom above effectiveFloor (TargetClamped)
   │     pull = Δ × vco.getLTV(A)          [LTV-neutral: cap↓Δ + asset-out at same LTV ⇒ getLTV invariant]
   │     vco.decreaseAssetCap(A, Δ)                                  ── cap-units VCO → VRYO (reserved up-front)
   │     ◄── pull asset ── vrt.deployForYield([A],[pull], recipient=THIS)   [VRT.VRYO_ROLE; measure ACTUAL receipt — PAXG FoT]
   │        if received==0 ⇒ vco.increaseAssetCap(A, Δ) (undo) + return
   │     forceApprove(dax, received) ; dax.reserveInjectAsset(poolId, received)   ── asset → DAX pool reserve [RESERVE_OFFICER_ROLE]
   │        credited = DAX balanceOf delta (real gain) ; credited==0 ⇒ revert InvariantViolation
   │     capVRYO[A] += Δ ;  deployedAsset[A] += credited
   │     INVARIANT: balanceOf(this) == balBefore  (no asset lingers on the officer)
   │
   └─ target < capVRYO  ──_recall(A, Δ, poolId)──
         want = Δ × deployedAsset[A]/capVRYO[A]        [STALE blended internal LTV — recall converts at the frozen rate]
         clamp: physical = min(want, pool.reserveAsset, DAX real balanceOf)   [thin pool ⇒ partial; FoT-absorbing]
         retireVY = full ? capVRYO : Δ×capVRYO/dep    (proportional to asset actually pulled)
         try dax.reserveExtractAsset(poolId, physical, recipient=address(vrt))   ── asset → VRT  [catch ⇒ RecallSkipped]
         capVRYO[A] −= retireVY ; deployedAsset[A] −= physical
         try vco.increaseAssetCap(A, retireVY) {} catch {}        ── cap-units VRYO → VCO (isolated: de-listed asset won't brick)

 Yield is NOT captured here (the DEX swap fee routes to VBBO); the deployed asset balance never grows ⇒ the
 (deployedAsset, capVRYO) ledger stays exact. globalCap conserved every step.
```

## Exit-destination ledger (the closed-circuit proof)

| Edge | Token | Destination | Class |
|---|---|---|---|
| `vrt.deployForYield(recipient=this)` | asset | **address(this)** (pull from VRT) | fixed-self |
| `dax.reserveInjectAsset` | asset | **the DAX pool** (poolId resolved live) | protocol-determined |
| `dax.reserveExtractAsset(recipient=address(vrt))` | asset | **VRT** (hardcoded) | fixed-internal |
| `vco.decrease/increaseAssetCap` | — (cap ledger) | VCO ↔ capVRYO | accounting only |
| `rescueTokens` → `_fullRecall` | asset | **VRT** (hardcoded, ADMIN) | admin → VRT |
| ~~arbitrary `to`~~ | — | — | **none exists** |

**No exit accepts a caller-supplied recipient.** Cap-units only shuffle VCO↔capVRYO (conserved). ⇒ **CLOSED relative to roles.**

## Trust surface (admin / roles — excluded from the atomic proof)
| Lever | Role | Effect |
|---|---|---|
| `_authorizeUpgrade` | ADMIN_ROLE | **DOMINANT — amplified by 3 roles.** A malicious VRYO upgrade commands DAX.RESERVE_OFFICER_ROLE (drain pool **asset** to any address via `reserveExtractAsset`) + VCO.OFFICER_ROLE (mutate caps) + VRT.VRYO_ROLE (`deployForYield`). |
| `setAssetDeployRatio` | ADMIN_ROLE | ≤95% (live 60%); how much reserve is deployed as DAX depth (the economic risk dial). |
| `setKeeperThreshold` | ADMIN_ROLE | rebalance band (live 2.5%). |
| `setDax` / `setPaused` | ADMIN_ROLE | re-point DAX / halt. |
| `rescueTokens` | ADMIN_ROLE | full-recall all to **VRT only** (no arbitrary dest) ✅ |

**Init-only / no-setter:** `vco`, `vrt`, `weth/wbtc/paxg`. **Deprecated VLM-era slots** (swapRouter/npm/vlm/usdc/PAIR_*/pairFee/deployRatioBps/capFloor/slippageBps/capVRYO_total=0/…) kept ONLY to pin the storage layout; unused.

## Live state (today) — LIVE + FUNDED
- `dax`=`0xD256C672` (real DAX), `vco`/`vrt` wired, `paused`=false, `keeperThresholdBps`=250. Roles: DAX.RESERVE_OFFICER✅, VCO.OFFICER✅, VRT.VRYO_ROLE✅.
- All 3 assets `assetDeployRatioBps`=**6000 (60%)**. `capVRYO` {WETH 102.9k · WBTC 101.5k · PAXG 22.1k VY} ≈ **226k VY cap deployed**; `deployedAsset` {3.83 WETH · 0.099 WBTC · 0.326 PAXG}.

**Verdict (RECONCILED, workflow `wqm7zyrs0` — 26 agents, joint VRYO+DAX; 35 raw → 13 surv / 6 ref / 16 Low-Info · 0 permissionless-exploitable, 0 conservation violations):** ✅ **CLOSED — no arbitrary-dest leak** (all destinations hardcoded {DAX, VRT}; `reserveExtract` recipient is role-gated to VRYO→VRT); **cap-conserving closed leg** (`globalCap = vcoCap + capVRYO` symmetric across deploy/recall — workflow refuted the "phantom cap / under-back / indefinite stagnation" over-claims). Residual: **C1** dominant `_authorizeUpgrade` amplified by 3 roles (drain DAX asset + pull VRT + mutate VCO caps; workflow rated High, I keep Critical for the VRT-pull amplification); **M1** the **backing-quality economic shift** (deployed reserve asset is arbitraged/swapped into VY-in-pool; `deployedAsset` overstates the live pool reserve — governance-accept + monitor); **M2** partial-recall degradation (keeper/monitoring); Lows (LTV drift bounded <10bps, execute() sandwich = no caller profit, setters no-timelock). **VLM fully eliminated** (zero roles on VRT/VCO/DAX, confirmed on-chain). See `findings/ValinityReserveYieldOfficer.md`.
