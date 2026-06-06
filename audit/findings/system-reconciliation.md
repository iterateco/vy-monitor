# Finding: Workspace ↔ Mainnet source reconciliation (Step A, local)

- **ID:** VAL-000 (process gate)
- **Category:** operational / upgrade
- **Severity:** Informational as a gate — but surfaces **two real risks**: (a) `Admin.json` address list is stale/wrong; (b) most contracts' workspace source has moved ahead of the recorded deployment.
- **Status:** Step A ✅ (local). Step B (on-chain bytecode confirm via Alchemy) pending key.

## Method
`audit/scripts/reconcile_local.mjs` compares the **as-deployed source** (the exact solc standard-json in `deployments/eth_mainnet/solcInputs/<hash>.json` that produced the live bytecode) vs. the **current workspace source**. Drift is measured over each contract's **true import closure** (only Valinity `contracts/...` files actually reachable via `import` from the main file; OZ/npm deps version-pinned and excluded). System is **18 UUPS proxies, 42 impl entries** (heavy upgrade history).

## Result 1 — `Admin.json` addresses are STALE/WRONG (High, operational)
The hand-maintained `deployments/eth_mainnet/Admin.json` lists addresses that do **not** match the real deployed addresses in the deploy artifacts + OZ manifest. Example: it lists VY = `0x34d7…8F07`; the actual deployed VY is **`0x597b29520098d6aaca3B2e0D1a380315c9240454`**. The entire `Admin.json` set is unreliable — **do not use it as the address source of truth.** Authoritative addresses are the artifact `.address` fields (below), cross-checked by the OZ manifest proxy list.

## Result 2 — Source readiness buckets (closure-aware)

### 🟢 Audit-ready from workspace source — 6 (main file + full import closure EXACT/COSMETIC)
| Contract | Address | Note |
|---|---|---|
| ValinityToken (VY) | `0x597b29520098d6aaca3B2e0D1a380315c9240454` | EXACT, closure 0/0 |
| ValinityYieldTreasury (VYT) | `0xe58E29c947013B4CBCdb67f90d659c3894BE2974` | EXACT |
| ValinityReserveTreasury (VRT) | `0x06087789B7122fA92E7F9868B10A286Dd4e4C832` | COSMETIC (comments only) |
| ValinityGasOfficer | `0x0a6C21174d039f5D85dA93FCB3FE7ad5F5f5E827` | EXACT |
| ValinityPortal | `0xF612C21161F400AbA27A0ef18b030350898b7628` | EXACT |
| VDAX | `0xD985C0EA5394f9A1acece695885cbD5210d5A1f9` | EXACT |
→ These are the cleanest starting spokes — but **still pending Step B** (the artifact may lag the true on-chain impl).

### 🔴 DRIFT — workspace moved ahead of recorded deploy — 11 (audit from as-deployed source)
ValinityCapOfficer, ValinityLoanOfficer, ValinityAcquisitionOfficer, ValinityBuybackOfficer.v1, ValinityFloorOfficer, ValinityDAX, ValinityReserveYieldOfficer, ValinityYieldOfficer, ValinityExchangeOfficer, ValinityStakingRouter, ValinityLiquidityManager(+v3 backup).
- Some drift only in the **main file** (CapOfficer, YieldOfficer, ExchangeOfficer, StakingRouter, LiquidityManager — closure clean); others also have **dependency drift** (e.g. FloorOfficer pulls drifted CapOfficer+VRT+VYT).
- **The as-deployed source is fully recoverable locally** from `solcInputs/`, so these are auditable now — just from the as-deployed source, **not** the workspace. The newer workspace versions (e.g. VLM V4, YieldOfficer V5) get a **separate pre-deploy review**.

### ⚠️ NO-DEPLOYED-SRC — 2 (artifact is proxy-pointer only)
ValinityBuybackOfficer (`0x4B97D45d276084c1C5BDBd0aa29B417cE02bE2F6`), ValinityMEVBotV2 (`0x6f2F45804E58e3240A2fDE9857c0e4F754CC4941`). Artifacts carry only `address`/`implementation`/bytecode, no source bundle → recover impl via Step B, then source from the impl artifact / Etherscan.

## Why "latest in workspace" ≠ "what's live"
Confirmed: 11 of the in-scope contracts have a newer workspace version than the last recorded deployment. Auditing those from `contracts/` would audit code that isn't running. The reconciliation table tells us, per contract, **which source to read.**

## CRITICAL caveat → Step B is mandatory
A hardhat-deploy artifact reflects the **last deploy it recorded**. With **42 impl entries across 18 proxies**, upgrades clearly happened repeatedly; some may post-date the artifact. So even 🟢 rows are "workspace == *artifact*", not yet "workspace == *live chain*". **Step B certifies the live impl.**

### Step B procedure (Alchemy, one-time, read-only)
For each of the 18 UUPS proxies:
1. `eth_getStorageAt(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)` → **live impl address**.
2. Compare live impl to: (a) the manifest's 42 impl addresses, (b) the artifact-implied impl. If the live impl is **not** in the manifest → upgrade done outside the OZ plugin → **High finding** (manifest/storage-layout tracking is blind to it).
3. `eth_getCode(liveImpl)`, mask metadata trailer + immutables, match against the best `solcInputs` deployedBytecode → certifies which source is truly live.
4. Also read `proxiableUUID`/admin where relevant, and the live `DEFAULT_ADMIN_ROLE`/upgrade authority (feeds the roles matrix).

Output: `live-state-report.md` + a `Live-impl` and `Audit source` column appended to `reconciliation.md`. Only **closure-clean + Step B-confirmed** rows are cleared for local-only deep audit; everything else is audited from the certified-live source.
