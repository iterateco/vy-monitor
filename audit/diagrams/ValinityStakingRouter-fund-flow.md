# ValinityStakingRouter (VSR) — Fund-Flow Circuit · closes the DAX CC-1 / DAX-L1

Proxy `0x664b3A81…98C7` → UUPS impl `0xe00db9e6…71d4`. The user-staking vault: deposits VY (and WBTC/WETH/PAXG/USDC/ETH) into **DAX (VDAX LP)** + **Uniswap V2 (VY/USDC LP)**, locks for **≥30 days**, returns **EXACTLY principalVY** (+ yield paid by VYO). Source==live **PROVEN by metadata IPFS hash equality** (`1220cb0b8a8e…`, solc 0.8.27 / runs=1 / cancun). **LIVE & holding real funds: ~564,647 VY staked, 765,748 VDAX custody.**

> **Convention:** atomic-flow shows ONLY non-admin paths (admin removed at Fase 4 — closed-circuit must hold without it). Admin/governance powers in the separate box + permanence watchlist.

> **CC-1 KEYSTONE:** VSR is DAX's **sole liquidity-whitelist member** — its `dax.depositVYOnly`/`dax.withdraw` move `reserveVY` across ALL DAX pools. The **mandatory ≥30-day lockup** separates deposit from withdraw ⇒ **no atomic/same-block round-trip** ⇒ a public staker cannot move-and-revert a DAX pool to sandwich an officer's `minOut=0` tx (or extract the DAX-L1 single-sided LP leak). This is exactly the lockup guard the DAX audit required.

## Access model — permissionless entry, value-conserving exits

```
   DEPOSITS (nonReentrant, whenDepositsNotPaused, validTier, MIN_STAKE 100 VY)
   depositStake(tier, V, minVdaxOut, minUniLPOut)         [≤3 VY stakes/user]
        pull V VY ← msg.sender
        split V → V_dax (→ dax.depositVYOnly → VDAX) + V_uni (→ Uni V2 zap → UNI-LP)
        V4: retain 1% of each LP forever (lockedVdaxLP/lockedUniLP, uncredited)
        credit the 99% remainder; zap dust → buybackOfficer
        guards: V_uni>0 ⇒ minUniLPOut>0 REQUIRED (public Uni pool); minVdaxOut caller-set (DAX private)
   depositAssetStake(asset, amt, tier, minLPOut) / depositETHStake(tier,minLPOut)  [unbounded asset stakes]
        pull asset ← msg.sender (ETH→WETH)
        USDC → Uni V2 LP ; else dax.swapExactIn(asset→VY, minOut=0) → dax.depositVYOnly → VDAX
        guard: lpAmount < minLPOut ⇒ revert (protects staker)

   WITHDRAWALS (nonReentrant, whenWithdrawalsNotPaused, block.timestamp ≥ unlockTime)
   withdrawStake(stakeId, minVyOut)
        burn VDAX (dax.withdraw) + UNI-LP (removeLiquidity + USDC→VY) → vyOut
        S1 floor: vyOut < minVyOut ⇒ revert (BEFORE asking YO to top up)
        loss  → yieldOfficer.topUpPrincipal(shortfall)
        gain  → buybackOfficer (excess)
        PAY EXACTLY principalVY → msg.sender
   withdrawAssetStake(stakeId, minAssetFromLP)
        burn LP → try exact-out VY→asset → {happy: 100% asset | mixed: asset+VY@spot | VYO tops up gap}
        asset/ETH → msg.sender ; mixed VY → msg.sender ; surplus → buybackOfficer

   ── NO caller-supplied recipient. Every non-admin exit ∈ {msg.sender, buybackOfficer}. ──
   ── LP custody (765k VDAX + UNI-LP) NEVER leaves except dax.withdraw/removeLiquidity back INTO VSR. ──
   ── VSR holds 0 raw VY between txs (confirmed live). ──
```

## Edge ledger (non-admin)
| Edge | Token | Destination | Gate / guard |
|---|---|---|---|
| stake principal return | VY | **`msg.sender`** (EXACTLY principalVY) | unlockTime + minVyOut |
| asset stake payout | asset / ETH (+ VY mixed) | **`msg.sender`** | unlockTime + minAssetFromLP |
| gain / surplus / zap dust | VY / asset | **`buybackOfficer`** | — |
| loss top-up (inbound) | VY / asset | from **yieldOfficer** → VSR | reverts if YO can't cover |
| LP mint/burn | VDAX / UNI-LP | DAX / Uni ↔ **VSR self** | held in contract |
| pulls | VY / asset | from `msg.sender` | — |

