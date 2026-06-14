# ValinityFloorOfficer (VFO) — Findings · **RE-AUDIT (permissionless UUPS redesign)**

**Address:** `0x79A902864d0Bb88DD5497B9Bec593d2ffb937867` (UUPS proxy) → impl `0x33c3DD5c0d815E328Ca840BeE9FFdC82159D2743` (10,853 B)
**Source==live:** PROVEN (gold standard, both legs) — live impl metadata-IPFS `12203281dfcde766b84f2fdd6e9cf626e739a1a0b85898df727ace87df5cfe10ffe0` == hardhat artifact deployedBytecode metadata == build-info `c3d525c0` compile of workspace `contracts/officer/ValinityFloorOfficer.sol` (662 ln, source keccak `0xc65077ba…` == workspace, git-clean HEAD `1aa24be`). solc 0.8.27 / runs=100 / cancun.
**Audit workflow:** `wu2ofpcrf` (joint VFO+VGO, 7 dimensions, 86 agents, adversarial 2-skeptic default-refute verification) — **39 raw → 37 survived / 2 refuted; 0 permissionless-exploitable; 0 permissionless conservation violations.**

> ⚠️ **OVERWRITES the prior VFO audit.** The old VFO (`0x3d9d78CD…`, NON-PROXY/NON-UPGRADEABLE, **operator-gated** `initiateFloor` with caller-supplied `SwapStep` calldata) is **DECOMMISSIONED**. A brand-new **UUPS proxy** was deployed at `0x79A9028…` and **all roles migrated** to it (VRT.BUYBACK_ROLE, VCO.OFFICER_ROLE, VGO.OFFICER_ROLE, VY-whitelist) and **revoked from the old** contract (verified on-chain). The new VFO is **PERMISSIONLESS** (anyone calls `executeFloor(uint256 flashAmount)`), routing is **HARDCODED** (no operator, no router whitelist, no caller-supplied calldata), and it additionally pokes `vryo.execute()` + pays a VGO keeper reward.

---

## Verdict

✅ **CLOSED relative to roles — no arbitrary-destination exfil in any non-admin path, even though `executeFloor` is now permissionless. Golden-rule cap conservation is TEXTBOOK-correct and caller-immune. 0 permissionless-exploitable findings, 0 permissionless conservation violations.**

The #1 question — *can an unprivileged caller make funds leave to an attacker address, or under-back VY?* — resolves **NO** (workflow VFO-CC-1..4, VFO-GR-1..4, VFO-PERM-1/2/6, both skeptics confirming):

- **Every token sink is hardcoded** (no caller-supplied recipient anywhere): VY → `vyt` (burn; no setter), reserve asset → `address(this)` (literal), USDC → `balancerVault` (repay), profit VY → `buybackOfficer` (VBBO, admin-set address — NOT caller). `executeFloor` takes **only** a `uint256 flashAmount`; the permissionless `caller_` is used **only** to label the `FloorExecuted` event, never as a recipient. No `delegatecall`/arbitrary `.call` exists (assembly is only the transient flash guard).
- **Golden rule textbook-correct & caller-immune:** burn `vyAmount` VY → VYT **==** `vco.decreaseAssetCap(asset, vyAmount)`; `withdrawAmount = vyAmount·reserve/cap` ⇒ `new_reserve/new_cap == reserve/cap` exactly (integer floor over-backs by dust, never under). Double-guarded: VFO pre-checks `vyAmount ≤ headroom` AND `VCO.decreaseAssetCap` independently reverts below `effectiveFloor`.
- **Permissionless redesign is safe:** profit → VBBO (not caller); a bad `flashAmount` (too large, or VY ≥ floor) just **reverts** via the atomic flash-repay; the minOut=0 V2/V3 swaps, if sandwiched, harm only the caller (revert) or reduce VBBO profit — they can **never** under-back the protocol (collateral release scales 1:1 with VY burned). Flash callback gated by `msg.sender==vault` + transient `_IN_FLASH_LOAN_SLOT` (no spoof/reentry). Keeper-reward farming is bounded (payReward fires only after a genuinely settled floor defense + VGO per-call cap + VGC epoch ceiling).

The **entire residual is admin/upgrade-trust + handoff** — the dominant lever being the UUPS upgrade gate amplified by VFO's bundled roles.

