# ValinityStakingRouter (VSR) — Security Audit

> **STATUS: RECONCILED with multi-agent workflow `w5etym0g7` (69 agents, 12 survived / 48 refuted). Awaiting user check-off.**

| | |
|---|---|
| **Contract** | ValinityStakingRouter (VSR) — user-staking vault (VY + asset + ETH staking) |
| **Proxy** | `0x664b3A81C963F07C1eb06516c560f9b2193698C7` (UUPS) |
| **Live impl** | `0xe00db9e62c16c89f81b7b31d48cf658f30a571d4` |
| **Source==live** | ✅ **PROVEN — metadata IPFS hash equality (gold standard)**: `1220cb0b8a8e…` recompile == live. solc 0.8.27, optimizer **runs=1**, cancun. Source = workspace `contracts/staking/ValinityStakingRouter.sol` (HEAD `8bb172a`, git clean). Closure = 1 repo file + 25 stock OZ v5 files. |
| **Verdict** | ✅ **CLOSED non-admin — 0 permissionless-exploitable.** CC-1/DAX-L1 **discharged** by the ≥30-day lockup. The entire risk surface is **admin-trust/centralization**: **1 Critical + 1 High + 2 Med + 2 Low — ALL admin/handoff**, resolved by a properly-structured Fase-4 handoff. |

## Source verification note
The on-disk Hardhat **deployment json** is a stale/different-settings compile — metadata `12203a7a9ee0…`, `deployedBytecode` 14,745 B vs live 24,076 B; **does NOT match live** (live UUPS-upgraded past the committed deploy record). **Do not trust it.** Proof is the **build-info `7789ac48` standard-json recompile of the current workspace source**, reproducing the live metadata IPFS hash exactly (`1220cb0b8a8e…`). As-deployed saved to `asdeployed/ValinityStakingRouter/`.

## What VSR is
A staking vault that turns user deposits into protocol LP and returns principal after a lock:
- **VY staking** (`depositStake`): splits VY into a DAX leg (`dax.depositVYOnly` → VDAX) and a Uniswap V2 leg (VY/USDC zap → UNI-LP). A credit/index system tracks each stake's share. **V4 permanent 1% LP lock** per stake (uncredited, accrues forever as protocol-owned liquidity). ≤3 VY stakes/user.
- **Asset staking** (`depositAssetStake`/`depositETHStake`): USDC → UNI-LP; WBTC/PAXG/WETH/ETH → `dax.swapExactIn(asset→VY)` → `dax.depositVYOnly` → VDAX. VYO owns all asset-yield bookkeeping.
- **Withdrawals** (`withdrawStake`/`withdrawAssetStake`): burn LP, reconstitute VY/asset, pay user. **Hard invariant: a VY staker always receives EXACTLY `principalVY`** — gains → `buybackOfficer`, losses → `yieldOfficer.topUpPrincipal`. Asset withdrawals deliver `principalAsset` value (happy/mixed/topUp branches).
- **Lockup**: every stake has `unlockTime`; withdrawal reverts while locked. `tierDurationSec` floored at 30 days (tiers 30/60/90), **un-lowerable even by admin** (`setTierDuration` reverts below 30d, L798). MIN_STAKE 100 VY.

## Live state — VSR IS LIVE & holds real funds
- **`totalStakedVY ≈ 564,647 VY`**, `totalAssetStakesActive = 3`. VSR custody: **765,748 VDAX**, **0 raw VY** (confirms zero-between-txs), `lockedVdaxLP = 37.3`, `lockedUniLP ≈ 0`. `daxIndex ≈ 0.333`, `uniIndex ≈ 0.421`.
- Wiring canonical: dax/vdax/uniPair(VY/USDC)/uniRouter(UniV2)/vy/usdc/weth; yieldOfficer (VYO `0xA245C9D2…`), buybackOfficer (VBBO `0x4B97D45d…`), vryo (`0xA95749f5…`). `varo = address(0)` (registerVDAO inert; addAsset[ADMIN] works). Not paused. assets = USDC/WBTC/PAXG/WETH. tiers 30/60/90d.
- `DEFAULT_ADMIN_ROLE` & `ADMIN_ROLE` both held solely by `0x8310eA7E…4a09` (Fase-4 subject).
- On-chain: DAX `swapWhitelist[VSR]=true`, **`liquidityWhitelist[VSR]=true` (sole member)**, VY `isWhitelisted[VSR]=true`. **`VRYO.STAKING_ROUTER_ROLE[VSR]=false`** → heartbeat fails silently (fail-tolerant; operational, not security).

## 1. Closed-circuit (priority #1) — CLOSED in the non-admin path (by physics)
Every non-admin outbound transfer (all 16 sites, grep-confirmed) has a **hardcoded recipient** — no caller-supplied `to`/recipient parameter exists. The only role-free destinations are: **`msg.sender`** (exactly `principalVY` L1553 / `principalAsset` value L1723/1728), **`buybackOfficer`** (surplus/gain/dust only — admin-set, never attacker-chosen), and **`yieldOfficer`** (an *inflow* via topUp, never an exfil sink). The 765k VDAX + UNI-LP backing leave VSR only via legitimate credit-based redemption (`dax.withdraw`/`removeLiquidity`) which returns value straight to `msg.sender`. `nonReentrant` (transient flag, blocks cross-function reentry) + strict CEI (stake zeroed L1392-1397 / L1616-1622 before any external call). The only arbitrary-`to` primitives — `adminExtract` (L1869) and `rescueTokens` (L1941) — are ADMIN-only; `rescueTokens` hard-blocks VDAX/UNI-LP. **Closed-circuit confirmed.**

