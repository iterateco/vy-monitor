# VRYO — ValinityReserveYieldOfficer — Findings · **ValinityDAX edition (V3 redesign)**

> ⚠️ **OVERWRITES the prior VRYO audit** (`wy9fa82g7`, Uniswap-V3-LP-via-VLM, impl `0x89f256f0`). That design is **eliminated**: VLM is fully disconnected. Live impl is now `0xc8b848b9` (upgraded 2026-06-08, block 25275278).

**Address:** proxy `0xA95749f52031dA2c4baB7cf38323B69A9E3415d3` → impl `0xc8b848b9b9d8bf67f972455a628cfe4cebb0a241` (UUPS).
**Source==live:** PROVEN (live impl metadata-IPFS == hardhat artifact == build-info `c3d525c0` compile of workspace `ValinityReserveYieldOfficer.sol`, 619 ln, keccak match; HEAD `1aa24be`). solc 0.8.27 / runs=100 / cancun.
**Status:** ✅ RECONCILED with workflow `wqm7zyrs0` (26 agents, 6 dims joint VRYO+DAX; 35 raw → 13 survived / 6 refuted / 16 Low-Info). Verdict aligned: **no closed-circuit break, cap conservation confirmed, 0 Critical/permissionless**. Tally (VRYO side): 1 Critical · 0 High · 1 Medium · 4 Low. The redesign's central risk is **economic backing-quality**, governance-accept.

## Summary

The reserve-yield officer, fully redesigned: it now deploys a per-asset fraction of VRT's reserves into the protocol's **own ValinityDAX VY/asset pools** as one-sided asset depth (instead of Uniswap-V3 LP), and recalls it as caps move. A **closed leg of VRT** — `globalCap(A) = vco.getAssetCap(A) + capVRYO[A]` is conserved; it never mints/moves circulating VY.

- **#1 closed-circuit (PASS).** Every asset destination is hardcoded {DAX (inject), VRT (recall/rescue)}; cap-units only shuffle VCO↔`capVRYO`. No caller-supplied recipient anywhere. The officer holds no asset between txs (`balanceOf==balBefore` invariant). `rescueTokens` settles only to VRT.
- **Cap conservation (PASS).** Deploy: `vco.decreaseAssetCap(Δ)` + `capVRYO += Δ`; recall: `vco.increaseAssetCap(retireVY)` + `capVRYO -= retireVY`. Symmetric. The up-front cap shift is undone on a failed VRT pull; the `deployStep` self-call try/catch rolls back per-asset on any sub-failure; the floor clamp keeps VCO above `effectiveFloor`.
- **Residual = admin/upgrade trust** (dominant `_authorizeUpgrade`, now amplified by 3 roles) **+ a backing-quality economic shift** (the headline of the redesign — see VRYO-M1).

**Live: LIVE + FUNDED.** ratio 60% all assets; ~226k VY cap deployed (WETH 102.9k / WBTC 101.5k / PAXG 22.1k) backed by 3.83 WETH / 0.099 WBTC / 0.326 PAXG. Roles all correctly held; VLM fully disconnected.

---

## Findings (preliminary — to be reconciled with workflow)

