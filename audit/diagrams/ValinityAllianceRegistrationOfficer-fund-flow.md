# ValinityAllianceRegistrationOfficer (VARO) — Atomic Fund-Flow Circuit

Proxy `0x514F0ABf…259f` → impl `0xeC4B64014c…42b6` (UUPS) + DELEGATECALL lib `0x6A0E4A9D…bCa5` (`VAROReferralSettleLib`, no own storage). Source==live **PROVEN** by metadata-IPFS-hash equality on BOTH the impl and the lib (deployment-json deployedBytecode meta == live; `metadata.sources` keccak256 == workspace `.sol` keccak256, byte-identical, git-clean HEAD `a85f449`). solc 0.8.27 / runs=1 / cancun.

> **Convention:** this diagram shows ONLY non-admin / permissionless paths — the closed-circuit proof must hold WITHOUT admin, because admin is being handed to governance. Admin/upgrade powers are in the separate trust-surface box.

VARO is a **paid-tier gateway + referral revenue accountant + V-DAO launcher**. The audit thesis: **every token exit lands at a protocol-determined or `msg.sender`-scoped destination — never an arbitrary/attacker address.**

## Intake circuit (payment → buyback / builder)

```
 T1 register ($0.50) / T2 referrer ($10)
   USDC path:  USDC(msg.sender) ─safeTransferFrom─▶ VARO ─V2 swapExactTokensForTokens(USDC→VY)─▶ VBBO   [minOut=0, sub-$10 = sandwich-uneconomical]
   ETH path:   ETH(msg.sender)  ─WETH.deposit─▶ VARO ─VDAX swapExactIn(WETH→VY, recipient=VBBO)─▶ VBBO   [minVyOut caller-supplied]
                                                       excess msg.value ─call{gas:23000}─▶ msg.sender (refund)
   side-effects: veo.register(msg.sender) ; _bindReferrer(msg.sender, referrer|house)

 T3 HL builder ($110)
   USDC(msg.sender) ─▶ VARO ─┬─ $100  cctp.depositForBurn ─▶ HyperEVM mintRecipient = hlFactory.predictBuilder(msg.sender)   [caller-DERIVED]
                              └─ $10   V2 swap(USDC→VY) ─▶ VBBO

 T4 launch V-DAO ($2000 in USDC/WBTC/ETH/PAXG)               PARTNER (affiliate, USDC only)
   asset(msg.sender) ─▶ VARO                                   USDC(msg.sender) ─▶ VARO ─▶ VBBO  ($10) or T3 legs ($110)
   factory.launch ⇒ 100% V-DAO supply minted ─▶ VARO          vdao[msg.sender] = targetVdao   (no token bought at registration)
     45% supply + VY      ─vdax.addPool────▶ main VDAX VY/V-DAO pool   (no LP to VARO; value → VDAX holders)
     45% supply + 2nd-leg ─vdaoDax.addPool─▶ VDAO-DAX pool            (2nd leg = asset[base] | bought-parent[layer])
     10% supply           ─safeTransfer────▶ creator (msg.sender)
     asset → VY:  base half→V2/VDAX ; layer all→VDAX(+buy parent)     [minVyOutForSeed / minParentOutForSeed caller-supplied]
   + if caller <T3: separate $100 USDC ─CCTP─▶ predictBuilder(msg.sender)
   rounding dust (Σbps may be <100%) stays at VARO — NO exit, NO rescueToken

 fundMyBuilder()  — $100 USDC(msg.sender) ─CCTP─▶ predictBuilder(msg.sender) ; hasBuilder[msg.sender]=true (one-shot chokepoint)
```

## Payout circuit (settle → claim) — the only VY-MINT path

```
 settleMine()  [paginated, ≤300 invitees/call]  — moves NO tokens; credits pendingVY[caller] from real source deltas:
       credit = (sourceCum_now − checkpoint) × bps        sources: VEO trading, VLO interest, VYO yield (PULL, checkpointed, idempotent)
                                                           bps: T2/T3 = 50%/5% ; T4 = 95%/9%  (caps 99% / 9.9%)

 claimMine()  [requires hasSettled] ─▶ _payOut(msg.sender):
       vyt.pullTokens(VARO, paid)            ← VY OUT of VYT  (reverts on shortfall; cushion-throttled; never partial)
       vco.addToHighestLTVFCap(paid)         ← cap UP by exactly `paid`   ✅ GOLDEN-RULE-CORRECT
       ├─ T2/T3 referrer:  vy.safeTransfer(paid) ─▶ referrer (msg.sender)
       └─ T4 referrer:     buyAndSplit — buy bound V-DAO with `paid` VY on main VDAX, then
                              standard: 50% V-DAO ─▶ referrer (msg.sender) + 50% ─donate─▶ its VDAO-DAX leg
                              VGC house: 100% ─donate─▶ VDAO-DAX leg (no creator cut)
       VARO ends the tx holding 0 VY (custody invariant)

 PUSH credits (no fund move, credit only):
   notifyReferrerPerpCredit(referrer, vyAmount)  ── caller-gated to `vpo`            (T<3 no-op)
   notifyInviteeRevenue(invitee, grossVY)        ── REVENUE_PUSHER_ROLE; credits referredBy[invitee]   (TRUST: no checkpoint)
```

## Keeper circuit (liability-counter freshness)

```
 sweep(count)  [permissionless, MIN_SWEEP_BATCH=50, 24h lap cooldown]
   try vgo.beginReward()  ──▶ … same _settleOne crediting over the GLOBAL referee list (reset-skip) … ──▶ try vgo.payReward(msg.sender)
   pays NO referrer (payout stays in claimMine) ; VGO reward = VGC to keeper, bounded by the VGC epoch ceiling ; both legs try/catch (never bricks)
```