## 2. CC-1 / DAX-L1 discharge (priority #2 / headline) — DISCHARGED at VSR
VSR is DAX's sole liquidity-whitelist member; `dax.depositVYOnly`/`dax.withdraw` move `reserveVY` across all pools in *opposite* directions. The DAX obligation required these be non-atomically-round-trippable. Three independent code-enforced facts close it:
1. **30-day lockup separates the two single-sided DAX legs.** Deposit pushes `reserveVY` up; withdraw pulls it down; no single entrypoint does both; they're separated by `unlockTime` (floor 30d, un-lowerable, `StakeStillLocked` L1380/L1605). A public caller **cannot move a DAX pool and snap it back in the same block/tx** — this is exactly the "lockup" mitigation the DAX audit enumerated as acceptable.
2. **No profit leg even across the lockup.** The invariant pays the staker EXACTLY `principalVY`; any LP-redemption gain (the DAX-L1 surplus) routes to **buybackOfficer, not the staker** (L1537-1543) — so the ~8-11% single-sided inter-holder leak **cannot be harvested** by the withdrawer.
3. **The index lever is admin-gated.** `daxIndex`/`uniIndex` are written only at init and in `_syncIndexes` (reachable only via `adminExtract`/`adminSyncIndexes`, ADMIN_ROLE); deposits/withdrawals only *read* the index.

The asset-deposit `minOut=0` swap (L1311-1313) runs against the **permissioned DAX vault** and creates a 30-day-locked stake — not atomically round-trippable. **CC-1 sandwich lever AND DAX-L1 atomic extraction both closed at VSR. Obligation discharged.**

## 3. Value conservation — sound (under YO solvency)
- **Exactly-principalVY** has only two outcomes: user gets `principalVY`, or the tx reverts (no silent underpayment). Gain→BBO, loss→YO covers. Asset path delivers `principalAsset` value identically.
- **Credit/index is symmetric & solvency-preserving:** `index = distributable_balance·1e18/totalCredits`, so `Σcredits·index == distributable balance` by construction — no cohort can claim more LP than present.
- **1% lock is genuinely uncredited & unleakable:** deducted before crediting, subtracted from the index basis and from `adminExtract`, blocked from `rescueTokens`, monotonic (`+=` only). **Only a UUPS upgrade can touch it.**
- **YO top-up reserve is NOT permissionlessly drainable:** the only drain vector (sandwich the redemption to manufacture a shortfall) is blocked by the caller's `minVyOut` floor enforced *before* topUp (L1503), which is `msg.sender`-scoped; a self-sandwicher only refills VSR for value they removed while paying 2× fees + 30-day lockup = negative-EV self-harm. The dominant recovery leg (DAX, ~756k VDAX) is whitelist-private.

## 4. Findings (reconciled)
### Group A — Permissionless-exploitable
**NONE.** Zero realizable permissionless exploits on the live ~564k VY / 765k VDAX. All 48 attack-shaped findings refuted (impossible atomicity, `msg.sender`-scoping, principal-clamp removes the profit leg, whitelist-private DAX leg, self-harm economics, admin-gated index). **Audit priorities #1 and #2 satisfied without admin trust.**

### Group B — Admin-trust / Fase-4 handoff (removed at handoff)
| ID | Sev | Title | Lines |
|---|:--:|---|---|
| VSR-UUPS-001 / VSR-C5 | **Critical** | `_authorizeUpgrade` gated **only by DEFAULT_ADMIN_ROLE**, empty body, no timelock → upgrade to arbitrary bytecode drains the ENTIRE backing (765k VDAX + 564k VY + the 37.3 locked) and can delete the lockup/invariant. **The dominant lever — broader than adminExtract.** | 1959, 182 |
| VSR-ADMIN-001 | **High** | `adminExtract(bps,to)` sends up to 100% of distributable LP to an arbitrary `to`, no timelock/cap/cooldown → bricks withdrawals + drains YO reserve. (Locked 1% correctly excluded.) Dominated by UUPS but independently dangerous. | 1867-1896 |
| VSR-ADMIN-003 | **Medium** | `setYieldOfficer`/`setBuybackOfficer` no timelock; instantly swap the principal-protection officers (DoS bounded to loss-path; no principal theft). | 811-835 |
| VSR-YIELD-001 | **Medium** | Un-wrapped `topUpPrincipal`/`onAssetWithdraw`/`topUpAssetWithdrawal`: an insolvent/broken YO freezes loss-case VY withdrawals + **ALL asset withdrawals**. Governance-recoverable (setYieldOfficer + UUPS). | 1531, 1625, 1671, 1707 |
| VSR-ADMIN-002 | **Low** | `rescueTokens` unbounded transfer of non-LP tokens (VY/USDC/WBTC…) to arbitrary `to`; only transient dust exposed (LP block-protected). | 1939-1953 |
| VSR-ADMIN-004 | **Low** | `setVryo`/`adminPause` no timelock; pause can freeze matured withdrawals (intended kill-switch). | 844-848, 1849-1857 |

