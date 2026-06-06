# ValinityMEVBotV2 (VMB) — Permissionless MEV Arb Circuit · VY→…→VY closed loop · **NEW VERSION (re-audit)**

Proxy `0x6f2F4580…4941` → UUPS impl **`0x98d7ee49…`** (was `0x16b66a22` in the 2026-06-01 audit — **upgraded**). A **permissionless** MEV arbitrage bot: anyone calls `executeArb`, the bot borrows VY from VYT, runs a keeper-supplied **route** (VY→…→VY) through whitelisted DEX routers, repays VYT 100%, and forwards all profit to the Buyback Officer. Source==live **PROVEN** by metadata-hash (build-info `4515c727` compiled the as-deployed source — byte-identical to the dirty workspace `.sol`, keccak `0x9daff5c3…` — to deployedBytecode metadata IPFS `12206c2d712d…` == live impl; solc 0.8.27/runs=100/cancun).

> **🔁 Complete redesign vs the prior audited version.** GONE: the arbitrary `router.call(callData)` + per-`(router,selector)` `routerSelectorAllowed` allowlist (the old CC-1 trust-core / Medium). NOW: the keeper supplies only `borrowVY` + a **typed** `Leg[]` route; the **contract itself builds every swap call** (recipient hardcoded = bot, `minOut = 0`, `amountIn` = 100% of balance). Strictly safer. `payoutBps`/`routerSelectorAllowed` remain only as inert deprecated storage slots (layout preservation).

## Atomic flow — `executeArb(borrowVY, Leg[] legs)` · permissionless · nonReentrant

```
 anyone ──executeArb(borrowVY, legs[])──▶ VMB   [!paused · borrowVY>0 · legs>0 · cooldown(7d) elapsed]
                                  │
   (best-effort) vgo.beginReward()  try/catch   ── vgo==0 live ⇒ skipped
   require legs[0].tokenIn==VY (start) && legs[last].tokenOut==VY (end)
   sweep pre-existing VY dust ─────────────────────────────────▶ buybackOfficer (VBBO)   ◀ hardcoded
   VYT ── borrowVY VY ──▶ VMB   [vyt.pullTokens(this, borrowVY); bot has VYT.OFFICER_ROLE]
                                  │
   FOR each leg (contract-built swap; router ∈ whitelist):
      amountIn = balanceOf(tokenIn)            (100% of balance; revert if 0)
      forceApprove(router, amountIn)
      _executeSwap → UniV2 swapExactTokensForTokens(to=this,minOut=0)
                   │ UniV3 exactInputSingle(recipient=this,minOut=0)
                   │ DAX  swapExactIn(recipient=this,minOut=0)        ◀ recipient HARDCODED = this
      require balanceOf(tokenOut) strictly ↑   (SwapOutputZero)
      require balanceOf(tokenIn) == 0          (TokenInNotDrained — full consume)
      forceApprove(router, 0)                   (clear allowance)
                                  │
   finalVY = balanceOf(VY); require finalVY >= borrowVY            (InsufficientVYToRepay)
   netProfit = finalVY - borrowVY; require netProfit >= minProfitVY (ProfitBelowMinimum; live floor = 70 VY)
   VMB ── borrowVY VY ──▶ VYT (repay)                              ◀ hardcoded
   VMB ── netProfit VY ──▶ buybackOfficer (VBBO)                   ◀ hardcoded
   require balanceOf(VY) == 0                                       (VYBalanceNotZero)
   nextEligibleAt[caller] = now + 7d
   (best-effort) vgo.payReward(msg.sender)  try/catch              ◀ keeper paid by VGO funds, NOT arb profit
```

## Exit set — every token destination (permissionless path)
| Token | Destination | Caller/keeper-controllable? | Guard |
|---|---|---|---|
| borrowed VY | **VYT** (repay, hardcoded) | NO | `finalVY >= borrowVY` or revert |
| profit VY | **buybackOfficer** (VBBO, hardcoded) | NO | `netProfit >= minProfitVY` floor |
| pre-borrow VY dust | **buybackOfficer** (hardcoded) | NO | swept before borrow |
| every swap output | **address(this)** | NO | encoder hardcodes recipient=this; `SwapOutputZero` |
| keeper reward | paid by **VGO** (external, from VGO funds) | — | best-effort try/catch; bot sends nothing to VGO |

**No caller/keeper-supplied recipient anywhere.** The keeper picks the *route* (which whitelisted pools, which token pairs) but the contract builds every call with `recipient = address(this)`. The only settlement exits are VYT + VBBO, both hardcoded.

## Principal is closed even against a malicious whitelisted router; **profit-above-floor is NOT (final leg)**
A whitelisted router receives `forceApprove(amountIn)` = full tokenIn balance. Suppose it steals tokenIn (sends to attacker) and deposits 1 wei `tokenOut` to pass `SwapOutputZero`, with `TokenInNotDrained` satisfied. If the stolen token is an **intermediate or the borrowed VY** → at the end `finalVY < borrowVY` → **`InsufficientVYToRepay` reverts → atomic rollback of `pullTokens`**. So **principal can never be diverted** — the repay + `VYBalanceNotZero` invariants are the real closure, not the whitelist.
**⚠ The exception is the FINAL leg (H-1):** `SwapOutputZero` checks a *strict increase*, not the *amount*. A malicious final-leg router (which outputs VY) can return exactly `borrowVY + minProfitVY` to the bot and pocket the rest to an attacker — repay (L319) and the floor (L330) both pass. **Bounded to `actualProfit − minProfitVY` (principal safe), but 100% of profit if `minProfitVY` were ever 0.** So the whitelist IS load-bearing for *profit* integrity — keep it to canonical routers and keep `minProfitVY > 0`.