## Exit-destination ledger (the closed-circuit proof)

| Exit | Token | Destination | Class |
|---|---|---|---|
| `_swapUsdcToVyV2(…, vbbo)` / `_buybackEthToVbbo(…, vbbo)` | VY | **VBBO** | hardcoded (init-only, no `setVbbo`) |
| `_refundExcessEth` | ETH | `msg.sender` | caller-scoped |
| `cctp.depositForBurn(mintRecipient)` | USDC | `hlFactory.predictBuilder(msg.sender)` | caller-DERIVED (admin-set factory) |
| `_payOut` T2/T3 | VY | `referrer` (= `msg.sender` in `claimMine`) | caller-scoped |
| `buyAndSplit` 50%/100% | V-DAO | `referrer` (msg.sender) + its VDAO-DAX pool | caller-scoped + protocol pool |
| `_executeVDAOSplit` creator cut | V-DAO | `creator` (= `msg.sender`) | caller-scoped |
| `vdax.addPool` / `vdaoDax.addPool` / `donate` | VY + V-DAO + asset | the AMM pools | protocol-determined |
| `vgo.payReward` | VGC (minted) | `msg.sender` (keeper) | caller-scoped, ceiling-bounded |
| rounding dust | any | **stays at VARO** (no exit) | trapped (no `rescueToken`) |

**No exit accepts a caller-supplied arbitrary recipient.** ⇒ **CLOSED relative to roles.**

## Trust surface (admin / upgrade — excluded from the atomic proof)

| Lever | Role | Blast radius |
|---|---|---|
| `_authorizeUpgrade` | ADMIN_ROLE | **DOMINANT** — a new impl inherits every role VARO holds (VYT.OFFICER mint, VCO.OFFICER cap, VDAX POOL_CREATOR+swap-whitelist, VDAO-DAX POOL_CREATOR, VSR.VARO_ROLE, VGO.OFFICER) ⇒ unbounded mint / cap / pool. |
| `setHlFactory` | ADMIN_ROLE | redirect a user's CCTP $100 to an attacker-predicted address (user funds; per-tx ≤ `cctpActivationUSDC`). |
| `setBps{Standard,VDAO}` | ADMIN_ROLE | raise referral cut up to 99%/9.9% ⇒ large mint magnitude (protocol always keeps ≥1%). |
| `setTierUsdcPrice` | ADMIN_ROLE | **no floor/ceiling check** — set any tier to 0 (free) or huge. |
| `setHouse` | ADMIN_ROLE | re-point default referrer (locked forever after `bootstrapVGCVDAO`). |
| `setCctp` / `setVDAOFactory` / `setVpo` / `setVgo` / `setReserveAsset` / `setCctpActivationUSDC` / `setPaused` | ADMIN_ROLE | wiring/config. |
| `setVgcDeployer` / `setVgcRecipient` (one-shot) + `bootstrapVGCVDAO` (one-shot) | ADMIN_ROLE / vgcDeployer | bootstrap the first (VGC) V-DAO; deployer-funded; latched. |

**Init-only immutable (NO setter):** `vbbo, vy, vyt, vco, veo, vlo, vyo, vdax, vsr, vdaoDax, vyUsdcV2Pool, uniV2Router`. **No `rescueToken` anywhere.**

## Live state (today) — FULLY DORMANT / UN-WIRED
- VARO holds **none** of its roles: VYT.OFFICER=false (**cannot mint VY**), VCO.OFFICER=false, VDAX POOL_CREATOR + swap-whitelist=false, VDAO-DAX POOL_CREATOR=false, VSR.VARO_ROLE=false.
- `vdaoFactory`/`hlFactory`/`cctp`=0; `weth`/`wbtc`/`paxg`=0 (USDC-only); `vpo`=0; `vgcDeployer`/`vgcRecipient`=0; `vdaoBootstrapped`=false; `paused`=false.
- Zero activity: `globalCreditedVY`=`globalClaimedVY`=0, `allReferees`=0. Even T1 reverts today (VEO.varo=0). `house`=KMS `0x8310eA7E`; admin (DEFAULT_ADMIN+ADMIN_ROLE)=KMS `0x8310eA7E`.

**Verdict (RECONCILED, workflow `wau2dte5v` — 30 agents, 8 dims; 31 raw → 17 surv / 4 ref / 10 Low-Info · 1 Crit / 2 High / 5 Med / 9 Low, ALL admin/trust/handoff or operational, ZERO permissionless-exploitable):** ✅ **CLOSED relative to roles — no arbitrary-dest exfil in any non-admin path** (all 6 exit vectors confirmed routed to protocol-determined or msg.sender-scoped destinations). **Golden-rule PROVEN unbreakable**: the only mint (`_payOut`) pairs `pullTokens(paid)`+`addToHighestLTVFCap(paid)` atomically, exact, and the VYT cushion (immutable, VARO=standard officer) reverts any unbacked mint. Referral credit checkpoint-idempotent (settleMine/sweep), bounded by real source fees × bps. Entire material residual = **admin/upgrade trust** (C1 dominant `_authorizeUpgrade`; H1 `setHlFactory` CCTP redirect; H2 `setTierUsdcPrice` no bounds; M-tier push-trust/MEV/bootstrap/CCTP-fail) + dependency trust (factory / V-DAO token / VDAO-DAX / hlFactory / CCTP / VPO). See `findings/ValinityAllianceRegistrationOfficer.md`.
