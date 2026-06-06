# ValinityCapOfficer (VCO) — Accounting / Cap-Ledger Circuit · the backing ledger

Proxy `0x2f024159…0051C` → UUPS impl `0x294841f3…aec8b`. The **accounting officer**: it holds **no tokens** and moves no funds. Its entire job is the per-asset **collateral-cap ledger** (how much VY is backed/collateralizable per reserve asset), the **utilization** tracker, the **asset registry**, and the **USD/LTV/LTV-F valuation** views. Source==live **PROVEN by metadata IPFS hash equality** (`1220ba8bec80…`, solc 0.8.27/runs=100/cancun) at **git commit `e268bbd`** (workspace HEAD is one undeployed commit ahead).

> **Convention:** VCO has NO fund flow (zero token custody/transfer). This diagram shows the **cap-ledger conservation** (the golden rule) instead. The atomic question is *accounting integrity*, not where funds go.

> **GOLDEN RULE (system invariant):** VY **out of** a treasury (VYT/VRT, into circulation) → **cap ↑** ; VY **into** a treasury → **cap ↓**. **EXCEPT VLM & VRYO** (closed legs of VRT → net-zero). VCO exposes the mutators; the OFFICERS enforce the direction.

## Access model — NO permissionless state; OFFICER + ADMIN only

```
   PUBLIC: only VIEW functions (getTVL, getAssetMetrics, getSystemMetrics, getLTV, getAssetsSortedByLTVF,
           getTotalCirculatingVY, getAvailableCap, getUtilizedCap, getAssetCollateralized, effectiveFloor).
           No public function mutates state. VCO holds/transfers ZERO tokens.

   OFFICER_ROLE (the golden-rule actors — live: VLO, VAO, VYO, VBBO, buyback-2 0x3d9d78CD, VRYO, VGO)
      ├─ increaseAssetCap(asset, amt)        cap ↑   (VY out of treasury)
      ├─ addToHighestLTVFCap(amt)            cap ↑   on the MAX-LTV-F asset   ← VYO yield-mint sink
      ├─ decreaseAssetCap(asset, amt)        cap ↓   (floor-enforced)         (VY into treasury)
      ├─ processTransactionFees(amt)         cap ↓   on the MIN-LTV-F assets  ← VBBO fee/buyback sink (floor-enforced)
      └─ updateCapUtilization(asset, util)   set utilized (VLO loan open/close)

   ADMIN_ROLE (accounting-override surface — must go to timelocked gov)
      ├─ setAssetCap(asset, amt)   DIRECT arbitrary cap set — BYPASSES floor + officers + golden rule  ⚠ dominant accounting lever
      ├─ addAsset / removeAsset / setAssetConfig    registry curation
      ├─ setVAO                     repoint the USD-price oracle (LTV-F source)
      ├─ setAssetCapFloor / setCapSpreadDivisor     floor params
      └─ _authorizeUpgrade          replace all accounting logic

   LTV-F = (raw balanceOf(VRT) · VAO-TWAP-USD) / cap   →  picks which asset cap to raise (max) / lower (min)
   effectiveFloor = max(assetCapFloor, maxCap / capSpreadDivisor)   →  decrease/fees can't push a cap below it
```

## Ledger edge table (no tokens — state only)
| Mutator | State change | Direction | Actor (live) | Guard |
|---|---|---|---|---|
| `increaseAssetCap` | `_caps[asset] +=` | ↑ | VLO/VAO | OFFICER; overflow check |
| `addToHighestLTVFCap` | `_caps[maxLTVF] +=` | ↑ | VYO (yield mint) | OFFICER; needs ≥1 non-zero LTV-F (else revert) |
| `decreaseAssetCap` | `_caps[asset] -=` | ↓ | VLO | OFFICER; ≥ effectiveFloor |
| `processTransactionFees` | `_caps[minLTVF] -=` | ↓ | VBBO/buyback-2 | OFFICER; ≥ floor; UnprocessedFees if all at floor |
| `updateCapUtilization` | `_utilizedCaps[asset] =` | set | VLO | OFFICER; **no bound vs cap** (note) |

## Live state (today)
- assets/caps (VY): WETH 23,452 · WBTC 19,814 · PAXG 14,410 (USDC not cap-registered); all utilized=0 (no loans). floor 11,726 (=maxCap/2); circulating VY 371,202.
- **Valuation gap:** `_calculateTVL`/`_calculateLTVF` count only **raw `balanceOf(VRT)`** → TVL≈1.05 while VY-in-VRT≈10.5M; the **Uniswap V3 LP positions VRT holds are NOT counted** → on-chain TVL/LTV-F understate true backing. (Under workflow assessment: does this skew the highest/lowest-LTV-F selection?)
- OFFICER_ROLE: VLO, VAO, VYO, VBBO, buyback-2 `0x3d9d78CD`, VRYO, **VGO `0x0a6C2117` (unaudited)**. admin EOA `0x8310eA7E…` holds DEFAULT_ADMIN + ADMIN (not OFFICER).

**Verdict (RECONCILED, workflow `wdkc3ozml` — 97 agents, 10 surv/77 ref):** ✅ **CLOSED ledger — 0 permissionless-exploitable.** No permissionless path mutates any cap/registry/utilization; holds no tokens; arithmetic sound (overflow-checked increases, floor-guarded decreases, saturating reads). **VY CANNOT be under-backed via any permissionless/view/oracle path** — the only over-statement paths are ADMIN (`setAssetCap`/`_authorizeUpgrade`) or a malicious/buggy officer (trusted-actor). Residual: **2 VCO Mediums** — (a) **V3-LP undercount** (TVL/LTV-F read only raw `balanceOf(VRT)`, ~100× understatement; misrepresents backing in views + mis-routes LTV-F cap-selection; BUT conservative & reshuffle-only since amounts are officer-supplied → no under-backing; not fixed in newer version), (b) **VGO `0x0a6C2117` unaudited holds OFFICER_ROLE** (audit or revoke). Golden-rule conservation is enforced per-OFFICER (VYO ✅; verify VBBO/buyback-2 swap-then-cap atomicity, VLO migrateLoans-locked, VAO TWAP, VRYO closed-leg symmetry, **VGO**). VLM confirmed NOT an OFFICER (closed-leg moot). Dominant admin levers: **`_authorizeUpgrade`** > **`setAssetCap`** (the two under-backing paths) → both must be timelocked/gov-gated.

---

## ⚙️ Admin / governance powers — permanent at handoff
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| **Direct cap override** | `setAssetCap` | **arbitrary cap set, bypasses floor + officers + golden rule** → can overstate/understate backing at will | **timelock + gov; the #1 accounting lever** |
| **Upgrade** | `_authorizeUpgrade` | replace all accounting logic | codehash/upgrade delay; role to gov |
| Oracle source | `setVAO` | repoint USD-price oracle → skews all LTV-F | timelock; confirm = audited VAO |
| Registry | `addAsset`/`removeAsset`/`setAssetConfig` | poison/remove assets; removeAsset drops caps+utilization | curate; never remove an asset with outstanding utilization |
| Floor params | `setAssetCapFloor`/`setCapSpreadDivisor` | relax/tighten the floor | timelock |

→ See `findings/ValinityCapOfficer.md`. Both `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` (today `0x8310eA7E…4a09`) → timelocked gov. **The golden-rule conservation is the system invariant — verified per-officer (VYO ✓; pending VBBO/VLO/VAO/VRYO-symmetry/buyback-2/VGO).**
