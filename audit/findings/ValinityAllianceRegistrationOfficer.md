# VARO — ValinityAllianceRegistrationOfficer — Findings

**Address:** proxy `0x514F0ABf411Dd63EDD92dAD9ceB7e39e0AeD259f` → impl `0xeC4B64014c041079dAc57a1CE698c1E539cA42b6` (UUPS) + DELEGATECALL lib `0x6A0E4A9D423CbdBC30dc9aE752469cb08d60bCa5`.
**Source==live:** PROVEN by metadata-IPFS-hash equality on BOTH impl + lib; `metadata.sources` keccak256 == workspace `.sol` keccak256 (byte-identical, git-clean HEAD `a85f449`). solc 0.8.27 / runs=1 / cancun.
**Status:** ✅ RECONCILED with workflow `wau2dte5v` (30 agents, 8 dims → adversarial verify → synthesis; 31 raw → 17 survived / 4 refuted / 10 Low-Info). Verdict aligned: closed-circuit confirmed, golden-rule unbreakable, permissionless surface minimal — all residual is admin/trust/handoff or operational.

## Summary

VARO is a paid-tier gateway + referral-revenue accountant + V-DAO launcher. It is the single biggest officer (1823 ln + 287 ln lib) but its fund movements are simple to bound:

- **#1 Closed-circuit (PASS).** Every token exit lands at VBBO (hardcoded, init-only), `msg.sender`, a `msg.sender`-derived address (`predictBuilder(msg.sender)`), the caller's bound V-DAO + its pools, or the AMM pools. **No exit accepts a caller-supplied arbitrary recipient. No `rescueToken`. No `setVbbo`/`setVy`/`setVyt`/`setVco`** (core sinks/sources are init-only immutable).
- **VY mint (PASS, golden-rule-correct).** The only mint is `_payOut`: `vyt.pullTokens(this, paid)` + `vco.addToHighestLTVFCap(paid)`. `pullTokens` reverts on shortfall and never partial-mints (verified against the as-deployed VYT), so the cap increment is exact and never over-stated. VARO is a standard officer → cushion-throttled. Custody invariant holds (VARO ends each tx with 0 VY).
- **Referral credit (PASS).** PULL credit = `(sourceCum_now − checkpoint) × bps`, checkpoint-idempotent across `settleMine`/`sweep`; bounded by real fees actually paid by referees × bps (≤99%). Self-dealing is net-negative (the referee must have paid the source fee in VY first).
- **Residual = trust:** dominant `_authorizeUpgrade`; un-checkpointed PUSH sources (`vpo`, `REVENUE_PUSHER_ROLE`); dependency trust (factory / V-DAO token / VDAO-DAX / hlFactory / CCTP / VPO).

**Live: fully dormant / un-wired** — holds none of its roles, factory/cctp/hlFactory unset, zero activity. Nothing is exploitable until wired; findings are code-level (for-when-wired) + handoff.

---

## Findings (RECONCILED — lead-auditor + workflow `wau2dte5v`)

**Severity tally: 1 Critical · 2 High · 5 Medium · 9 Low — ALL admin/trust/handoff or operational. ZERO permissionless-exploitable.** The 4 workflow refutations + my own analysis confirm: no non-admin path leaks principal to an arbitrary address, no permissionless unbacked mint, no referral double-credit.

### VARO-C1 [Critical — admin/upgrade, deferred-handoff] `_authorizeUpgrade` inherits every officer role
[ValinityAllianceRegistrationOfficer.sol:1822](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1822) — `_authorizeUpgrade(address) onlyRole(ADMIN_ROLE)`, no on-contract timelock. When wired, VARO holds VYT.OFFICER_ROLE (mint VY), VCO.OFFICER_ROLE (raise cap), VDAX POOL_CREATOR + swap-whitelist, VDAO-DAX POOL_CREATOR, VSR.VARO_ROLE, VGO.OFFICER_ROLE. A malicious upgrade weaponizes all of them (redirect `_payOut`, mutate accounting; mint is still VYT-cushion-bounded but a new impl can re-point the cushion-bounded mint to an attacker). Dominant lever, same family as VSR/VYO. **Handoff:** migrate BOTH DEFAULT_ADMIN_ROLE + ADMIN_ROLE atomically to governance + external TimelockController (plain OZ AccessControl, no built-in delay), then renounce the EOA.

