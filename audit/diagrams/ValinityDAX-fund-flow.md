# ValinityDAX (DAX) — Fund-Flow Circuit · the CC-1 lynchpin

Proxy `0xD256C672…` → UUPS impl `0x8efde23e…`. The protocol's **private constant-product AMM**: N pools `{asset, reserveVY, reserveAsset}`, one basket LP token VDAX (`0xd985c0ea`). Officers swap reserve-asset↔VY here. **No fee.** Source==live triple-confirmed (metadata `7598b902`).

> **Convention:** DAX has NO permissionless entry — every function is whitelist- or role-gated. The "operational" box below is what whitelisted officers/routers do; the admin box is governance powers.

## Access model — CLOSED relative to roles/whitelists (a permissioned vault)

```
   swap-whitelist {VBBO, VAO, VEO, StakingRouter, VGO}
      └─ swapExactIn(poolId, tokenIn, amountIn, minOut, recipient) [onlySwapWhitelisted, nonReentrant]
            constant product, NO FEE:  VY→Asset out=rAsset·in/(rVY+in) ; Asset→VY out=rVY·in/(rAsset+in)
            enforces minOut (SlippageExceeded) + InsufficientLiquidity
            pull tokenIn safeTransferFrom(msg.sender) → out → recipient (whitelisted caller's choice)

   liquidity-whitelist {StakingRouter}
      ├─ depositVYOnly(vy, recipient) → distribute vy pro-rata across ALL pools' reserveVY; mint VDAX = vy·supply/(2·ΣreserveVY)
      └─ withdraw(shares, recipient)  → burn VDAX, pro-rata VY+asset from ALL pools, convert asset→VY internally, return 100% VY → recipient

   POOL_CREATOR_ROLE {VARO} ‖ ADMIN
      └─ addPool(asset, vySeed, assetSeed) → new VY/asset pool (ARBITRARY asset; basket already holds LINK + 2 launched tokens)

   ── NO permissionless entry. NO whitelist-disable toggle. ──

   CC-1 PIVOT: officers (VBBO/VAO) swap with minOut=0 trusting "no sandwich". DAX enforces the whitelist correctly,
   BUT the whitelist includes VEO (public router) + StakingRouter (public staking → moves reserveVY across all pools).
   ⇒ the no-sandwich guarantee rests on VEO + StakingRouter, not on DAX. (Resolve in those audits.)
```

## Edge ledger (all gated — no permissionless edge)
| Edge (line) | Token | Destination | Gate |
|---|---|---|---|
| swap out (630/657) | asset or VY | `recipient` | swap-whitelist |
| withdraw (507) | VY | `recipient` | liquidity-whitelist |
| adminWithdrawRaw (564/572) | VY+assets | `recipient` | ADMIN |
| adminExtractLiquidity (834-835) | VY+asset | `recipient` | ADMIN |
| rescueTokens (764) | any | `to` | ADMIN (can desync reserves) |
| pulls (safeTransferFrom) | — | from `msg.sender` | gated callers only |

**Verdict (reconciled, `w91m0w9q5`):** ✅ **CLOSED relative to roles/whitelists — no permissionless entry, no DAX-internal break.** AMM/LP math **sound & value-conserving** (swap rounds in pool's favor; divisor-2 cancels; no honest round-trip profit). 0 permissionless-exploitable, **1 Medium (DAX-M1/CC-1 — cross-contract, lives in VEO+SR)**, 3 Low (LP single-sided round-trip leak; basket non-standard-asset desync incl. live FoT PAXG; addPool no-validation), rest Info. The CC-1 no-sandwich guarantee **pivots to VEO + StakingRouter** — discharge there. Stale "MEV bot rebalances" comment (live MEVBot not swap-whitelisted) = operational defect.

---

## ⚙️ Admin / governance powers — permanent at handoff (the trust config IS the security)
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| **Swap whitelist** | `updateSwapWhitelist` | **#1 KNOB** — adding a malicious/over-permissive swapper enables sandwiching officers' minOut=0 flows | **freeze to audited contracts; never add an unvetted swapper** |
| Liquidity whitelist | `updateLiquidityWhitelist` | a bad LP-whitelisted addr can move prices / probe LP math | freeze to audited (live: StakingRouter) |
| Pool creation | `addPool` / POOL_CREATOR_ROLE=VARO | poison-asset into the shared basket | curate assets; VARO trust |
| Price levers | `adminInjectLiquidity` (no ratio) / `adminExtractLiquidity` / `adminWithdrawRaw` / `rescueTokens` | move prices, desync reserves, arbitrary recipient | timelock; note stale MEVBot rebalancer |
| Pause | `updatePauseStatus` | halt swaps/deposits/withdrawals | — |
| Upgrade | `_authorizeUpgrade` | replace all logic | codehash/timelock + UPGRADER_ROLE |

→ See `findings/ValinityDAX.md`. **CC-1 resolves into obligations on VEO + StakingRouter** (the public-facing swap/liquidity whitelist members). The swap-whitelist membership is the system's permanent trust anchor.
