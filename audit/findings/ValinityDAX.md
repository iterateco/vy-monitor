# ValinityDAX (DAX) — Findings · **RE-AUDIT (+ reserve-officer asset injection)**

> ⚠️ **OVERWRITES the prior DAX audit** (`w91m0w9q5`, impl `0x8efde23e`). RE-DEPLOYED to impl `0x7c240521`. The only material change is the new `RESERVE_OFFICER_ROLE` + `reserveInjectAsset`/`reserveExtractAsset` (asset-only, VRYO-driven). The swap / AMM / LP / admin core is **unchanged** (build-info confirms), so the prior conclusions on that core carry over.

**Address:** proxy `0xD256C672616f7c5DEE3e42a8199f121EE08401B7` → impl `0x7c2405212274b69c262e8de823a1826bfb763b3d` (UUPS).
**Source==live:** PROVEN (live impl metadata-IPFS == hardhat artifact == build-info `c3d525c0` compile of workspace `ValinityDAX.sol` 968 ln + `VDAX.sol` 166 ln, keccak match; HEAD `1aa24be`). solc 0.8.27 / runs=100 / cancun.
**Status:** ✅ RECONCILED with workflow `wqm7zyrs0` (26 agents, 6 dims joint VRYO+DAX; 35 raw → 13 survived / 6 refuted / 16 Low-Info). Verdict: closed relative to roles/whitelists; the new reserve surface is safe-by-design; 0 permissionless-exploitable. Tally (DAX side): 0 Critical · 2 High · 2 Medium · 3 Low.

## Summary

The protocol's private, VY-hardcoded basket DEX (every pool VY/asset, one shared VDAX LP). Swaps are whitelist-gated, constant-product, no-fee, value-conserving (unchanged + still sound). **New surface:** two asset-only primitives gated to `RESERVE_OFFICER_ROLE` (VRYO only), letting VRYO deposit/withdraw single-sided asset depth without a forced VY sale or a VDAX mint/burn.

- **Closed relative to roles/whitelists (PASS).** No permissionless entry. The new `reserveInjectAsset` only adds asset; `reserveExtractAsset` reverts above the reserve and never touches VY or VDAX. Both `nonReentrant`.
- **New lever:** `RESERVE_OFFICER_ROLE` can drain pool **asset** reserves (never VY) to an arbitrary recipient — held only by VRYO (which hardcodes VRT). Treat as admin-equivalent at handoff.
- **CC-1** still pivots to VEO + StakingRouter (discharged in those audits).

**Live:** RESERVE_OFFICER_ROLE = VRYO-only; MEV bot now swap-whitelisted (rebalancer wired); VLM holds zero DAX roles.

---

## Findings (preliminary — to be reconciled with workflow)