### VARO-H1 [High — admin/trust] `setHlFactory` can redirect every user's CCTP $100
[ValinityAllianceRegistrationOfficer.sol:1593](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1593) + [:1100-1112](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1100) — `hlFactory` is admin-rotatable with only a zero-check; the CCTP `mintRecipient` is `hlFactory.predictBuilder(user)` passed straight to `depositForBurn` with no validation. A malicious/compromised admin-set `hlFactory` returns attacker addresses → **every** T3/T4/partner-withBuilder/`fundMyBuilder` caller's bridged `cctpActivationUSDC` (default $100) is minted to the attacker on HyperEVM, **no L1 recovery** (USDC is burned). Affects 4 permissionless entry points; aggregate loss unbounded across users. Per-user it's the user's own $100 (not protocol principal), so it does not break the closed circuit for protocol funds — but it is direct user loss. **Handoff:** confirm `hlFactory` is the canonical HyperEVM factory + timelock `setHlFactory`. (Workflow raised from my preliminary Medium → High.)

### VARO-H2 [High — admin] `setTierUsdcPrice` has no bounds
[ValinityAllianceRegistrationOfficer.sol:1797](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1797) — admin can set any tier to **0** (free) or `uint256.max`. `tier4Usdc=0` → free V-DAO launches that still consume the seeding/mint paths (flood both DAX legs with unbacked V-DAO supply); `tier1/2/3=0` → free registrations/sybil graph; huge values → DoS / overflow in `_usdcToAsset`. No floor/ceiling. **Handoff:** add a floor in policy + timelock; validate non-zero before lock. (Workflow raised from my preliminary Medium → High.)

### VARO-M1 [Medium — admin/trust] Un-checkpointed PUSH sources (`vpo`, `REVENUE_PUSHER_ROLE`)
- [:1249](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1249) `notifyReferrerPerpCredit` (gated to `vpo`); [:1271](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1271) `notifyInviteeRevenue` (`REVENUE_PUSHER_ROLE`).
Both credit `pendingVY` from a caller-asserted amount with **no checkpoint** (by design, documented L1266-1268: "pushers MUST report deltas and never double-send"). A compromised/buggy `vpo` or pusher can inflate a favored referrer's credit → claimable as freshly-minted VY. **Mitigated by the VYT cushion** (the inflated claim can't mint *beyond* the cushion; over-statement just reverts the claim or conservatively over-states the VYO liability counter) — so the workflow rated this **Low**. I keep it **Medium** because, within the cushion, the credit is real *unbacked* VY to an attacker-favored address. Treat `vpo` + every `REVENUE_PUSHER_ROLE` grantee as minter-adjacent: audited contracts only; consider a per-epoch push cap on upgrade. Live: `vpo`=0, no pushers.

### VARO-M2 [Medium — admin/MEV] `cctpActivationUSDC` has no upper bound + no per-call max
[ValinityAllianceRegistrationOfficer.sol:1577](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1577) (only `!=0` check) read live at [:1049](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1049)/[:1089](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1089). `fundMyBuilder` / the T4 `<T3` carve read `cctpActivationUSDC` at execution with **no caller max-amount** — an admin can raise it and MEV-order ahead of a user's tx so the user pays the inflated amount. Funds still go to the user's **own** builder (closed circuit preserved), so it's over-payment, not exfiltration. Other tiers use fixed `tierNUsdc` (safe). **Handoff:** cap it in policy; consider a `maxAmount` param on `fundMyBuilder`.

