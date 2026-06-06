# ValinityYieldOfficer (VYO) — Security Audit

> **STATUS: RECONCILED with multi-agent workflow `wf_b7bb0f6d-03a` (resumed as `w0ximbq0f` after an overnight infra stall; 63 agents, 5 survived / 49 refuted). Awaiting user check-off.**

| | |
|---|---|
| **Contract** | ValinityYieldOfficer (VYO) — yield engine + VSR principal backstop; OFFICER (VY minter) on VYT |
| **Proxy** | `0xA245C9D2D375A317DbA3d18bC74BF5921E7892C9` (UUPS) |
| **Live impl** | `0x08a4de6b20fd8d3580b94991028a53d6a7ae1c92` |
| **Source==live** | ✅ **PROVEN — metadata IPFS hash equality (gold standard)**: `1220e8c4be47…` recompile == live. solc 0.8.27, runs=100, cancun. Source = **uncommitted workspace** `contracts/officer/ValinityYieldOfficer.sol` (committed HEAD `0fb4122` does NOT match — user redeployed from workspace without committing, same pattern as VLO). Closure = 1 repo file + 25 OZ v5. |
| **Verdict** | ✅ **CLOSED non-admin — 0 permissionless-exploitable.** Yield mint is bounded (9% cap, frozen `maxGross`, self-throttling rate), backed (universal VCO booking), and value-conserving. Entire material risk surface is **admin-trust/handoff**, dominated by `_authorizeUpgrade` (an upgrade can mint unbounded VY). |

