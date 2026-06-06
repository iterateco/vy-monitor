# ValinityLiquidityManager (VLM) — Fund-Flow Circuit

Proxy `0x920AbB09…` → UUPS impl `0xcB147742…`, DELEGATECALLs library `V3SnapbackGate` `0x5c3baf31…`. The **liquidity officer**: sole author of the system's Uniswap V3 positions, **minted directly to VRT** (permanent owner); VLM operates them as an NPM-approved operator and never holds the NFT. Source==live **metadata-hash proven** (VLM = commit `c4bfc30`, meta `d69e1a26…`; library meta `08a6c1e9…`).

> **Convention:** circuit shows ONLY non-admin paths. Admin (mintPosition, adminRebalance, burnPosition, configurePair, setters, rescueTokens, `_authorizeUpgrade`) in the box at the bottom + watchlist.

## Operational flow (permissionless)

```
   Anyone ──snapbackHome()──> [permissionless, nonReentrant]   (re-center oldest cooldown-eligible registered pair)
      │  silent-skip (return (0,0), NO revert) if: paused | no cooldown-eligible pair | TWAP-misaligned | uneconomic
      │
      │  1. pick pair with oldest lastRebalanceAt where now - lastRebalanceAt >= cooldown (6h)
      │  2. assertTwapAligned (|slot0 tick − TWAP tick| <= maxTickDeviationBps ±3%)   ──fail──► skip
      │  3. economic gate (V3SnapbackGate.check, VIEW, on TWAP price):
      │        allow = !inRange || nearBand || (yieldMgd >= costMgd)                  ──!allow─► skip
      │  4. VGO.beginReward()  (try/catch; skipped if msg.sender==vryo or vgo unset)
      │  5. _rebalance(pair, useCurrentTick=true):
      │        _closePosition:  npm.decreaseLiquidity ─► npm.collect(recipient=THIS) ─► npm.burn
      │        _zapForRebalance: swapRouter.exactInputSingle(recipient=THIS)   [minOut from slot0]
      │        _mint:           npm.mint(recipient = address(VRT))             ◄── NEW position owned by VRT
      │        (NO pull from VRT, NO push to VRT — residual sub-bp dust stays on VLM, consumed next cycle)
      │  6. VGO.payReward(msg.sender)  (try/catch)  ── gas refund + flat bonus ──► msg.sender
      ▼
   Anyone ──refreshSnapshot(pairKey)──> [permissionless, nonReentrant]
      │  throttled by minRefreshInterval (silent return); TWAP-guarded
      │  vrt.setPositionSnapshot / clearPositionSnapshot   (NO token movement)
      ▼
   Tokens never reach a caller-chosen address: mint→VRT, swap→self, collect→self, sweep→VRT (all hardcoded).
   Only msg.sender-facing value = VGO gas reward (bounded by VGO + 6h cooldown + economic gate).
   Risk surface = bounded MEV on the zap/mint (slot0-derived minOut), NOT redirection.
```

## Edge ledger — operational (permissionless)
| # | Edge (line) | Token | Destination | Class |
|---|---|---|---|---|
| 1 | mint (1083) | LP token0/1 | **address(vrt)** (position owner) | fixed-internal |
| 2 | zap swap out (1396) | token | **address(this)** (VLM) | fixed-self |
| 3 | collect (1040) | token0/1 | **address(this)** (VLM) | fixed-self |
| 4 | sweep (1295) — admin paths only at runtime | token | **address(vrt)** | fixed-internal |
| 5 | VGO reward (769) | (gas/bonus, paid by VGO) | **msg.sender** | bounded reward |
| — | approvals (1067-68,1390) | — | npm / swapRouter only | bounded |
| — | rescueTokens (524) | any | arbitrary `to` | **ADMIN — excluded** |

**Verdict (reconciled, `wlekavf32`):** ✅ **CLOSED for permissionless callers** — no token/LP value can reach an attacker-chosen address (mint→VRT, swap→self, collect→self, sweep→VRT all hardcoded; DELEGATECALLed `V3SnapbackGate` is view-only, no transfer/SSTORE). Sole residual = **Low** bounded MEV (VLM-L1) on `snapbackHome`'s slot0-anchored zap minOut, capped by the ±3% TWAP guard + 6h cooldown + **TWAP-priced** economic gate (the gate can't be cheaply flipped, and `computeMinOut` recomputes at the manipulated price so slippage doesn't stack). ≤4 cycles/day, <1% position value/cycle. 0 Crit/High/Med.

---

## ⚙️ Admin / governance powers — EXCLUDED from the circuit (handoff inventory)
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| Seed mint | `mintPosition` | pull seed from VRT (once/pair via `seedConsumed`), mint→VRT | one-shot; bounded by `seedAmount0/1` |
| Emergency rebalance | `adminRebalance` | manual re-center | confirm policy |
| Burn | `burnPosition` | close + sweep managed→VRT | — |
| Pair config | `configurePair`/`setRangeBps`/`setSlippage`/`setSnapbackPairs`/`setSnapbackParams`/`setSnapbackV4` | set pools, ranges, slippage, snapback set, vgo/vryo, nearBand | **confirm values + pool TWAP cardinality before lock** |
| Rescue | `rescueTokens` | arbitrary `to` | governance trust (VLM holds only transient dust) |
| Upgrade | `_authorizeUpgrade` | replace all logic incl. invariants | codehash/timelock + UPGRADER_ROLE |
| **MEV bounds** | `initialize` only (NO setter) | `twapInterval`(1800)/`maxTickDeviationBps`(300) — no one-tx setter; **retunable via UUPS upgrade** (governance keeps `_authorizeUpgrade`), NOT frozen forever | confirm ±3%/30-min as long-term defaults, OR ship a setter in an impl upgrade before lock (cheaper). Bounds constants are dead code. |

→ See `findings/ValinityLiquidityManager.md`. Source==live metadata-hash proven (VLM=`c4bfc30`); workspace is 1 ADMIN-only guard line ahead (`setSnapbackPairs` dedup), not yet deployed.
