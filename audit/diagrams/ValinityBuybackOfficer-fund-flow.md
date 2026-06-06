# ValinityBuybackOfficer (VBBO) — Fund-Flow Circuit

Proxy `0x4B97D45d…` → UUPS impl `0xf311e729…`. The **buyback officer + system fee sink** (VY 1% transfer fee + VAO fee + VLO interest/fee land here). `executeBuyback()` retires VY and recycles reserve backing into VY. No external library. Source==live **byte-identical-bytecode proven** (workspace commit `b77d8d7`; metadata differs by comments only).

> **Convention:** circuit shows ONLY non-admin paths. Admin (`setDax`/`setVryo`/`setVgc*`/`setVgo`/`setDonationBps`/`setCooldown`/`setMinVy`/`setPaused`/`rescueToken`/`_authorizeUpgrade`) in the box at the bottom.

## Operational flow (permissionless — single entry)

```
   Anyone ──executeBuyback()──> [permissionless, nonReentrant]
      │  gates: !execPaused; vgo.beginReward() (if set); cooldown(2h); vyBal >= minVyToExecute(1000)
      │
      │  [1] DONATION (best-effort try/catch; CURRENTLY DISABLED: vgcToken=0)
      │        this.__donateVGCStep(vyBal*donationBps/1e4):
      │           VY ──swap(DAX, minOut=0)──► VGC (to self)
      │           pool.flash(this,0,0) ─► uniswapV3FlashCallback pays VGC ─► vgcUniV3Pool LPs
      │  [2] pick asset = largest VCO cap (headroom = cap − effectiveFloor)
      │  [3] vyUse = min(vyBal, headroom)
      │  [4] withdrawAmount = vyUse × reserve(asset in VRT) / cap     (exact LTV); snapshot preAssetBal
      │  [5] burn:  vyUse VY ───────────────────────────────────────► VYT  (retired)
      │  [6] pull:  ◄── withdrawAmount asset ── vrt.withdrawForBuyback([asset],[amt], recipient=THIS)
      │  [7] vco.decreaseAssetCap(asset, vyUse)                       (ONE-WAY, never restored)
      │  [8] swap:  asset ──swapExactIn(DAX, minOut=0, recipient=THIS)──► VY   (bought VY KEPT for next cycle)
      │  [9] INVARIANT: revert if asset balance after > preAssetBal   (closed circuit; delta semantics)
      │  [10] vryo.execute()
      │  [11] lastExecuteAt = now
      │  [12] vgo.payReward(msg.sender)  (best-effort try/catch) ── gas refund + bonus ──► msg.sender
      ▼
   Every sink hardcoded: burn→VYT, asset→self, swap out→self, VGC→vgcUniV3Pool. NO arbitrary-'to'.
   Hard-wired route: VRT ─asset─► THIS ─asset─► DAX ─VY─► THIS.
   Risk = the minOut=0 DAX swaps (CC-1: safe ONLY if DAX permissioned) + buyback economics, NOT redirection.
```

## Edge ledger — operational (permissionless)
| # | Edge (line) | Token | Destination | Class |
|---|---|---|---|---|
| 1 | burn (424) | VY | **VYT** | fixed-internal |
| 2 | withdrawForBuyback (431) | asset | **address(this)** (from VRT) | fixed-self |
| 3 | swap asset→VY (489) | VY | **address(this)** (kept) | fixed-self |
| 4 | donation swap (523) | VGC | **address(this)** | fixed-self (dormant) |
| 5 | flash donate (566) | VGC | **vgcUniV3Pool** LPs | fixed-pool (dormant) |
| 6 | VGO reward (463) | gas/bonus (from VGO) | **msg.sender** | bounded reward |
| — | forceApprove (488,522) | — | DAX only | bounded |
| — | rescueToken (655) | non-VY only | arbitrary `to` | **ADMIN — excluded** (blocks VY) |

**Verdict (reconciled, `wrc1qyt6q`):** ✅ **CLOSED for all permissionless callers** — all sinks hardcoded (VYT/self/DAX/pool); `rescueToken` admin-only + blocks VY. Buyback economics **value-conservative & non-drainable** permissionlessly. 0 Crit/High, **1 Medium (VBBO-M1/CC-1: `minOut=0` DAX dependency** — no-MEV guarantee fully delegated to DAX permissioning; not a redirect; rate-limited 2h + size-bounded; **hard prerequisite = audit DAX before handoff)**, 1 Low (VGC donation swap, dormant), rest Info. No VBBO-internal fix (minOut=0 baked in by design).

---

## ⚙️ Admin / governance powers — EXCLUDED from the circuit (handoff inventory)
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| **Swap venue** | `setDax` | **HIGHEST-value knob** — the minOut=0 swap venue; a malicious/mis-set DAX drains every buyback | strongest control (timelock/allowlist); confirm = live DAX |
| VRYO ref | `setVryo` | the `execute()` callee each cycle | confirm = live VRYO |
| Donation | `setVgcToken`/`setVgcUniV3Pool`/`setDonationBps`(≤5%) | enables/sizes the VGC LP donation (currently disabled) | decide whether to enable; if so, JIT-capture is by-design ≤5% |
| Cadence | `setCooldown`(≤1d)/`setMinVyToExecute` | buyback frequency/size floor | confirm |
| Rescue | `rescueToken` | arbitrary `to` for **non-VY** strays (blocks VY) | governance trust (VBBO holds mostly VY) |
| Pause | `setPaused` | kill switch | — |
| Upgrade | `_authorizeUpgrade` | replace all logic incl. invariants | codehash/timelock + UPGRADER_ROLE |

→ See `findings/ValinityBuybackOfficer.md`. Source==live byte-identical-proven (workspace `b77d8d7`). **CC-1: the minOut=0 DAX dependency is the dominant item — carry exact DAX obligations to the DAX audit.**
