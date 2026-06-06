# ValinityReserveYieldOfficer (VRYO) — Fund-Flow Circuit

Proxy `0xA95749f5…` → UUPS impl `0x89f256f0…`. The **reserve-yield officer**: deploys ~85% of VRT's reserves into **VRT-owned** Uniswap V3 positions and recalls them to track `circulatingVY × deployRatio`. `V3ZapMath` inlined (no delegatecall). Source==live **metadata-hash proven** (VRYO = commit `c4bfc30`, meta `0c18431c…`).

> **Convention:** circuit shows ONLY non-admin paths. Admin (`setDeployRatio`/`setSlippage`/`setKeeperThreshold`/`setVlm`/`setPairFee`/`setPaused`/`reinitializeV2`/`rescueTokens`/`sweepUsdcDust`/`_authorizeUpgrade`) in the box at the bottom. **NB: even the admin movers (`rescueTokens`, `sweepUsdcDust`) settle only to VRT — NO arbitrary destination exists anywhere in the contract.**

## Operational flow (permissionless — single entry)

```
   Anyone ──execute()──> [permissionless, nonReentrant]
      │  preconditions: pairFees set, vlm != 0 (else revert)
      │  drift gate: skip BODY if |circVY − lastCircVY| < 2.5% (snapback hook still fires)
      │  target = circulatingVY(from VCO) × deployRatioBps(85%);  netDelta = target − capVRYO_total
      │
      ├─ netDelta > 0  ──_executeDeployLoop──> (multi-pass, MAX 12, anti-concentration slice gap/3)
      │     pick asset w/ most VCO headroom → _deployIntoPair:
      │        vlm.refreshSnapshot + vlm.assertTwapAligned (±3% TWAP, try/catch→skip)
      │        vco.decreaseAssetCap(source, takeVY)
      │        ◄── pull source asset ── vrt.deployForYield([source],[takeVY×LTV], recipient=THIS)
      │        _zapIntoV3: swapRouter.exactInputSingle(recipient=THIS, minOut@slot0)
      │                    npm.increaseLiquidity ─► VRT's NFT  (amount*Min=0)
      │        on zap fail: vco.increaseAssetCap(source, takeVY) rollback
      │
      ├─ netDelta < 0  ──_executeRecallLoop──> (multi-pass)
      │     pick pair w/ largest pairPrincipal; recallAsset = lower-VCO-cap side (WW) / PAXG (PU)
      │     _recallFromPair:
      │        vlm.refreshSnapshot + assertTwapAligned
      │        liqToBurn = snap.liquidity × takeVY/pairPrincipal
      │        ◄── proceeds ── vrt.decreasePositionLiquidity(pairKey, liqToBurn, 0,0, deadline)
      │        reverse-zap: swapRouter.exactInputSingle(counterparty→recallAsset, recipient=THIS, minOut@slot0)
      │        pairPrincipal−=takeVY; capVRYO_total−=takeVY; vco.increaseAssetCap(recallAsset, takeVY)
      │        (yield = excess physical beyond takeVY×LTV → stays for VRT)
      │
      ├─ _settleAllToVRT: USDC→PAXG swap, then WETH/WBTC/PAXG ─► address(vrt)  + zero-balance InvariantViolation checks
      ▼
      └─ try vlm.snapbackHome{gas:1.5M}()  (best-effort; fires every call, throttled by VLM's 6h cooldown)

   Every token sink hardcoded: swaps→self, deployForYield→self(pull), increaseLiquidity→VRT NFT,
   decreaseLiquidity→VRYO, settle→VRT. NO arbitrary-'to' anywhere (rescueTokens has no dest arg).
   Risk = bounded MEV on slot0-anchored zaps + cap-accounting integrity, NOT redirection.
```

## Edge ledger — operational (permissionless) + admin movers
| # | Edge (line) | Token | Destination | Class |
|---|---|---|---|---|
| 1 | zap / reverse-zap / usdc swap (804,705,864) | token | **address(this)** | fixed-self |
| 2 | deployForYield recipient (555) | source | **address(this)** (pull from VRT) | fixed-self |
| 3 | increaseLiquidity (825) | token0/1 | **VRT's NFT** | fixed-internal |
| 4 | decreasePositionLiquidity (686,991) | token0/1 | **VRYO** → settled to VRT | fixed-internal |
| 5 | _settleAllToVRT (382,387,392) | WETH/WBTC/PAXG | **address(vrt)** (+ invariant checks) | fixed-internal |
| — | forceApprove (698,798,818-19,858) | — | swapRouter / npm only | bounded |
| — | rescueTokens()/sweepUsdcDust() | all | **address(vrt)** (ADMIN, NO arbitrary dest) | admin → VRT |

**Verdict (reconciled, `wy9fa82g7`):** ✅ **CLOSED — no arbitrary-destination leak ANYWHERE** (permissionless or admin; confirmed exhaustively). 0 Crit/High/Med, **1 Low** = bounded no-redirect MEV on `execute()`'s slot0-anchored zaps (capped by VLM's ±3% TWAP band + 0.5% live slippage + 2.5% drift gate; attacker can't trigger at will). **Cap-accounting PASSED — no VLO-M1 inflation** (deploy/recall symmetric in VY units; per-asset WETH/WBTC caps self-correcting via deploy-highest / recall-lowest picker loop, floor-bounded). Cleared for handoff from VRYO's side, conditional on VCO confirming 6 obligations.

---

## ⚙️ Admin / governance powers — EXCLUDED from the circuit (handoff inventory)
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| Deploy ratio | `setDeployRatio` | ≤95%; fraction of reserves at risk in LP | confirm 85% intended |
| Slippage | `setSlippage` | ≤5%; **bounds execute MEV** | keep tight (live 0.5%) |
| Drift gate | `setKeeperThreshold` | ≤20%; rebalance eagerness | confirm 2.5% |
| VLM ref | `setVlm` | the TWAP-guard provider; mis-set ⇒ execute reverts (vlm==0) or trusts a bad VLM | confirm = live VLM |
| Pair fee | `setPairFee` | blocked while pair has live deployments | — |
| Pause | `setPaused` | halts body (snapback still fires) | — |
| Rescue | `rescueTokens()` / `sweepUsdcDust()` | unwind + settle **to VRT only** (no arbitrary dest) | ✅ safe by design |
| Upgrade | `_authorizeUpgrade` | replace all logic incl. invariants | codehash/timelock + UPGRADER_ROLE |

→ See `findings/ValinityReserveYieldOfficer.md`. Source==live metadata-proven (VRYO=`c4bfc30`); recorded solcInputHash stale; workspace 1 commit ahead.