---

## Golden-rule / backing — TEXTBOOK CORRECT (workflow VFO-GR-1..4, all confirmed)
```
 burn vyAmount VY → VYT   ==   vco.decreaseAssetCap(asset, vyAmount)     [exact same amount]
 withdrawAmount = vyAmount · reserve / cap   (reserve = asset.balanceOf(VRT), cap = vco.getAssetCap(asset))
   ⇒ new_reserve/new_cap = reserve/cap EXACTLY ; integer floor over-backs by dust, never under-backs.
 DOUBLE-GUARD: VFO checks vyAmount ≤ headroom (cap − effectiveFloor) AND VCO.decreaseAssetCap reverts if newCap < effectiveFloor.
```

---

## Findings (reconciled with workflow `wu2ofpcrf` — both skeptics in agreement)

### VFO-C1 — `_authorizeUpgrade` is the master drain lever, amplified by 3 inherited roles · **Critical** (admin-trust/handoff; NOT permissionless)
`_authorizeUpgrade(address)` (L294) is `onlyRole(ADMIN_ROLE)`. Because the proxy **holds** VRT.BUYBACK_ROLE + VCO.OFFICER_ROLE + VGO.OFFICER_ROLE + VY-whitelist, a malicious UUPS implementation inherits all of them. Blast radius:
- **Reserve sweep (Critical, VFO-ADMIN-C1):** a replaced impl can call `vrt.withdrawForBuyback([all assets],[all balances], attacker)` → drains **100% of WBTC/WETH/PAXG/USDC reserves** to an arbitrary address (VRT line 337 transfers to the caller-supplied recipient; only VFO holds BUYBACK_ROLE).
- **Cap corruption / golden-rule break (High, VFO-ADMIN-C2 — one of the 2 conservation-flagged findings):** a replaced impl can call `vco.increaseAssetCap(asset, huge)` (VCO L440, OFFICER_ROLE, overflow-check only, **no upper bound**) → arbitrarily inflates the VY cap, breaking backing accounting.
*Precond: ADMIN_ROLE compromised / malicious upgrade. **Fix:** migrate DEFAULT_ADMIN+ADMIN to a timelock with a codehash/upgrade delay; do it **atomically with VRYO and DAX** (shared KMS — one key currently hits all of them). This is the #1 handoff item.*

### VFO-H1 — Venue/recipient setters can redirect the closed circuit's value flows · **High** (admin-trust)
`setUsdc` (L637), `setV2Router` (L613), `setV3Router` (L625), `setBalancerVault` (L604), `setV3Factory` (L619), `setV3Quoter` (L631), `setBuybackOfficer` (L581) are all `onlyRole(ADMIN_ROLE)`. A compromised admin can re-point USDC, the swap routers, the flash vault, or the profit recipient to attacker-controlled venues/addresses **without** a full upgrade — bypassing the hardcoded-sink property by changing what the "hardcoded" addresses are. *Bounded to admin-trust (not operator/permissionless). **Fix:** timelock all venue setters; freeze to canonical addresses + publish.*

### VFO-M1 — Backing-ratio reads use on-hand VRT balance only (excludes deployed-for-yield) — backing-quality MONITOR · **Medium** (conservative; NOT a leak; the 2nd conservation-flagged finding)
`reserve = IERC20(asset).balanceOf(address(_vrt))` (L397) counts only the asset **physically in VRT**. Since the VRYO redesign deploys part of the reserve into the DAX pools (`deployForYield`), the on-hand balance **understates** true backing. Effect: `withdrawAmount = vyAmount·reserve/cap` is computed against the smaller on-hand reserve, so VFO **under-withdraws** collateral relative to the full pro-rata share — i.e. it **over-backs** the remaining VY (conservative, safe direction). **Cap conservation stays exact** (cap still ↓ by exactly `vyAmount`); this only makes the live backing-ratio *read* diverge from true backing. **Same family as VRYO-M1 / the deployedAsset-vs-live-reserve divergence — MONITOR**, don't treat as a leak. *No fix required for safety; the monitor should reconcile on-hand VRT balance + VRYO `deployedAsset` against cap.*

