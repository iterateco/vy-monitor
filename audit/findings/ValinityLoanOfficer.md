# Audit: ValinityLoanOfficer (VLO) — contract 6 of 18

> Reconciled with multi-agent adversarial workflow `wy5ct28gd` (71 agents; 20 confirmed / 12 refuted). **Verdict: CLOSED-non-admin.** Lending math verified sound (no tiny-payment extraction, no interest evasion, conservation `totalVyRelease == collateralReturned + interestCharged` exact). **One real Medium: `migrateLoans` cap-inflation asymmetry (admin-armed).** My A2/A3 watch-items cleared; A1 confirmed as the Medium.

- **Proxy:** `0x8Fd8d5eB23f520D9BF8863364Ed44dbb29769DE4` → **UUPS impl** `0xd72e3fb78209eea2df2820531e2beb4e2563a434`
- **Source:** `contracts/officer/ValinityLoanOfficer.sol` (1135 lines) · solc 0.8.27 · UUPS + AccessControl + ReentrancyGuardTransient
- **Role in flow:** the protocol's **lending officer** — holds **OFFICER_ROLE on VRT** (drives loans) and **OFFICER_ROLE on VCO** (cap inc/dec). It's the OFFICER_ROLE holder VRT delegates its loan exits to.

## Gate 1 — Source == Live ✅ (recompile-proven)
The on-disk deployment artifact is a **stale older build** (`numDeployments:2`, metadata `e0fb5e21…` ≠ live). The user **redeployed the latest VLO directly from the workspace** via another session, bypassing the artifact pipeline. I proved the workspace source IS live by **recompiling with Hardhat (solc 0.8.27)**: the recompiled **metadata IPFS hash is byte-identical to live** (`79ade5ae…`), and the bytecode matches live except the 2×20-byte UUPS `__self` immutable (@4937/@5473). Definitive. (This validates the recompile path for the remaining 🔴 contracts.)

## What it is — "rent-to-own" lending
A borrower locks **VY collateral** to borrow a **reserve asset** (WBTC/WETH/PAXG, or ETH via WETH) from VRT. Interest accrues per-second **on the collateral**; once accrued interest reaches the collateral the loan is **underwater** (fully consumed — "rent-to-own complete"). LTV = reserveBalance/cap (asset units per VY).

| Function | Access | Effect |
|---|---|---|
| `openLoan(asset, collateral)` | **permissionless**, nonReentrant | 1% fee VY→VBBO; pull net VY collateral→VLO→VRT; `VCO.decreaseAssetCap(net)`; `VRT.processLoan` sends principal asset to borrower (WETH→ETH via `.call`) |
| `increaseLoan(asset, addl)` | **permissionless**, nonReentrant, active | crystallize interest→carry; if underwater route whole collateral→VYT & reopen; merge new collateral |
| `repayLoan(asset, payment)` | **permissionless**, payable, nonReentrant, active | pull asset payment (ETH for WETH); `VRT.releaseLoan` returns VY; pro-rata: collateralReturned→borrower, interestCharged→VBBO; `VCO.increaseAssetCap(totalVyRelease)`; underwater branch→all VY to VYT |
| `liquidateUnderwater(asset, borrowers[])` | **permissionless**, nonReentrant | anyone liquidates genuinely-underwater loans; collateral VY→VYT; principal written off; cap NOT restored; no asset taken |
| `migrateLoans(MigrateLoanVars[])` | ADMIN | seed loans, pulling VY from admin |
| setters (`setInterestRatePerSecond` ≤~101% APR, `setLoanCapBps`, `setVryo`, `setProcessingFeePercentage`, `setProcessingFeeRecipient`, `setInterestRecipient`, `setUnderwaterRecipient`), `_authorizeUpgrade` | ADMIN | config / UUPS |
| `receive()` | WETH only | rejects non-WETH ETH |

**Live state:** VCO `0x2f024159…`, VRT `0x06087789…`, VY `0x597b2952…`, VRYO `0xa95749f5…`. **processingFeeRecipient = interestRecipient = VBBO** `0x4b97d45d…`; **underwaterRecipient = VYT** `0xe58e29c9…` (correct). interest ≈**11.99% APR**, fee **1%**, loanCap **5%**. admin = `0x8310ea7e…` (shared KMS). VLO = OFFICER on VRT & VCO ✅.