### VRYO-C1 [Critical — admin/upgrade, deferred-handoff] `_authorizeUpgrade` amplified by THREE roles
[ValinityReserveYieldOfficer.sol:258](../asdeployed/ValinityReserveYieldOfficer/contracts/officer/ValinityReserveYieldOfficer.sol#L258) — `onlyRole(ADMIN_ROLE)`, no timelock. VRYO holds **DAX.RESERVE_OFFICER_ROLE + VCO.OFFICER_ROLE + VRT.VRYO_ROLE**. A malicious VRYO upgrade can: drain **all DAX pool asset reserves** to an attacker (`reserveExtractAsset(recipient=attacker)`), mutate VCO caps (phantom inflation), and pull VRT reserves (`deployForYield`). The combined blast radius is larger than the old VRYO. **Handoff:** migrate DEFAULT_ADMIN + ADMIN together to governance + external TimelockController; renounce the EOA. (Same dominant-lever family as every officer; flagged Critical for the 3-role amplification.)

### VRYO-M1 [Medium — economic/backing, by-design] Reserve depth is exposed to conversion into VY-in-pool
The core of the redesign: VRYO injects reserve asset into a **shared** DAX VY/asset pool as one-sided depth and receives **no VDAX** (its claim is enforced only by `RESERVE_OFFICER_ROLE` + the `deployedAsset` ledger). The single-sided injection makes the asset cheap → the (now whitelisted) MEV bot and whitelisted swaps (VEO routing users, VBBO, VAO) swap VY→asset, taking the deployed asset **out** of the pool and leaving VY. So a deploy can effectively **convert hard-asset backing (WETH/WBTC/PAXG) into protocol-own-VY-in-pool** — a real-backing-quality reduction (you can't back VY with VY). Also: `deployedAsset[A]` only decrements on recall, **not** when swaps/arb thin the pool → it can **overstate** the pool's actual asset reserve, over-counting backing in any view/monitor that reads it (recall itself is safe — clamped to the live reserve). Bounded by the deploy ratio (live 60%, max 95%) and the asset stays inside the protocol's own DEX. **Not permissionless-exploitable** (value goes to the pool/VBBO, not an attacker) and cap is conserved — this is a **governance risk-acceptance**: how much hard reserve to expose as DEX depth. *(Workflow to quantify worst-case + confirm the monitor double-count guidance from [[project_vryo_v3_dax_redesign]].)*

### VRYO-M2 [Medium — operational/keeper] Partial-recall degradation needs monitoring
When whitelisted swaps/arb thin a pool faster than the band-gated `execute()` recalls, `_recall` clamps to the live reserve and retires cap **proportionally** (cap stays conserved — the workflow refuted the "stagnates indefinitely / phantom cap" over-claim: each `execute()` still makes progress, and `delta/globalCap` stays above the 2.5% band so rebalancing keeps firing). But the **intended deploy ratio may not be realized** and `deployedAsset[A]` overstates the live pool reserve until recall reconciles. **Mitigation:** governance monitor `deployedAsset[A]` vs the live `pool.reserveAsset`; alert on divergence; `setAssetDeployRatio(asset,0)` or `rescueTokens` to reset. Not exploitable, not a conservation break.

### VRYO-L4 [Low — accounting, by-design] Asymmetric LTV drift (deploy live vs recall frozen)
Deploy pulls asset at VCO's **live** LTV; recall converts at the **frozen blended** internal LTV (`deployedAsset/capVRYO`) — "recall nudges VCO's LTV — intended" ([:73-76](../asdeployed/ValinityReserveYieldOfficer/contracts/officer/ValinityReserveYieldOfficer.sol#L73)). Workflow CONFIRMED: cap is conserved; under-backing is bounded (<5–10 bps per 10% LTV swing + pool drain), guard-railed by the floor clamp + recall clamp + try/catch; **non-exploitable** by any permissionless caller (amounts VRYO-computed, destinations VRT/DAX). Documented economic trade-off.

### VRYO-L5 [Low — handoff] Admin setters have no timelock; `setDax` re-point
`setAssetDeployRatio`/`setKeeperThreshold`/`setPaused`/`setDax` are instant ADMIN ops. Fold into the C1 timelock requirement. `setDax` re-points the DEX VRYO injects into — confirm = real DAX (live ✅).

### VRYO-Info [confirmed] VLM fully eliminated
VLM `0x920AbB09` holds **zero roles** on VRT (`VLM_ROLE`/`LIQUIDITY_MANAGER_ROLE`/`OFFICER_ROLE`/`VRYO_ROLE`/`BUYBACK_ROLE` all false), VCO (`OFFICER_ROLE` false), and DAX (`RESERVE_OFFICER`/`swapWhitelist`/`ADMIN` false). The deprecated `VLM_ROLE` *definition* lingers in VRT's source but no contract holds it (the workflow's one VLM gap — discharged on-chain).

### VRYO-L1 [Low] `execute()` permissionless; injection drift is arb'd to VBBO
`execute()` is permissionless and band-gated (2.5%). Injecting/extracting asset shifts the pool price; the arb is captured by the MEV bot → VBBO, not the caller. Timing `execute()` is a protocol-beneficial keeper poke; no attacker edge (value never routes to the caller). Confirm rounding (mulDiv floors) always favors the protocol.

### VRYO-L2 [Low] PAXG/FoT handled on VRYO's side; DAX over-counts
`deployStep` books `deployedAsset += DAX actual balance gain` (FoT-safe) and recall clamps to the DAX real balance — so VRYO's ledger is exact for PAXG. But `dax.reserveInjectAsset` credits the pool's `reserveAsset` by the **nominal** amount → the DAX over-counts PAXG by the fee (the pre-existing DAX-L2; see DAX findings).

### VRYO-L3 [Info] Deprecated VLM-era storage slots retained for layout
swapRouter/npm/vlm/usdc/PAIR_*/pairFee/deployRatioBps/capFloor/slippageBps/`capVRYO_total`(=0)/pairPrincipal/lastCirculatingVY kept only to pin the UUPS layout; unused. `capVRYO_total` reads 0 — monitors must use `Σ capVRYO(asset)`.

---

## Handoff checklist
1. Migrate DEFAULT_ADMIN + ADMIN together → governance + timelock; renounce EOA (VRYO-C1). The upgrade lever commands 3 powerful roles.
2. Decide the acceptable `assetDeployRatioBps` (live 60%, max 95%) — the dial on how much hard reserve is exposed as DAX depth (VRYO-M1).
3. Confirm the monitor counts `deployedAsset` correctly (in Round-Floor numerator, NOT double-counted in daxTVL) and is aware it can overstate vs the live pool reserve (VRYO-M1).
4. VLM is fully eliminated — confirmed zero roles on VRT/VCO/DAX. No dangling VLM reference can touch reserves/caps.
