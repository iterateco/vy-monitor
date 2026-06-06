# Finding: Repo source ≠ live code for many contracts (match-gate correction)

- **ID:** VAL-002
- **Category:** operational / audit-integrity
- **Severity:** High (process) — auditing the wrong source would invalidate conclusions.
- **Status:** confirmed via on-chain selector gate (`audit/scripts/selector_gate.mjs`, read-only).

## What happened
Doing VYT (contract 2), live-state reads showed `paused()` and `pulledThisEpoch()` **revert** on-chain, yet my earlier Step A/B marked VYT "audit-ready (workspace==live)". Forensics proved the repo source is a **different contract** than what's deployed.

## Root cause — the earlier gate was not source-truthful
My Phase-0 reconciliation checked two things that are both true yet insufficient:
1. repo source == the artifact's embedded `solcInputs` source (Step A) ✅
2. artifact `deployedBytecode` == live runtime bytecode (Step B) ✅

It **never** checked **artifact source compiles to artifact bytecode**. For VYT they don't: the artifact's **ABI+bytecode describe the LIVE (UUPS) contract**, but its **embedded source (and the repo `.sol`) is an older non-upgradeable version**. So both checks passed while repo source ≠ live code. `verify_one.mjs` also had a bug (accepted an empty 0-byte `eth_getCode` result from a transient RPC hiccup as a pass) — now fixed.

## VYT specifics (proof)
Live `0xe58E…` is a **UUPS proxy** → impl `0x35a86beb…` (verified twice, stable).
| In repo source, NOT live | Live on-chain, NOT in repo source |
|---|---|
| `paused`, `pullEpochStart`, `pulledThisEpoch` | `pullTokensForAsset(address,uint256,address)` |
| `pullTokensWithPriority`, `emergencyWithdraw` | `getBalance`, `proxiableUUID`, `upgradeToAndCall` (UUPS) |
The artifact **ABI** matches the LIVE set (has `pullTokensForAsset`/`getBalance`/`upgradeToAndCall`; lacks `emergencyWithdraw`/`paused`). The repo `.sol` is the only VYT source present and it is stale. **We do not have the live VYT source in the workspace.**

## Source-truthful gate — coverage of repo-source functions present in LIVE bytecode
(selector presence; <100% can be regex noise for struct/overloaded params, but the low rows are unambiguous)

| Coverage | Contracts | Read as |
|---|---|---|
| **100%** | **ValinityToken**, ValinityAcquisitionOfficer, ValinityLoanOfficer, ValinityPortal | source fns all present in live |
| 93–96% | ValinityGasOfficer (96), ValinityFloorOfficer (93) | likely match; confirm (regex noise?) |
| **88%** | **ValinityReserveTreasury (VRT)** | ⚠️ borderline — P0 custody; must confirm |
| 47–71% (**SOURCE≠LIVE**) | VYT 47, ReserveYieldOfficer 52, YieldOfficer 51, VLM 55, CapOfficer 58, DAX 64, StakingRouter 68, ExchangeOfficer 71 | repo source is NOT the live contract |

## Impact on the plan
- **Contract 1 (VY) stands** — 100% selector coverage **and** byte-EXACT via a *correct* (non-empty) bytecode comparison; non-proxy. No change.
- **VYT and the whole 47–71% set cannot be audited from workspace source.** Need the **live impl's verified source** (Etherscan or Sourcify) per contract.
- **VRT (88%) and Gas/Floor (93–96%) need a rigorous confirm** before trusting workspace source.

## The rigorous gate going forward (self-contained, no deps)
Each `solcInputs/<hash>.json` is a complete solc standard-json. Compile it with solc 0.8.27 and compare the resulting `deployedBytecode` to the **live** runtime (mask metadata+immutables). If they differ → that artifact's source ≠ live (the VYT case), and we must fetch live source from Etherscan/Sourcify. This is the gold standard and replaces the artifact-bytecode proxy used in Phase 0. Selector-gate above is the cheap pre-filter.

## Needed from user
- An **Etherscan API key** (in `vy-monitor/.env` as `ETHERSCAN_API_KEY=…`) to pull verified live-impl source for the mismatched contracts — or confirm we may use **Sourcify** (no key) as the source. Etherscan now requires a key even for `getsourcecode`.
