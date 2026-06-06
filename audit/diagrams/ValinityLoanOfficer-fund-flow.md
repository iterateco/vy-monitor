# ValinityLoanOfficer (VLO) — Fund-Flow Circuit

Proxy `0x8Fd8d5eB23f520D9BF8863364Ed44dbb29769DE4` → UUPS impl `0xd72e3fb7…`. The **lending officer**: borrowers lock VY collateral to borrow reserve assets from VRT; interest accrues per-second and consumes collateral ("rent-to-own"). Holds OFFICER_ROLE on VRT + VCO. Source==live **recompile-proven** (metadata hash `79ade5ae…`).

> **Convention:** circuit shows ONLY non-admin paths. Admin (`migrateLoans`, setters, `_authorizeUpgrade`) in the box at the bottom + watchlist.

## Operational flow (permissionless, borrower-scoped)

```
   Borrower ──openLoan(asset, collateral)──> [permissionless, nonReentrant]
      │  1% fee (VY) ───────────────────────────────────► processingFeeRecipient (=VBBO)
      │  net VY collateral ──► VLO ──► VRT (depositCollateral)   + VCO.decreaseAssetCap(net)
      │  ◄── principal asset ── VRT.processLoan(asset, principal, net, borrower)
      ▼                                       (WETH path: VRT→VLO, unwrap, ETH .call→borrower)
   ── interest accrues per-second on collateral (≈12% APR); caps at collateral = "underwater" ──
      │
   Borrower ──repayLoan(asset, payment)──> [permissionless, payable, nonReentrant]
      │  asset payment ──► VLO ──► VRT (releaseLoan returns VY to VLO)
      │  pro-rata split of returned VY:
      │     collateralReturned ──────────────► borrower (msg.sender)
      │     interestCharged ──────────────────► interestRecipient (=VBBO)   + VCO.increaseAssetCap(totalVyRelease)
      │  [underwater branch: ALL collateral VY ─► underwaterRecipient (=VYT); principal written off; cap NOT restored]
      ▼
   Anyone ──liquidateUnderwater(asset, borrowers[])──> [permissionless, nonReentrant]
      │  only genuinely-underwater loans; collateral VY ─► VYT; principal written off; caller paid nothing
      ▼
   VRYO.execute()  (best-effort heartbeat after each op, try/catch)

   Every outflow → {borrower=msg.sender, VRT, VBBO, VYT, feeRecipient}. NO caller-arbitrary destination.
   Risk surface = lending MATH (rounding, cap symmetry, underwater detection) + the ETH .call reentrancy,
   not fund redirection. nonReentrant(transient) on all four mutators.
```

## Edge ledger — operational (permissionless)
| # | Edge (line) | Token | Destination | Class |
|---|---|---|---|---|
| 1 | open fee (994) | VY | processingFeeRecipient (=VBBO) | admin-set sink |
| 2 | open collateral (944,998) | VY | borrower→VLO→VRT | fixed-internal |
| 3 | open principal (964,971) | asset | **borrower** (or ETH `.call` 967) | msg.sender-bounded |
| 4 | repay payment (709,712) | asset | borrower→VLO→VRT | fixed-internal |
| 5 | repay return (774) | VY | **borrower** | msg.sender-bounded |
| 6 | repay interest (765) | VY | interestRecipient (=VBBO) | admin-set sink |
| 7 | underwater (625,726,851) | VY | underwaterRecipient (=VYT) | admin-set sink |
| 8 | cap dec/inc (946,788) | — | VCO accounting | internal |
| — | migrateLoans (1021) | VY (in) | admin→VLO→VRT | admin path |

**Verdict (my read, pending workflow):** ✅ **CLOSED for permissionless callers** — no asset/VY can reach an attacker-chosen address; borrower outflows are hard-bound to `msg.sender`, sinks are admin-set. The real audit work is the **lending math + reentrancy**, which the multi-agent pass is stress-testing.

---

## ⚙️ Admin / governance powers — EXCLUDED from the circuit (handoff inventory)
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| Interest rate | `setInterestRatePerSecond` | ≤ ~101% APR (capped); a max rate force-underwaters loans → collateral to VYT | confirm policy; timelock |
| Recipients | `setProcessingFeeRecipient`/`setInterestRecipient`/`setUnderwaterRecipient` | redirect fee/interest/underwater VY | confirm = VBBO/VBBO/VYT before lock (live ✅) |
| Loan cap | `setLoanCapBps` | max collateral per loan (5%) | confirm value |
| Loan seeding | `migrateLoans` | admin pulls own VY, sets loan state | confirm not abusable post-handoff |
| Upgrade | `_authorizeUpgrade` | replace all logic incl. invariants | codehash/timelock + UPGRADER_ROLE |

→ See `findings/ValinityLoanOfficer.md`. Source==live recompile-proven (metadata `79ade5ae…`); on-disk artifact is an older build (user redeployed from workspace).
