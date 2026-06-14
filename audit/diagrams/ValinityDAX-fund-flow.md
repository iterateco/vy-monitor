# ValinityDAX (DAX) — Fund-Flow Circuit · **RE-AUDIT (+ reserve-officer asset injection)**

> ⚠️ **This OVERWRITES the prior DAX audit** (impl `0x8efde23e`). RE-DEPLOYED to impl `0x7c240521`. The **only material change is the new `RESERVE_OFFICER_ROLE` + `reserveInjectAsset`/`reserveExtractAsset`** (asset-only, VRYO-driven, for the [[ValinityReserveYieldOfficer-fund-flow]] redesign). The swap / AMM / LP / admin core is **unchanged** (build-info confirms).

Proxy `0xD256C672…` → UUPS impl `0x7c240521…` (12,457 B). The protocol's **private constant-product AMM**: N pools `{asset, reserveVY, reserveAsset}`, one basket LP token VDAX. Officers swap reserve-asset↔VY here. **No swap fee.** Source==live **PROVEN** (live impl metadata-IPFS == artifact == build-info `c3d525c0` compile of workspace `ValinityDAX.sol`+`VDAX.sol`, keccak match; HEAD `1aa24be`). solc 0.8.27 / runs=100 / cancun.

> **Convention:** DAX has NO permissionless entry — every function is whitelist- or role-gated.

## Access model — CLOSED relative to roles/whitelists (a permissioned vault)

```
   swap-whitelist {VBBO, VAO, VEO, StakingRouter, VGO, MEV bot}
      └─ swapExactIn(poolId, tokenIn, amountIn, minOut, recipient) [onlySwapWhitelisted, nonReentrant]   ── UNCHANGED
            constant product, NO FEE:  VY→Asset out=rAsset·in/(rVY+in) ; Asset→VY out=rVY·in/(rAsset+in)
            enforces minOut + InsufficientLiquidity ; value-conserving (k preserved, rounds in pool's favor)

   ★ NEW ── RESERVE_OFFICER_ROLE {VRYO only} ── ASSET-LEG ONLY (VY reserve NEVER touched, NO VDAX mint/burn)
      ├─ reserveInjectAsset(poolId, assetAmount)   [nonReentrant]
      │     pull asset safeTransferFrom(VRYO) → pool.reserveAsset += assetAmount   (single-sided depth; price drifts → MEV bot arbs)
      └─ reserveExtractAsset(poolId, assetAmount, recipient) → assetOut  [nonReentrant]
            revert if assetAmount > reserveAsset ; pool.reserveAsset −= assetAmount ; safeTransfer(asset, recipient)
            (recipient is arbitrary BUT role-gated; VRYO hardcodes address(vrt). The pool is never removed/compacted.)

   liquidity-whitelist {StakingRouter}: depositVYOnly / withdraw (pro-rata VDAX, both legs)   ── UNCHANGED
   POOL_CREATOR_ROLE {VARO} ‖ ADMIN: addPool(asset, vySeed, assetSeed)   ── UNCHANGED
   ── NO permissionless entry. ──

   CC-1 PIVOT (unchanged): officers (VBBO/VAO) swap minOut=0 trusting "no sandwich"; the whitelist includes VEO (public router)
   + StakingRouter ⇒ the no-sandwich guarantee rests on VEO + StakingRouter (discharged in those audits).
```

## Edge ledger (all gated — no permissionless edge)
| Edge | Token | Destination | Gate |
|---|---|---|---|
| `swapExactIn` out | asset or VY | `recipient` | swap-whitelist (value-conserving) |
| `withdraw` | VY | `recipient` | liquidity-whitelist (StakingRouter) |
| **★ `reserveInjectAsset`** | asset (in) | pool.reserveAsset | **RESERVE_OFFICER (VRYO)** |
| **★ `reserveExtractAsset`** | asset (out) | `recipient` | **RESERVE_OFFICER (VRYO → VRT)** |
| `adminExtractLiquidity` / `adminWithdrawRaw` | VY+asset | `recipient` | ADMIN |
| `adminInjectLiquidity` | VY+asset (in) | pool | ADMIN |
| `rescueTokens` | any | `to` | ADMIN (can desync reserves) |

**Asset-reserve drain levers:** ADMIN (`adminExtractLiquidity`, pro-rata) **and** RESERVE_OFFICER (`reserveExtractAsset`, asset-only, VRYO-only). VY reserves: only ADMIN or value-conserving swaps. The MEV bot is now (per the redesign) the intended rebalancer of single-sided injection drift — **verify it is swap-whitelisted** (the prior audit flagged a *stale* "MEV bot rebalances" comment; the redesign makes it load-bearing).

**Verdict (RECONCILED, workflow `wqm7zyrs0` — 26 agents, joint VRYO+DAX; 0 permissionless-exploitable):** ✅ **CLOSED relative to roles/whitelists — no permissionless entry, no DAX-internal break.** Swap/LP math sound & value-conserving (unchanged from `w91m0w9q5`). The new reserve surface is **asset-only, role-gated, reentrancy-guarded, bounded** (`reserveExtractAsset` reverts above the reserve; `reserveInjectAsset` only adds; VY reserve never touched). Residual: **H1** `RESERVE_OFFICER_ROLE` can drain pool ASSET reserves (never VY) to an arbitrary address — held only by VRYO (hardcodes VRT), treat as admin-equivalent; **H2** a DAX upgrade/`revokeRole` can strand VRYO's deployed assets (shared-KMS cross-bricking — migrate both under one timelock); **M3** `reserveInjectAsset` books nominal not balance-delta → PAXG over-count (VRYO compensates); M1 CC-1 (VEO+SR); Lows (adminExtract ledger-desync, updateSwapWhitelist DoS, carried LP/basket Lows). **VLM fully removed** (zero DAX roles). **MEV bot now swap-whitelisted** (rebalancer wired). See `findings/ValinityDAX.md`.

---

## ⚙️ Admin / role powers — permanent at handoff (the trust config IS the security)
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| **Swap whitelist** | `updateSwapWhitelist` | **#1 KNOB** — a malicious swapper sandwiches officers' minOut=0 flows | freeze to audited contracts; confirm the MEV bot is included (load-bearing for the new rebalancing) |
| **★ RESERVE_OFFICER_ROLE** | role grant | drain pool **asset** reserves to any address (asset-only, never VY) | grant ONLY to the audited VRYO (live: VRYO-only ✅); treat as admin-equivalent |
| Liquidity whitelist | `updateLiquidityWhitelist` | move prices / probe LP math | freeze to audited (StakingRouter) |
| Pool creation | `addPool` / POOL_CREATOR_ROLE=VARO | poison-asset into the shared basket | curate; VARO trust |
| Price levers | `adminInject/Extract/WithdrawRaw` / `rescueTokens` | move prices, desync reserves, arbitrary recipient | timelock |
| Upgrade | `_authorizeUpgrade` | replace all logic | codehash/timelock + UPGRADER_ROLE |

→ See `findings/ValinityDAX.md`. **VLM is fully removed** (holds no DAX role: RESERVE_OFFICER/swap-whitelist/ADMIN all false).