## Gate 0 — Atomic fund flow / CLOSED-CIRCUIT (permissionless) — my read: CLOSED, no arbitrary-destination leak
Every value edge lands on a **fixed/role/borrower** destination — never a caller-arbitrary address:

| Edge | Token | Destination | Class |
|---|---|---|---|
| openLoan fee | VY | processingFeeRecipient (=VBBO, admin-set) | admin-set sink |
| openLoan collateral | VY | borrower→VLO→VRT (`processLoan`) | fixed internal |
| openLoan principal | asset | **borrower = msg.sender** (or ETH via `.call`) | msg.sender-bounded |
| repay payment | asset | borrower→VLO→VRT | fixed internal |
| repay return | VY | **borrower = msg.sender** | msg.sender-bounded |
| repay interest | VY | interestRecipient (=VBBO) | admin-set sink |
| underwater (repay/increase/liquidate) | VY | underwaterRecipient (=VYT) | admin-set sink |
| migrateLoans | VY (in) | admin→VLO→VRT | admin path |

→ **No permissionless path sends asset or VY to an attacker-chosen address.** Borrower-facing outflows are hard-bound to `msg.sender`; the three sink recipients (fee/interest/underwater) are admin-set, not caller-set. The interest model is "rent-to-own" by design (interest consumes collateral). **The whole risk surface here is the lending MATH** (rounding, cap symmetry, underwater detection) and **reentrancy** (the ETH `.call` to borrower) — which is exactly what the workflow's dedicated finders are stress-testing.

