# ValinityYieldOfficer (VYO) — Fund-Flow Circuit · the yield engine + VSR backstop

Proxy `0xA245C9D2…92C9` → UUPS impl `0x08a4de6b…1c92`. The **yield engine**: mints VY from **VYT** (it's an OFFICER on VYT) to pay staking yield and to backstop VSR's principal guarantee; books the minted VY into **VCO's** LTV-F cap. Source==live **PROVEN by metadata IPFS hash equality** (`1220e8c4be47…`, solc 0.8.27 / runs=100 / cancun — the deployed source is the *uncommitted* workspace version). **LIVE: backs VSR's ~564,647 VY of stakes; 57,007 VY promised-yield reservation; 13 premium holders.**

> **Convention:** atomic-flow shows ONLY non-admin paths. ROUTER_ROLE (=VSR, audited) hooks are shown as the trusted-router boundary; admin/governance in the separate box.

> **MINT POWER:** VYO calls `vyt.pullTokens(this, amt)` which **MINTS VY**. The closed-circuit question is whether minted VY is (a) bounded and (b) backed — and whether any permissionless caller can redirect it.

## Access model — public claims (self-scoped) + trusted-router hooks

```
   PUBLIC (msg.sender-scoped, nonReentrant, whenClaimsNotPaused)
   claimYield(stakeId)            → accrue own VY-stake yield (≤ maxGross), settle 90/5/5
   claimAssetYield(stakeId)       → accrue own asset-stake yield (≤ maxYieldAsset), pull VY, swap→asset

   _settleYield / _pullAndSellForYield  (the 90/5/5 split on gross):
        pull 95% VY from VYT (mint)  →  90% → user (VY, or swap VY→asset to user)
                                         5%  → feeRecipient (VBBO) as VY
                                         5%  → stays in VYT (ecosystem fee, never pulled)
        book 95% pulled VY → capOfficer.addToHighestLTVFCap  (VCO backing)
        totalPromisedYield -= gross  ;  totalYieldClaimedVY[user] += gross (VARO pulls)

   onlyRouter (ROUTER_ROLE = VSR, trusted/audited)
   onDeposit / onAssetDeposit     → lock yieldBps (rate snapshot), reserve maxGross / 2×(prin+yield)
   onWithdraw / onAssetWithdraw   → settle final yield, release reservation
   topUpPrincipal(user,id,amtVY)  → pull amtVY from VYT → router (VSR) ; book VCO cap     [PRINCIPAL BACKSTOP]
   topUpAssetWithdrawal(asset,short,recipient) → pull VY, swap VY→asset (minOut=short) → recipient(=VSR)

   ── Public claims bounded by per-stake maxGross (≤9% of principal) + self-throttling master rate. ──
   ── Every non-admin exit ∈ {msg.sender/user, feeRecipient(VBBO), router(VSR)}. No arbitrary dest. ──
```

## Master rate (self-throttling — the mint governor)
```
   effective  = vsr.totalStakedVY() + totalAssetStakeVY
   freeVY     = vyt.getAvailableForYield() − totalPromisedYield        (reservation)
   usableFree = freeVY × 50%                                            (other 50% = permanent cushion)
   rate = (usableFree ≥ effective) ? 9% : sqrt(9%² × usableFree/effective)   ⇒ → 0 as VYT free VY drains
   yieldBps locked at deposit; maxGross = principal × yieldBps. Yield accrues linearly, capped at maxGross.
```

## Edge ledger (non-admin)
| Edge | Token | Destination | Bound / gate |
|---|---|---|---|
| yield user leg | VY or asset | **user** (msg.sender / stake owner) | ≤ maxGross; self-throttled rate |
| fee leg | VY | **feeRecipient (VBBO)** | feeBps ≤ 5% |
| ecosystem fee | VY | **stays in VYT** (not pulled) | 5% |
| VCO backing | (accounting) | `capOfficer.addToHighestLTVFCap(95%)` | every pull booked |
| principal backstop | VY / asset | **router (VSR)** / recipient | onlyRouter; router-supplied amount = genuine shortfall |
| mint source | VY | from **VYT** (`pullTokens`) | VYO=OFFICER; gated by VYT cushion/headroom |

## CC / backstop notes
```
   Yield mint is BOUNDED (per-stake maxGross ≤9%; master rate → 0 as VYT cushion drains) and BACKED
   (95% booked into VCO LTV-F cap; 5% ecosystem retained). Public callers can only claim their OWN accrued yield.
   topUpPrincipal/topUpAssetWithdrawal are onlyRouter (VSR), bounded by VSR's genuine shortfall, recipient=VSR.
   ⇒ VYO's "solvency" backing VSR = VYT mint-headroom + VCO cap-acceptance (cross-contract). If VYT can't mint,
     topUp reverts → VSR withdrawal reverts (DoS, not theft).
```

**Verdict (RECONCILED, workflow `wf_b7bb0f6d-03a` / resumed `w0ximbq0f` — 63 agents, 5 surv/49 ref):** ✅ **CLOSED in the non-admin path by physics** — VY minted at only 4 `vyt.pullTokens` sites; permissionless sinks (`claimYield`/`claimAssetYield`) are msg.sender-scoped, recipient-hardcoded to the user, and clamped to `maxGross`; topUps are onlyRouter (VSR). **0 permissionless-exploitable.** Mint **bounded** (9% cap, frozen snapshot, self-throttling rate→0 as VYT free-VY drains), **backed** (every pull booked 1:1 into VCO = the cap golden-rule increment), and **value-conserving** (reservation conservation-neutral; all clamp-to-0 on decrements → only biases the rate DOWN, never inflates). VSR backstop bounded+backed, only DoS-able (~12× live cover), not drainable. **Entire material risk = admin-trust; DOMINANT lever `_authorizeUpgrade`** (an upgrade inherits the live VYT OFFICER_ROLE → unbounded mint) > `setRouter`. Cross-deps: **VYT** (mint headroom/getAvailableForYield), **VCO** (the golden-rule conservation sink), **VARO** (when wired), **VSR** (trusted router).

---

## ⚙️ Admin / governance powers — permanent at handoff
| Power | Function | Role | Effect | Handoff requirement |
|---|---|---|---|---|
| **Upgrade** | `_authorizeUpgrade` | ADMIN_ROLE | **#1 DOMINANT LEVER** — empty-body authorizer; an upgrade inherits VYO's live **VYT OFFICER_ROLE** → `pullTokens(attacker, unbounded)` = **unbounded unbacked VY mint in one tx**. Strictly dominates setRouter; also repoints vyt/vco/dax/uni (no setters). | **codehash + upgrade delay; ADMIN_ROLE → TimelockController** |
| **Set router** | `setRouter` | ADMIN | **#2** — grants ROUTER_ROLE; a malicious router pulls VYT to a router-supplied recipient (weaker than upgrade) | **timelock + gov; ROUTER_ROLE must stay = audited VSR** |
| Fee dest | `setFeeRecipient` | ADMIN | redirect the 5% yield-fee stream | timelock; confirm = VBBO |
| Fee rate | `setFeeBps` (≤5%) | ADMIN | user always ≥90% | — |
| Pause | `pauseClaims` | ADMIN | freeze all yield claims (DoS) | — |
| Peers | `setVryo` / `setVaro` | ADMIN | heartbeat / referral target | confirm = audited |

→ See `findings/ValinityYieldOfficer.md`. **Both `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE`** (today `0x8310eA7E…4a09`) → timelocked gov. The mint-capable powers (`setRouter`, `_authorizeUpgrade`) are the dominant trust anchors. **VYO backs VSR's principal guarantee → its mint-headroom depends on VYT + VCO.**