### VFO-M2 — Handoff: migrate BOTH admin roles atomically; role-bundle concentration · **Medium** (handoff)
`DEFAULT_ADMIN_ROLE` administers `ADMIN_ROLE` (both granted to the KMS at `initialize` L289-290). If only one is migrated, the old key can re-grant itself the upgrade lever (VFO-ADMIN-M1). Separately, VFO concentrates VRT.BUYBACK + VCO.OFFICER + VGO.OFFICER + VY-whitelist behind a **single** upgrade gate (VFO-ADMIN-M2) — maximal blast radius per VFO-C1. *Fix: migrate DEFAULT_ADMIN + ADMIN together, then renounce from the EOA; verify on-chain.*

### Lows (all admin-trust / availability / bounded-MEV — none permissionless-exploitable)
- **VFO-L1 — `vryo.execute()` un-try/catch'd rollback (availability).** L451 `if (address(vryo)!=0) vryo.execute();` runs **after** flash repay (L426) and profit forward, but is **not** wrapped in try/catch — so a VRYO revert/pause rolls back the entire (already-settled) floor defense. Inconsistent with the best-effort VGO reward leg (which the code explicitly try/catches so "a VGO failure must never brick the floor defense"). **Liveness/grief only — no fund leak** (caller eats gas, retries; protocol state untouched). *Recommendation: wrap `vryo.execute()` in try/catch in a future impl. [VFO-PERM-5 / VFO-COUP-1]*
- **VFO-L2 — PAXG fee-on-transfer bricks PAXG floor defense (DoS only).** VFO sells `withdrawAmount` (L418), not the received balance; if PAXG ever enables its transfer fee, VFO receives `withdrawAmount·(1−fee)` but the V3 sell pulls the full `withdrawAmount` → revert. Clean atomic revert, **no partial burn / no under-backing**; the floor button is just unusable for PAXG while the fee is on. *[VFO-GR-6 / VFO-PERM-4]*
- **VFO-L3 — Sandwich of minOut=0 swaps skims would-be buyback *surplus* (protocol profit), not reserves.** A searcher can sandwich the public-pool V2 buy / V3 sell, capturing slippage that would otherwise become VBBO profit. **Cannot cause reserve loss or under-backing** (collateral release is rigidly proportional to VY burned). *[VFO-PERM-3]*
- **VFO-L4 — `rescueToken` does not block reserve assets, only VY (L659).** Admin can sweep any non-VY token (WBTC/WETH/PAXG/USDC) stranded in VFO. Blast radius ~0 (standing balances are 0 between txs). *[VFO-ADMIN-H1, downgraded from High]*
- **VFO-L5 — `setVryo` can install a malicious vryo whose un-try/catch'd `execute()` runs every callback** (admin-controlled griefing/reentrancy surface; the call site is post-state-settlement). *[VFO-ADMIN-H3, downgraded from High]*

### Positive validations (Info — confirmed by both skeptics)
Closed circuit PROVEN (VFO-CC-1: no caller-controlled recipient; VFO-CC-2: minOut=0 contained by atomic repay; VFO-CC-4: reentrancy closed). Golden rule holds & caller-immune (VFO-GR-1..4). Permissionless backing-safe (VFO-PERM-1), flash-spoof blocked (VFO-PERM-2), keeper-reward farming bounded (VFO-PERM-6). VGO reward leg correctly isolated — a VGO failure cannot brick the floor (VFO-COUP-2). UUPS storage layout consistent (VFO-ADMIN-INFO1).

---

## Handoff checklist
1. **Migrate DEFAULT_ADMIN + ADMIN (KMS `0x8310eA7E`) → timelocked governance, atomically with VRYO + DAX** (shared KMS), then renounce from the EOA. Add a codehash/upgrade delay (VFO-C1).
2. **Timelock all venue setters** (`setUsdc`/`setV2Router`/`setV3Router`/`setBalancerVault`/`setV3Factory`/`setV3Quoter`/`setBuybackOfficer`) and freeze to canonical (VFO-H1).
3. `setPaused` → fast guardian. `rescueToken` → timelock (VFO-L4).
4. Monitor on-hand VRT balance + VRYO `deployedAsset` vs cap (VFO-M1).
5. (Nice-to-have) wrap `vryo.execute()` in try/catch on the next upgrade (VFO-L1).