## Findings (reconciled): 0 Critical, 0 High, 1 Medium, 2 Low, 13 Info
| ID | Sev | Finding |
|---|---|---|
| **VLO-M1** | **Medium** | **`migrateLoans` cap-inflation asymmetry.** Normal open is cap-symmetric: `_depositCollateral` calls `vco.decreaseAssetCap(netCollateral)` (946), full repay calls `vco.increaseAssetCap(totalVyRelease)` (788) → net zero. But `_migrateLoan` (1008-1044) pulls VY from admin + `vrt.depositCollateral` (1023) and sets `loan.collateral`, **without ever calling `decreaseAssetCap`**. When the migrated borrower later repays, line 788 `increaseAssetCap` runs with **no prior offsetting decrease** → the VCO asset cap is permanently inflated by the migrated collateral, breaking the `Σcaps ≈ circulating-VY` backing invariant and over-stating allowable borrowing. **Admin-armed** (only ADMIN calls migrateLoans), permissionless-realized (borrower's repay completes it). **Fix:** `_migrateLoan` should `decreaseAssetCap(collateral)` to mirror the open path, OR migrated loans must be flagged so repay skips the restore. Confirm whether migration was paired with a manual cap adjustment at the time. |
| VLO-L1 | Low | **`increaseLoan` per-loan cap bypass.** `_checkLoanCap(additionalCollateral)` (598) validates only the *increment* against `loanCapBps`, not the cumulative `loan.collateral + additionalCollateral`. A borrower can open at the cap then `increaseLoan` repeatedly, concentrating one position well beyond the intended per-loan ceiling. Soft limit (still bounded by VCO floor/cap + VRT reserve balance); **permissionless**. Fix: check cumulative collateral. |
| VLO-L2 | Low | Same migrate cap-inflation viewed as long-run accounting drift (companion to M1). |
| VLO-CC1 | Info | Closed circuit: all outflows → {msg.sender, VRT, VBBO, VYT, feeRecipient}; no arbitrary destination; conservation exact. |
| VLO-I-math | Info | **Lending math verified sound** (was my A2 watch): pro-rata repay has no tiny-payment extraction and no interest-evasion; partial-repay interest rounds DOWN against the borrower (slightly underpays VBBO by dust, never the reverse); underwater boundary consistent across repay/increase/liquidate. |
| VLO-I-reentrancy | Info | **ETH `.call` to borrower safe** (was my A3 watch): `nonReentrant` (transient) covers it; state is conserved; cross-contract reentrancy via VRT/VRYO assumed-non-reentrant (VRT audited, VRYO best-effort try/catch post-state). |
| VLO-I-rate | Info | Admin interest rate retroactive to the un-crystallized elapsed period, bounded by `MAX_INTEREST_RATE_PER_SECOND` (~101% APR). Handoff consideration (a maxed rate force-underwaters loans → collateral to VYT). |
| VLO-I-liq | Info | `liquidateUnderwater` permissionless but only acts on genuinely-underwater loans (`totalInterest>=collateral` gate) and pays caller nothing → no grief incentive beyond gas. |
| VLO-I-fot | Info | Fee-on-transfer asset (e.g. PAXG) on repay could revert / require borrower overpayment due to exact-amount assumptions — but PAXG fee is currently 0 and the asset set is governance-controlled; keep FoT-active tokens out or handle explicitly. |
| VLO-I-misc | Info | `reinitializeV2/V3` external but `reinitializer(n)`-guarded (already consumed); `__gap` not reduced when V4 mapping appended (doc drift, no collision); raw `vyToken.transferFrom` return unchecked (safe under fee-whitelist invariant); WETH/ETH paths balanced (no stuck ETH / mismatch); underwater branches don't re-check `underwaterRecipient != address(0)` (setters/reinit enforce it). |

## Cross-contract dependencies
- **VRT (OFFICER_ROLE):** VLO drives processLoan/releaseLoan/applyInterest/depositCollateral — VRT audited (closed relative to roles). ✅
- **VCO (OFFICER_ROLE):** cap inc/dec + `getTotalCirculatingVY`/`getAssetCap`/`effectiveFloor` — VCO is 🔴 (need source); the cap math correctness partly depends on VCO (audit when reached).
- **VY token:** fee-on-transfer logic exists but VLO/VRT/VYT/officers are fee-whitelisted (verified in VY audit) → exact-amount math holds. ✅
- **WETH:** standard; ETH only accepted from WETH.
- **VBBO (interest+fee sink), VYT (underwater sink), VRYO (heartbeat):** audited / to-audit nodes.
- **Shared admin key** across VYT/VAO/MEVBot/VRT/VLO.

## Governance-handoff conditions (preliminary)
- `setInterestRatePerSecond` — even capped, confirm policy; a max rate force-underwaters loans → collateral to VYT.
- Confirm recipients before lock: processingFee+interest = VBBO, underwater = VYT (live values correct ✅).
- `_authorizeUpgrade` — can remove all invariants; timelock+multisig+UPGRADER_ROLE.
- `migrateLoans` — admin-only loan seeding; confirm not abusable post-handoff.

## Check-off
- [x] Source == live (**recompile-proven**: metadata hash identical; workspace source IS live)
- [x] Fund-flow mapped — CLOSED, no arbitrary-destination leak (my read)
- [x] Live-state read (recipients, rates, roles)
- [x] Multi-agent adversarial workflow reconciled (`wy5ct28gd`, 71 agents, 20 confirmed/12 refuted) — lending math verified sound; 1 Medium (migrateLoans cap asymmetry)
- [x] **User agrees → checked off 2026-06-01**

## VLO-M1 disposition (user, 2026-06-01)
`migrateLoans` was a **one-time bootstrap** to bring loans + users over from a **previous ecosystem**, and the power **will be locked in once governance takes over** (admin won't re-run it). So the cap-inflation asymmetry has **no future attack surface** post-handoff. Residual note: any *currently-outstanding* migrated loans, when repaid, still hit `increaseAssetCap` without a prior `decreaseAssetCap` — so the live VCO cap may already carry the migrated collateral as inflation. **Pre-handoff recommendation:** do a one-time reconciliation of `Σ VCO asset caps` vs. actual circulating-VY backing to confirm the migrated collateral didn't leave a standing overstatement (or confirm it was cap-adjusted manually at migration time). Accepted as a known, bounded, non-recurring item.

## Final tally (reconciled): 0 Critical, 0 High, **1 Medium** (VLO-M1 migrateLoans cap inflation — admin-armed accounting bug), 2 Low, 13 Info.
**No permissionless value-extraction survived refutation.** The closed circuit holds (no arbitrary-destination leak; conservation exact). The Medium is an **accounting-invariant** bug (cap can be inflated above backing via admin migration + borrower repay), not a direct theft — but it matters before handoff because it can let the reserve be over-borrowed against. **Recommended pre-handoff fix:** make `_migrateLoan` call `decreaseAssetCap` (mirror the open path), or confirm migrations were cap-adjusted manually. VLO-L1 (cumulative loan-cap bypass) is a permissionless soft-limit weakening worth fixing too.