### DAX-H1 [High — role/admin] `RESERVE_OFFICER_ROLE` can drain pool asset reserves to an arbitrary address
[ValinityDAX.sol:927](../asdeployed/ValinityDAX/contracts/dex/ValinityDAX.sol#L927) — `reserveExtractAsset(poolId, assetAmount, recipient)` transfers up to the full `reserveAsset` of any pool to a caller-supplied `recipient`, gated only by `RESERVE_OFFICER_ROLE`. It is **asset-only** (VY reserves untouched, no VDAX burned) and currently held **only by VRYO** (which always passes `address(vrt)`). But the role is a powerful asset-drain lever: a malicious/compromised holder — or a malicious **VRYO upgrade** (VRYO holds the role) — could pull every pool's asset reserve to an attacker. **Handoff:** grant `RESERVE_OFFICER_ROLE` ONLY to the audited VRYO (live ✅); treat it as admin-equivalent; timelock VRYO's upgrade. (Ties to VRYO-C1.)

### DAX-H2 [High — admin/upgrade] DAX upgrade (or `revokeRole`) can strand VRYO's deployed assets
[ValinityDAX.sol:965](../asdeployed/ValinityDAX/contracts/dex/ValinityDAX.sol#L965) — DAX `_authorizeUpgrade` is ADMIN_ROLE (same KMS key as VRYO). A malicious DAX upgrade or `revokeRole(RESERVE_OFFICER_ROLE, VRYO)` permanently breaks VRYO's recall path: `reserveExtractAsset` reverts → VRYO's try/catch emits `RecallSkipped` → the deployed asset (live ~3.83 WETH + 0.099 WBTC + 0.326 PAXG, scaling with the deploy ratio) is **stranded** in the DAX, recoverable only via the DAX's own `adminExtractLiquidity` (admin path, outside VRYO). Availability/griefing, not a value leak. **Handoff:** the shared KMS admin means one key compromise hits both VRYO and DAX — migrate both under the **same** governance timelock; treat the pair atomically.

### DAX-M1 [Medium — CC-1, cross-contract] Officer `minOut=0` no-sandwich rests on VEO + StakingRouter
Unchanged from the prior audit: `swapExactIn` correctly gates to the swap-whitelist, but the whitelist includes VEO (public router) and StakingRouter, so the officers' `minOut=0` no-sandwich guarantee is discharged in **those** contracts (both audited ✅), not in DAX. Carried forward.

### DAX-M2 [Medium — accounting, by-design] Single-sided reserve ops shift price → arb dependency
`reserveInjectAsset`/`reserveExtractAsset` move only the asset leg, so they shift the pool price (k changes); the design relies on the **MEV bot** (now swap-whitelisted ✅) to rebalance the drift. This is intentional, but it means each VRYO deploy creates a predictable arb that the bot captures → VBBO. Confirm no other whitelisted party can front-run the bot for the arb (the value should route to VBBO, and the VY leg is never directly moved by the reserve ops). See VRYO-M1 for the backing-quality consequence.

### DAX-M3 [Medium — accounting, FoT] `reserveInjectAsset` credits nominal, not balance-delta → PAXG over-count
[ValinityDAX.sol:913](../asdeployed/ValinityDAX/contracts/dex/ValinityDAX.sol#L913) — `pool.reserveAsset += assetAmount` books the **nominal** request, not the received balance-delta. For FoT PAXG, the DAX's `reserveAsset` exceeds its actual token balance → the constant-product swap math over-estimates available asset and can revert at `safeTransfer` (the tail extractor is short), and `getPoolReserves` overstates the asset reserve (extends the pre-existing DAX-L2). **VRYO compensates on its side** (books the DAX's *real* balance gain, recall clamps to the real balance), so cap conservation + recall are unaffected, but the DAX's own ledger/AMM-pricing degrades for PAXG. Whitelisted-swapper-facing, not permissionless. **Fix on a future upgrade:** balance-delta accounting in `reserveInjectAsset` (mirror VRYO/the VDAO-DAX).

### DAX-L1 [Low — admin coordination] `adminExtractLiquidity` 100% can desync VRYO's ledger
[ValinityDAX.sol:791](../asdeployed/ValinityDAX/contracts/dex/ValinityDAX.sol#L791) — removing a pool VRYO has deployed into (basisPoints=10000) leaves VRYO's `capVRYO`/`deployedAsset` non-zero while `hasPool` is false → VRYO `execute()` early-returns and the ledger is stale (and globalCap conservation breaks until reconciled). Admin-coordination only; mitigated by `VRYO.rescueTokens()`. **Handoff:** coordinate pool removal with `rescueTokens` first.

### DAX-L2 [Low — admin DoS] `updateSwapWhitelist` can disable swaps / the rebalancer
[ValinityDAX.sol:731](../asdeployed/ValinityDAX/contracts/dex/ValinityDAX.sol#L731) — a malicious admin can remove VEO/VBBO/VAO/MEV-bot, DoS-ing routing + the new reserve-injection rebalancing (withdrawals use a separate liquidity-whitelist, so they're not blocked — the workflow corrected that over-claim). Grief, not a leak. Timelock.

### DAX-L3 [Low] Single-sided LP round-trip leak / basket non-standard-asset hygiene / addPool no-validation
Carried forward from the prior audit (the unchanged LP/swap core): a gated single-sided LP round-trip leak (StakingRouter-mitigated), basket non-standard-asset desync, and `addPool` no-validation (curate assets; POOL_CREATOR=VARO trust).

### DAX-Info [confirmed] VLM removed; MEV bot whitelisted
VLM holds **zero** DAX roles (RESERVE_OFFICER / swapWhitelist / ADMIN all false). The MEV bot is now swap-whitelisted — the redesign's "MEV bot rebalances" is live + intentional (resolves the prior audit's stale-comment operational defect).

---

## Handoff checklist
1. Keep `RESERVE_OFFICER_ROLE` = the audited VRYO only (live ✅); treat as admin-equivalent; timelock VRYO's upgrade (DAX-H1 ↔ VRYO-C1).
2. Freeze the swap-whitelist to audited contracts; confirm the MEV bot stays included (load-bearing for the new rebalancing) (DAX-M2).
3. Migrate DEFAULT_ADMIN + ADMIN together → governance + timelock; the admin LP levers (`adminExtract`/`rescueTokens`) keep arbitrary recipients.
4. CC-1: ensure VEO + StakingRouter remain the only public-facing whitelist members (DAX-M1).