### VARO-M3 [Medium — operational] CCTP-fail + `hasBuilder` set before delivery → no retry/recovery
[ValinityAllianceRegistrationOfficer.sol:1100-1112](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1100) sets `hasBuilder[user]=true` right after `depositForBurn` (which only burns + returns a nonce; it does not confirm cross-chain delivery). If the bridge fails operationally (wrong `cctpHLDomain`, no relayer), the $100 is burned, `hasBuilder` stays true, and `fundMyBuilder` is permanently blocked ([:1048](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1048)) with **no recovery path** (no `rescueToken`, no flag reset). **Handoff:** validate `cctpHLDomain` + CCTP liveness before wiring; consider an admin `hasBuilder` reset on the next upgrade.

### VARO-M4 [Medium — economic, by-design] Referral mint magnitude at 95% bps
`MAX_BPS_OTHER`=99% ([:248](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L248)); VDAO default 95%. Each settled fee mints up to 95% of the referee's fee back as fresh VY (with a matching cap increase) — intended tokenomics (same family as VYO yield) and golden-rule-consistent, but a large ongoing VY-mint stream once wired. Cushion-guarded (can't mint beyond VYT free-VY). **Handoff:** size VYT cushion / set sane bps; protocol always keeps ≥1%.

### VARO-M5 [Medium — admin, irreversible] One-shot `setVgcDeployer`/`setVgcRecipient`
[:1601-1615](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1601) — one-shot, latched, zero-check only. The `vgcRecipient` becomes the permanent **house** (all direct-traffic referees bind to it → it earns the bulk of referral revenue at 95%) + the VGC-V-DAO creator (VEO V-DAO swap fees route to it) + tier-4. A wrong/compromised recipient permanently captures that economic position with no recovery short of a full VARO upgrade. (Workflow said High and claimed it gets `VYT.OFFICER_ROLE` — that is **incorrect**; bootstrap grants no external roles, only VARO-internal house/creator/tier state. Hence Medium, recoverable via upgrade pre-renounce.) **Handoff:** review both addresses before the one-shot calls.

### VARO-L1 [Low — design-review] Cached `vdaoDaxSecondPoolId` (not live-resolved)
[:1173-1174](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1173), used at claim [:1490-1491](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1490) + lib `donateToVdaoDax`. VARO caches the VDAO-DAX second-leg pool id at launch, whereas it resolves the **main** VDAX pool id LIVE on every call (because the main DAX re-indexes ids on removal). **Architectural inconsistency:** if the VDAO-DAX also re-indexes pool ids on removal, a stale cached id would donate claim payouts to the wrong pool. Depends on VDAO-DAX behavior (out of scope). **Handoff:** confirm VDAO-DAX pool-id stability (or that seeded pools are never removed) before relying on the claim donate path; mirror the live-resolution pattern if it re-indexes.

### VARO-L2 [Low] No slippage floor on the sub-$10 buyback legs (`minVyOut=0`)
T1/T2/T3-remainder/partner USDC buyback legs ([:720](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L720), [:786](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L786), [:1015](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1015), [:1066](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1066)) swap on public V2 with `minOut=0`. The user pays a **fixed** USD price and gets their tier regardless; the swap output goes to **VBBO**, so any sandwich diminishes the protocol's buyback (≤$10/tx), **not** the user's principal — the workflow's "user loses 90-99%" framing is incorrect. Negligible; design inconsistency vs the ETH/T4 legs which take a caller `minOut`. Documented.

### VARO-L3 [Low] Pricing oracle uses spot V2 (no TWAP)
[:635](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L635) `_usdcToAsset` composes VDAX spot × **V2 VY/USDC spot** (manipulable). Caller bounds (`maxAssetAmount`, `minVyOut`, `minVyOutForSeed`) protect the caller and the protocol seed at settle time → manipulation is caller-bounded; only the payment-sizing *quote* reads spot. Low.

### VARO-L4 [Low] `_usdcToAsset` two-step truncation can quote 0 for tiny amounts
[:648-649](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L648) — the overflow-avoiding two-step division truncates; for a microscopic-reserve new pool + a $0.50 quote the intermediate can floor to 0. UX/precision edge (a 0 quote only hurts the caller), not a security/exfil issue. Consider reordering (VY-first) or single-step with wider intermediate.