## Source verification note
On-disk deployment json is a different compile (don't trust). Proof is the **build-info `21058a62` recompile of the current workspace source**, reproducing live metadata `1220e8c4be47…` exactly. ⚠ The workspace file had **uncommitted edits** — those edits ARE the deployed source (verified by hash). As-deployed saved to `asdeployed/ValinityYieldOfficer/`.

## What VYO is
The protocol's **yield engine** and the backstop behind VSR's principal guarantee. It is an **OFFICER on VYT** (the VY mint treasury) — `vyt.pullTokens(this, amt)` mints VY to VYO. With that minted VY it pays staking yield and covers VSR shortfalls, **booking 95% of every pull into VCO's highest-LTV-F cap**.
- **Rate**: dynamic master rate (`_getMasterRate`, piecewise sqrt, cap 9%; tier caps 7.5/4.17/1.7%), **self-throttling to 0 as VYT free-VY drains** (only 50% of free VY counted; 50% permanent cushion). Locked at deposit via `yieldBpsSnapshot`; `maxGross = principal × yieldBps`. Linear accrual, capped at `maxGross`.
- **Payout split** (every yield event): 90% user / 5% feeRecipient (VBBO) as VY / **5% never minted (stays in VYT)**. Asset yield: pull VY → swap VY→asset (Uniswap V2 for USDC, DAX otherwise) → user.
- **Backstops** (onlyRouter): `topUpPrincipal` (VY) and `topUpAssetWithdrawal` (asset) pull VY from VYT to cover VSR shortfalls — deliberately **not yield-capped** (router-supplied amount); asset leg slippage-protected (`minOut=targetAsset`, `PoolTooShallow` revert).
- **VARO referral** (V5): `totalYieldClaimedVY[user] += grossVY` (VARO pulls); `_syncReferralReserve` folds VARO debt into the reservation (try/catch).

## VCO booking — correct-by-design (per the cap golden rule)
Confirmed against `project_vco_cap_golden_rule`: every `vyt.pullTokens(this, X)` (VY **out of** VYT → into circulation) is matched 1:1 by `capOfficer.addToHighestLTVFCap(X)` → **cap ↑ by exactly the minted amount**. The booked amount is the **full 95% pulled** (= 100% of what's minted), at all four pull sites (L534/784/1164/1260). The un-minted 5% ecosystem fee correctly does **not** move the cap (it never leaves VYT). VCO books VY (not asset value), so swap slippage doesn't affect backing. This is tight conservation — **not a double-count and not a bug**. The workflow's "un-try/catch'd VCO booking" item is **by-design** (booking is a must-succeed financial step; VCO is immutable, set only at init).

## Access model
- **Public** (msg.sender-scoped, nonReentrant, whenClaimsNotPaused): `claimYield`, `claimAssetYield`.
- **onlyRouter** (ROUTER_ROLE=VSR): `onDeposit`/`onWithdraw`/`topUpPrincipal`/`onAssetDeposit`/`onAssetWithdraw`/`topUpAssetWithdrawal`.
- **Admin** (ADMIN_ROLE): `setRouter` (grants ROUTER_ROLE), `setFeeRecipient`, `setFeeBps`(≤5%), `pauseClaims`, `setVryo`, `setVaro`, `syncReferralReserve`, `initializeV4`. `_authorizeUpgrade` = ADMIN_ROLE.

## Live state — VYO IS LIVE & operational
- Wiring canonical: vyToken/vyt (**VYT.OFFICER_ROLE[VYO]=true**)/capOfficer(VCO `0x2f024159…`)/feeRecipient(VBBO)/router=VSR (ROUTER_ROLE✓)/vryo/dax/uniRouter/uniPair/usdc. `varo=address(0)` (referral sync no-op). claimsPaused=false, feeBps=500 (5%).
- `premiumCount=13` (of 1000), `totalPromisedYield≈57,007 VY`, `totalAssetStakeVY≈6,758 VY`, `referralReservedVY=0`.
- `DEFAULT_ADMIN_ROLE` & `ADMIN_ROLE` both held by `0x8310eA7E…4a09` (Fase-4 subject); VSR holds ROUTER_ROLE. VYT cushion 350k / target 7M → ~6.65M headroom vs ~564k VSR stakes ≈ **12× cover**.

## 1. Closed-circuit (priority #1) — CLOSED by physics
VY is minted only at **4 sites** (`vyt.pullTokens` @ L532/781/1146/1239). The only **permissionless** sinks are `claimYield`/`claimAssetYield`, both **msg.sender-scoped** (caller's own stakes), **recipient-hardcoded to `user`** (no attacker-supplied destination), and **amount-clamped** to `maxGross − grossPaidTotal` (and 95% of that). The two un-yield-capped pulls (`topUpPrincipal`/`topUpAssetWithdrawal`) are **onlyRouter** (VSR). **No permissionless path mints unbacked VY, redirects funds, or over-claims.**

## 2. Mint bounded + backed + value-conserving — YES on all three
- **Bounded**: per-stake `maxGross` frozen at deposit (snapshot, never recomputed); master rate hard-capped 9%; self-throttles to 0 as VYT free-VY drains. Deposit-time rate is theoretically flash-manipulable but: hook ordering excludes the attacker's own pending stake; forcing 9% needs a *permanently unrecoverable* ~2× effective (>1M VY) donation to VYT; payoff capped at 9% on own principal → **economically irrational, not exploitable**.
- **Backed**: every pull booked to VCO (4 sites, unguarded by-design) — the golden-rule increment.
- **Value-conserving**: reservation accounting conservation-neutral (deposit `+maxGross`/`+2×(prin+yield)`, claim/withdraw decrements net to exactly zero). **All clamp-to-0 guards are on decrements**, so they can only bias `totalPromisedYield` downward (→ lower rate, conservative), never inflate. sqrt/division truncation sub-1-bps, floors in protocol's favor; 2× asset buffer over-reserves (safe direction).

## 3. VSR backstop covenant — bounded + backed + only DoS-able (not drainable)
`topUpPrincipal`/`topUpAssetWithdrawal` are onlyRouter (VSR), bounded by VSR's genuine shortfall, asset leg slippage-protected, pulls booked to VCO. The **only** permissionless coupling is VYT cushion exhaustion (topUp reverts if VYT ≤ cushion) — but no permissionless lever forces that on demand; auto-refill is self-healing; live ~12× cover. "Malicious router drains it" needs a malicious ADMIN (`setRouter`) — admin-trust, not permissionless.

## 4. Findings (reconciled)
### Group A — Permissionless-exploitable
**NONE.** No High/Medium permissionless finding exists; all 49 attack-shaped findings refuted. Every original High/Critical collapsed to (a) self-harm MEV on the claimant's own payout, or (b) admin-trust.

| ID | Sev | Title | Disposition |
|---|:--:|---|---|
| VYO-007/008 | Low/Info | User-leg asset-yield swap uses `minOut=0` (L1251/1255) — MEV sandwich on the **claimant's OWN** payout; recipient hardcoded to msg.sender; no over-mint/redirect | Self-harm only; off-chain mitigable (private relay). Officers' no-sandwich model: protection lives in VEO/VSR, not the officer. |
| VYO-003 | Info | PAXG / FoT asset silently under-delivers user yield (≤ issuer FoT rate; PAXG live rate 0%; USDC unaffected) | No protocol loss; onboarding-hardening note |
| VYO-R7 | Info | Uni/DAX swaps with `minOut=0` succeed barring pool exhaustion | informational |

### Group B — Admin-trust / Fase-4 handoff (keystone)
| ID | Sev | Title | Lines |
|---|:--:|---|---|
| VYO-AUTH (upgrade) | **Keystone (Critical-if-malicious-admin)** | `_authorizeUpgrade` empty-body `onlyRole(ADMIN_ROLE)` → an upgrade inherits VYO's live VYT OFFICER_ROLE and can `pullTokens(attacker, unbounded)` = **unbounded unbacked VY mint in one tx. The DOMINANT lever** (strictly dominates setRouter). | 1285 |
| VYO-ROUTER | High (handoff) | `setRouter` grants ROUTER_ROLE → a malicious router pulls VYT to a router-supplied recipient (weaker than upgrade) | 666-679 |
| VYO-R4 | Info | VCO `addToHighestLTVFCap` un-try/catch'd (4 sites) → temporary claim DoS if VCO reverts | by-design (booking must succeed; VCO immutable; atomic revert, no stranded state) |
| VYO-ADMIN | Info | `setFeeRecipient`/`setFeeBps`(≤5%)/`pauseClaims`/`setVaro`/`setVryo` — strictly weaker admin levers | 654-714 |

### Group C — Cross-contract obligations
| ID | Sev | Title |
|---|:--:|---|
| VYT-headroom | Info/Low | VYO's self-throttle + backstop depend on VYT `getAvailableForYield()` honesty + cushion/auto-refill keeping headroom (live ~12× cover) |
| VCO-booking | Info | VCO must absorb the **accumulated** booking of every VY VYO mints (golden-rule sink) and never revert under normal op — the other half of "all minted VY is backed" |
| VARO-debt | Info | when wired, `outstandingReferralDebtVY()` must be honest/bounded (try/catch-guarded; malicious VARO only throttles new-stake rate, reversible) |

**Net: 0 Critical / 0 High / 0 Medium permissionless. 1 Low + Info (self-harm MEV), rest Info — admin-trust/handoff or cross-contract.**

## 5. Fase-4 handoff conditions (VYO-specific)
1. **`_authorizeUpgrade` (L1285) is the DOMINANT lever** — an ADMIN tx can upgrade to logic that mints unbounded VY via the live OFFICER_ROLE. **ADMIN_ROLE recipient MUST be a TimelockController** (or timelocked multisig) so every upgrade + `setRouter` incurs a public, contestable delay. Single highest-value condition.
2. Migrate **both** `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` (today `0x8310eA7E…4a09`) to the same governance/timelock, then **renounce** the EOA copies. (ADMIN_ROLE is role-admin of ROUTER_ROLE + gates upgrade; DEFAULT_ADMIN is role-admin of ADMIN.)
3. **Verify ROUTER_ROLE = VSR only**; treat `setRouter` as a timelocked governance action.
4. Route `pauseClaims`/`setFeeBps`/`setFeeRecipient`/`setVaro`/`setVryo` through the same timelock. `vyToken`/`vyt`/`capOfficer` (init) and `dax`/`uni`/`usdc` (initializeV4) have no setters → mutable only via upgrade (covered by #1).

## 6. Cross-contract obligations raised here
- **VYT (`0xe58E29c9…`)**: `getAvailableForYield()` honesty (the self-throttle depends on it) + cushion/auto-refill maintaining backstop headroom (~12× live). VYT already audited — confirm officer-pull headroom semantics.
- **VCO (`0x2f024159…`)**: must absorb VYO's accumulated cap bookings (the golden-rule sink) and not revert under normal op. **The VCO audit is the conservation check** (see `project_vco_cap_golden_rule`). VCO is immutable in VYO (no setter) — a strength.
- **VARO** (when wired): honest/bounded `outstandingReferralDebtVY()`.
- **VSR** (trusted router): one topUp per withdrawal with genuine shortfalls (VYO delegates idempotency to VSR's state machine); enforce the user-leg no-sandwich externally.

---
**Bottom line:** VYO is **closed and safe in the permissionless threat model** — no unbacked VY mint, no fund redirection, no over-claim beyond per-stake `maxGross`. Yield is bounded (9% cap, frozen snapshot, self-throttling), backed (universal VCO booking — the golden-rule increment), and value-conserving (conservation-neutral reservation, all drift biased conservative). The only material risk is the **ADMIN_ROLE keystone — chiefly `_authorizeUpgrade`, which can mint unbounded VY via a malicious implementation.** The irreversible Fase-4 handoff is SAFE **iff** ADMIN_ROLE + DEFAULT_ADMIN_ROLE are routed to timelocked governance before handoff, and the VYT/VCO/VARO/VSR obligations are honored. No permissionless code defect blocks the handoff.