## CC-1 / DAX-L1 discharge
```
   reserveVY-moving ops: dax.depositVYOnly (deposit) and dax.withdraw (withdraw) — OPPOSITE directions.
   They are separated by ≥30 DAYS (unlockTime). nonReentrant blocks composing them in one tx.
   ⇒ NO atomic / same-block buy-then-revert primitive on reserveVY ⇒ officer minOut=0 NOT sandwichable via VSR.
   ⇒ DAX-L1 single-sided in/out leak requires atomic round-trip → NOT extractable (30-day directional exposure instead).
   Asset paths: deposit = swapExactIn(asset→VY)+depositVYOnly (same direction, no reverse);
                withdraw (≥30d later) = withdraw+swapExactIn(VY→asset) — bounded matured-stake settlement, not a primitive.
   Residual: internal minOut=0 swaps (L1312 asset→VY, L1814 VY→asset dump) + minVdaxOut-may-be-0 on depositVYOnly
             → bounded MEV on the STAKER's own mint/payout, mitigated by minLPOut/minUniLPOut/minVdaxOut. Not a protocol drain.
```

**Verdict (RECONCILED, workflow `w5etym0g7` — 69 agents, 12 surv/48 ref):** ✅ **CLOSED in the non-admin path** — every exit ∈ {msg.sender, buybackOfficer}; no caller-supplied recipient; LP custody stays in-contract; 0 raw VY between txs. **0 permissionless-exploitable.** **CC-1 / DAX-L1 DISCHARGED by the ≥30-day lockup** (deposit↔withdraw non-atomic, opposite-direction) + the principal-clamp routing all redemption surplus to BBO (staker has no profit leg) + admin-frozen index. "Exactly principalVY" value-conserving; YO top-up reserve non-drainable by any staker (minVyOut is msg.sender-scoped → self-sandwich is negative-EV). The entire residual risk is **admin-trust/centralization: 1 Critical (UUPS upgrade, DEFAULT_ADMIN) + 1 High (adminExtract) + 2 Med + 2 Low** — all resolved by a properly-structured handoff. Principal protection depends on **VYO solvency** (cross-contract obligation).

---

## ⚙️ Admin / governance powers — permanent at handoff
| Power | Function | Role | Effect | Handoff requirement |
|---|---|---|---|---|
| **Upgrade** | `_authorizeUpgrade` | **DEFAULT_ADMIN_ROLE** | **#1 DOMINANT LEVER (Critical)** — empty body, no timelock; replace all logic → drains the ENTIRE backing incl. the 37 locked VDAX, and can delete the lockup/invariant. Strictly broader than adminExtract. | **codehash + upgrade delay; role to timelocked gov; then renounce** |
| Extract LP | `adminExtract(bps,to)` | ADMIN | **#2 (High)** — pulls up to 100% of *distributable* LP (765k VDAX − 37 locked) to an **arbitrary `to`**; locked 1% protected; bricks withdrawals + drains YO reserve | **timelock + gov; per-period cap/cooldown; bound `to`** |
| Rescue | `rescueTokens(token,to,amount)` | ADMIN | arbitrary `to`, **blocks VDAX/UNI-LP**; bounded to dust (0 raw VY held) | timelock |
| Officers/venues | `setYieldOfficer/setBuybackOfficer/setVryo/setVaro` | ADMIN | repoint sinks/heartbeat | timelock; confirm = audited contracts |
| Registry | `addAsset/removeAsset/setMinStake` | ADMIN | curate stakeable assets | curate; no FoT surprises |
| Tiers | `setTierDuration` (30–365d floor) | ADMIN | lock durations (30d floor preserves CC-1 guard) | **never below 30d** |
| Pause | `adminPause` | ADMIN | halt deposits/withdrawals | — |
| Index | `adminSyncIndexes` / `adminSetApprovals` | ADMIN | resync index / set max approvals to DAX+Uni | timelock |

→ See `findings/ValinityStakingRouter.md`. **CC-1 closes here** (lockup). **`adminExtract` is the dominant handoff risk** (touches real LP). **Both `DEFAULT_ADMIN_ROLE` (upgrade) and `ADMIN_ROLE` (everything else)** must go to timelocked gov. Principal protection ⇒ **VYO solvency obligation**.