### VARO-L5 [Low] Trapped rounding dust (no `rescueToken`)
`_executeVDAOSplit` leaves bps-rounding dust at VARO with no exit ([:1179](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1179)). Safer than an arbitrary-dest rescue (deliberate); dust is permanently locked. Info/Low.

### VARO-L6 [Low — handoff process] DEFAULT_ADMIN_ROLE + ADMIN_ROLE on the same address
[:558-559](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L558). Revoking only ADMIN_ROLE at handoff leaves DEFAULT_ADMIN_ROLE able to re-grant it (and to grant `REVENUE_PUSHER_ROLE`). **Handoff:** revoke/migrate BOTH atomically (folds into VARO-C1).

### VARO-L7 [Low — by-design] `setHouse` locked after bootstrap
[:1565-1569](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1565)/[:1693-1695](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1693) — `house` is permanently locked to `vgcRecipient` after `bootstrapVGCVDAO`. Intentional (prevents mid-flight default-referrer rotation); recoverable only via UUPS upgrade. Set `house`/recipient correctly first.

### VARO-L8 [Low — by-design] ETH refund 23k-gas-cap reverts on expensive `receive`
[:1755-1761](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1755) — `_refundExcessEth` caps the refund call at 23k gas and reverts on failure (anti-grief). A smart-wallet with an expensive `receive` can't over-send ETH; use the USDC path. Acceptable.

### VARO-L9 [Low/Info — comment inaccuracy] `sweep` batch check runs after `beginReward`
[:1390-1432](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/ValinityAllianceRegistrationOfficer.sol#L1390) — the `MIN_SWEEP_BATCH` guard lives inside `sweepRange` ([VAROReferralSettleLib.sol:207](../asdeployed/ValinityAllianceRegistrationOfficer/contracts/alliance/VAROReferralSettleLib.sol#L207)), **after** `vgo.beginReward()`, contradicting the L1391-1392 comment ("cheap validation first"). The workflow called this "keeper gas griefing (Medium)" — but the caller IS the rewarded keeper (`payReward(msg.sender)`), and `SweepBatchTooSmall` only triggers when the caller themselves passes `count < 50` while ≥50 remain (whenever `remaining < 50` the call necessarily finishes the lap → no revert). So it is **self-inflicted** wasted gas on a reverted tx, not third-party griefing — downgraded to Low/Info. Optional: hoist the batch check before `beginReward` and fix the comment.

---

## Handoff / wiring checklist (surfaced for governance — not VARO bugs)
1. Grant VARO its roles only when ready: VYT.OFFICER_ROLE, VCO.OFFICER_ROLE, VDAX POOL_CREATOR + swap-whitelist, VDAO-DAX POOL_CREATOR, VSR.VARO_ROLE, VGO.OFFICER_ROLE — **atomically** (partial wiring = unsafe). Each is a privileged capability; audited-only.
2. Wire `vdaoFactory` (+ `factory.setVaro`), `hlFactory` (VARO-H1 — confirm canonical), `cctp` + `cctpHLDomain` (VARO-M3 — validate liveness), `vpo`, `vgo`, reserve assets (WBTC/ETH/PAXG), and `VEO.setVaro(VARO)` (T1 reverts until done).
3. Treat `vpo` + `REVENUE_PUSHER_ROLE` as minter-adjacent (VARO-M1) — audited contracts only; start with zero pushers.
4. Migrate DEFAULT_ADMIN_ROLE + ADMIN_ROLE together to governance + external timelock, then renounce the EOA (VARO-C1 + L6).
5. Validate non-zero tier prices + sane bps + bounded `cctpActivationUSDC` before lock (VARO-H2, M2, M4).
6. Review `vgcDeployer`/`vgcRecipient` before the one-shot calls (VARO-M5); confirm VDAO-DAX pool-id stability (VARO-L1).
7. Dependencies NOT yet audited — **ValinityVDAOFactory, ValinityVDAO token, VDAO-DAX, hlFactory, VPO** — audit before enabling T4/perp paths.