### Group C — Cross-contract obligation
| ID | Sev | Title | Disposition |
|---|:--:|---|---|
| CC-1 / DAX-L1 (obligation 1) | **Discharged** | Atomic/same-block reserveVY round-trip + DAX-L1 atomic leak — CLOSED at VSR by 30-day lockup + single-direction + admin-frozen index + principal-clamp routing surplus to BBO. | §2 |

### Group D — Informational (verified-correct defensive properties)
VSR-PRINCIPAL-001 (exactly-principalVY), VSR-CEI-001 / VSR-ASSET-CEI-001 (CEI + transient nonReentrant), VSR-VRYO-001 (heartbeat fail-tolerant), VSR-INDEX-SYNC-001 (lock subtracted from index basis), VSR-INIT-001/002 (`reinitializer(3)` consumed, `_disableInitializers` set), VSR-ADMIN-EXTRACT-001 (extract respects lock). FoT(PAXG)/decimals/USDC-blacklist/ETH-revert edges all refuted to Info (self-harm or issuer-gated, atomic revert preserves state).

## 5. Fase-4 handoff conditions (VSR-specific)
1. **The UUPS upgrade authority is the dominant lever** — `_authorizeUpgrade` (L1959) is gated **only by DEFAULT_ADMIN_ROLE**, empty body, no on-chain delay; strictly broader than `adminExtract` (can drain everything incl. the locked VDAX and delete the invariant/lockup). **Securing DEFAULT_ADMIN_ROLE is paramount.**
2. **Both roles must move, then renounce.** DEFAULT_ADMIN (upgrade + role-admin-of-all) *and* ADMIN (extract/rescue/officers/pause/tiers) are both held by `0x8310eA7E…4a09` → transfer both to governance, then the human admin renounces both.
3. **No contract-level two-step / no upgrade timelock.** VSR uses plain OZ `AccessControl` (not `AccessControlDefaultAdminRules`) and `_authorizeUpgrade` has no delay → **governance MUST enforce an external timelock** (≥1-day) and ideally an upgrade delay; this automatically gates extract/rescue/officer-setters. Strongly recommend an `adminExtract` per-period cap/cooldown.
4. **dax/uniRouter/uniPair/vy/usdc/weth are immutable-except-upgrade** (no setters) → repointing them collapses into condition 1.
5. **`setTierDuration` floor is 30 days — never lower it** (the CC-1 lockup guard). Curate assets; never add FoT/rebasing/callback-token assets that break accounting (PAXG already supported — its handling verified safe: FoT shortfall reverts atomically, no drift).
6. `varo = address(0)` — `registerVDAO` inert; if VARO is wired post-handoff, governance vets it first.

## 6. Cross-contract obligations raised here
- **VYO / YieldOfficer (`0xA245C9D2…`) — HARD DEPENDENCY, audit next.** (a) **Top-up solvency:** `topUpPrincipal` (L1531) and `topUpAssetWithdrawal` (L1671/1707) are un-try/catch'd → insolvency freezes loss-case VY withdrawals and ALL asset withdrawals; VYO must cover the deterministic ~1% POL lock per VY round-trip + genuine IL across ~564k VY. (b) **Asset-yield bookkeeping:** `onAssetDeposit`/`onAssetWithdraw` correctness assumed; `onAssetWithdraw` runs un-wrapped on every asset withdrawal. (c) VYO must stay governance-replaceable (it is) and non-malicious.
- **Officers (VAO/VBBO):** the CC-1 `minOut=0` sandwich lever is **closed at VSR** — VSR adds no new officer obligation; any residual for officers' *own direct* DAX swaps is MEV-submission discipline at the officer audits.
- **VRYO (`0xA957…15d3`) — operational, low-urgency:** grant `STAKING_ROUTER_ROLE` to VSR so the heartbeat activates (fail-tolerant today; no fund impact if unfixed).
- **VARO — inert** (varo=0); no live obligation.

---
**Bottom line:** Against the live ~564k VY / 765k VDAX, VSR has **NO permissionless exploit** — the non-admin circuit is provably closed, the CC-1/DAX-L1 obligation is **discharged** by the 30-day lockup + single-direction + principal-clamp design, and the exactly-principalVY / credit-index / 1% lock accounting is value-conserving with the YO reserve non-drainable by any staker. The entire residual risk is **admin-trust/centralization**, dominated by the DEFAULT_ADMIN-gated UUPS upgrade (Critical) then `adminExtract` (High). **VSR is SAFE to hand off at Fase 4** provided both roles move to timelocked governance (then renounce), an upgrade delay + adminExtract cap are enforced, and YieldOfficer solvency/replaceability is maintained. **The irreversible handoff is the correct remediation for every surviving finding.**