## Backing / value conservation
- **Treasury made whole every time:** `borrowVY` pulled from VYT and repaid 100% atomically (else revert) — the bot can never end at a loss to VYT. No VCO cap interaction (borrow-and-return, not a circulating-VY-changing mint ⇒ no golden-rule cap event).
- **Bot retains nothing:** `VYBalanceNotZero` forces 0 VY at the end; no non-VY residual (every leg fully consumes tokenIn).
- **No unbacked mint without an upgrade** — `pullTokens` moves VYT's existing VY and is repaid; only `_authorizeUpgrade` (ADMIN) could install logic that pulls without repaying.

## Access model
```
 PERMISSIONLESS: executeArb (anyone; 7-day per-caller cooldown; 70 VY min-profit floor)
 ADMIN_ROLE (0x8310eA7E → governance):
   ├─ _authorizeUpgrade    ⚠ DOMINANT lever — upgrade inherits VYT.OFFICER_ROLE → could pull unbounded unbacked VY
   ├─ setBuybackOfficer    ⚠ repoint profit sink
   ├─ setRouterWhitelist   add/remove routers (contained by closed-loop invariants)
   ├─ setVgo               set keeper-reward engine (currently 0 = disabled; VGO unaudited)
   ├─ setMinProfitVY       anti-grief floor (live 70 VY)
   ├─ setCallerCooldown    1–30 day bound
   └─ setPaused            emergency stop
 NO rescue function. Bot holds 0 between txs.
```

## Live state (today)
- impl `0x98d7ee49`; vyToken `0x597b2952`, vyt `0xe58E29c9` (bot = VYT.OFFICER_ROLE ✓), buybackOfficer `0x4B97D45d` (= VBBO).
- **vgo = 0** (keeper rewards disabled — no VGO trust dependency live). execPaused=false. cooldown 7d. **minProfitVY = 70 VY** (active). payoutBps=100 (deprecated/inert).
- whitelist: **UniV2 Router02 + UniV3 SwapRouter02** only (DAX path coded but not whitelisted). 14 arbs; standing VY = 0.

**Verdict (RECONCILED, workflow `wc33q498d` — 64 agents, 26 surv / 29 ref):** ✅ **CLOSED for the permissionless flow — principal can never be exfiltrated, even by a malicious *intermediate-leg* router.** Swap calls are contract-built (recipient = bot, no calldata); the VY→…→VY loop + `SwapOutputZero` + `TokenInNotDrained` + `finalVY≥borrowVY` repay + `VYBalanceNotZero` make any *principal* diversion revert atomically; treasury made whole every tx; bot retains nothing. **Major design improvement** over the prior impl (arbitrary-calldata + selector allowlist removed). Residual (all admin/upgrade-gated, none permissionless): **C-1** `_authorizeUpgrade` dominant lever (inherits VYT.OFFICER_ROLE → **cushion-bounded ~6.65M VY/call**, repeatable — NOT unbounded); **H-1** malicious final-leg router skims profit-above-floor (`actualProfit − minProfitVY`; 100% if floor=0); **H-2** `setMinProfitVY=0`; **M-1** `setVgo` unaudited-VGO trust (vgo=0 live); **M-2** dual-role handoff trap; Lows (setBuybackOfficer, FoT/VY-whitelist fail-safe reverts).

---

## ⚙️ Admin / governance powers — permanent at handoff
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| **Upgrade (C-1)** | `_authorizeUpgrade` | replace logic; **inherits VYT.OFFICER_ROLE → cushion-bounded ~6.65M VY/call** (NOT unbounded; bot is standard officer, VYT CUSHION=350k/TARGET=7M), repeatable | **#1 lever** — TimelockController + real upgrade delay; migrate **both** DEFAULT_ADMIN + ADMIN then renounce |
| Reward engine (M-1) | `setVgo` | enable keeper rewards via (unaudited) VGO; VGO would get VYT.OFFICER_ROLE → could pull VYT during payReward (VMB itself unaffected) | **do NOT call until VGO audited**; timelock |
| Anti-grief floor (H-2) | `setMinProfitVY` | **0 removes the H-1 cap + enables farming** | keep > 0 (live 70 VY); add `vgo!=0 ⇒ floor!=0` guard |
| Router set (H-1) | `setRouterWhitelist` | a malicious **final-leg** router skims profit-above-floor (principal still safe) | governance-voted, canonical routers only; timelock + freeze |
| Profit sink (L-1) | `setBuybackOfficer` | divert arb profit (not principal) | timelock; keep = VBBO |
| Cooldown / Stop | `setCallerCooldown` (1-30d) / `setPaused` | griefing economics / halt | `setPaused` → fast guardian |
| ~~Rescue~~ | — | **none** | ✅ no standing balance; verify no upgrade adds one |

→ See `findings/ValinityMEVBotV2.md`. Both `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` (today `0x8310eA7E…4a09`) → timelocked governance; revoke both from the EOA.
