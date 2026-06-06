# ValinityAcquisitionOfficer (VAO) — Fund-Flow Circuit

Proxy `0x7a0E582479579e1423bc4f1DFD0750feA9282B01` → UUPS impl `0xc364f74e…`. Holds ~0 between acquisitions (pass-through). Pulls VY from VYT (holds **PRIORITY_OFFICER_ROLE** → can pull below the 350k cushion), swaps it, delivers the acquired asset to VRT.

> **Convention:** the circuit shows ONLY non-admin paths. Admin/governance functions (`rescueToken`, fee/config setters, `_authorizeUpgrade`) are *excluded by design* and listed in the box at the bottom + the permanence watchlist.

## Operational flow (non-admin)

```
                 ┌────────────────────────────────────────────┐
                 │  VYT  (sole VY minter, ~7.07M VY)           │
                 └───────────────────┬────────────────────────┘
                                     │ vyt.pullTokens(address(this), totalVY)
                                     │ VAO holds PRIORITY_OFFICER_ROLE → below-cushion OK
                                     │ bound: totalVY ≤ poolCapBps(25%) × VY V2 reserve   ⚠️ spot reserve (flash-inflatable)
                                     ▼
        ╔══════════════════════════════════════════════════════════════════════╗
        ║                    VAO  (pass-through, holds ~0)                       ║
        ║   entry: acquire(...)  — WALLET_ROLE only (bot 0x3c3816e9…1672)        ║
        ╚══════════════════════════════════════════════════════════════════════╝
            │                                  │
            │ fee slice (VY)                   │ swap leg  (the ONLY non-closed edge)
            │ fee = totalVY × feeBps/10000     │ for each step:
            ▼                                  │   forceApprove(router, FULL tokenIn balance)
   ┌──────────────────────┐                   │   router.call(backend calldata)   ← arbitrary call
   │ feeRecipient = VBBO  │  ⚠️ admin-settable │   require tokenOut balance rose > 0  ← NO minOut
   │ 0x4b97d45d…2be2f6    │  dest; fee ≤ 100%  │                                   │
   └──────────────────────┘                   ▼                                   │
                              ┌───────────────────────────────────────────────┐  │
                              │ whitelisted router (admin-curated set)         │  │
                              │ ⚠️ CONDITIONAL EDGE: with a compromised        │  │
                              │ WALLET_ROLE key or a malicious whitelisted     │  │
                              │ router, VY can be routed to an EXTERNAL pool/   │  │
                              │ address (returns only dust tokenOut to pass).  │  │
                              │ Closed ONLY IF (bot key honest) AND (whitelist │  │
                              │ curated). NOT closed by physics.               │  │
                              └───────────────────────────────────────────────┘  │
                                     │ acquired assetToBuy returns to VAO          │
                                     ▼                                             │
        ┌──────────────────────────────────────────────────────────────────┐     │
        │  assetBalance = balanceOf(assetToBuy);  require > 0                │◄────┘
        │  IERC20(assetToBuy).safeTransfer(address(vrt), assetBalance)       │
        │  ✅ SINK HARDCODED TO VRT — acquired asset CANNOT be diverted by   │
        │     parameters. This edge IS closed by physics.                   │
        └───────────────────────────────────┬──────────────────────────────┘
                                             │ + VCO.increaseAssetCap(capIncreaseAsset, totalVY)
                                             ▼   (accounting only, no value move; credited GROSS ⚠️ VAO-04)
                                        VRT (reserve treasury — audited next)
```

## Edge ledger — operational (non-admin)
| # | Edge | Token | Destination | Bound | Closed? |
|---|---|---|---|---|---|
| 1 | `vyt.pullTokens` → VAO | VY | VAO (self) | ≤ 25% spot VY reserve/tx (⚠️ flash-inflatable, VAO-09) | ✅ fixed-internal |
| 2 | fee transfer | VY | feeRecipient (**VBBO**) | `fee = totalVY×feeBps/10000`, feeBps ≤ 100% ⚠️ | ⚠️ admin-settable dest + 100% ceiling (VAO-10) |
| 3 | swap approve + `.call` | tokenIn (VY/intermediate) | whitelisted router → pool | full balance approved; output only `>0` | ⚠️ **CONDITIONAL** — leaks if WALLET_ROLE or router dishonest (VAO-01/02) |
| 4 | acquired asset → VRT | assetToBuy | **VRT (hardcoded)** | entire balance | ✅ **closed by physics** |
| 5 | cap credit | — (no value) | VCO accounting | `+= totalVY` (gross) | ✅ no value; ⚠️ accounting inflation (VAO-04) |

**Verdict:** ✅ **CLOSED (non-admin)** — verified by a 119-agent adversarial pass (0 Crit/High/Med, 2 Low, 3 Info). Edge 4 (the **acquired asset**) is closed by **physics** — the VRT sink is hardcoded with no setter. Edge 3 (the **VY-spend leg**) is closed by the **admin-curated router whitelist** + the WALLET_ROLE key — a trust boundary, not physics: it can *waste* spent VY (no min-out, ≤25%/tx) but cannot touch accumulated reserves or send the final asset anywhere but VRT. **No permissionless drain.** The only caller-arbitrary edge in the contract is `rescueToken`, which is ADMIN-only (handoff box below). This is *closed*, but leans on two settable trust anchors where VY/VYT leaned on none.

---

## ⚙️ Admin / governance powers — EXCLUDED from the circuit (handoff inventory)
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| Arbitrary token exit | `rescueToken(token,to,amount)` | ADMIN moves any ERC20 to any address | VAO holds ~0 between acquisitions; constrain or risk-accept |
| Fee ceiling | `setPriceDisparityFeeBps` / `setLTVDisparityFeeBps` | up to **100%** of pulled VY → feeRecipient | cap <100% in code/policy; confirm feeRecipient=VBBO |
| Router set | `setRouterWhitelist` | grants full-approval + `.call` target | curate to audited routers; freeze before lock |
| WALLET_ROLE | `setWalletAuthorization` | grants the `acquire()` hot key | **non-admin trust anchor** — keep minimal/hardened |
| Oracle pools | `setAssetTwapConfig` / `setWethUsdcTwapFeeTier` / `setWethAddress` | defines LTV-F price feeds | verify high-cardinality pools before lock |
| Size limiter | `setPoolCapBps` (≤25%) | per-tx VY ceiling (spot-reserve based) | keep conservative |
| Upgrade | `_authorizeUpgrade` (UUPS) | replaces all logic | codehash/allowlist/timelock + dedicated UPGRADER_ROLE |

→ See `findings/ValinityAcquisitionOfficer.md` (VAO-01…13) and the permanence watchlist in `diagrams/INDEX.md`.
