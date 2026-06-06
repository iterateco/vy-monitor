# ValinityMEVBotV2 (VMB) — Findings · **NEW VERSION re-audit** (supersedes 2026-06-01)

**Proxy:** `0x6f2F45804E58e3240A2fDE9857c0e4F754CC4941` · **live impl `0x98d7ee493a44b4f1280004b475dedefbf45fa55d`** (upgraded from `0x16b66a22`, the prior-audited impl).
**Source==live:** PROVEN (gold standard) — build-info `4515c727…` compiled ValinityMEVBotV2 to deployedBytecode metadata IPFS `12206c2d712d…` == live impl; its embedded source is byte-identical to the dirty workspace `contracts/arbitrage/ValinityMEVBotV2.sol` (keccak `0x9daff5c3…`). Deployed from the uncommitted workspace (HEAD `3d99bf6` + edits). solc 0.8.27/runs=100/cancun. As-deployed source saved.
**Audit workflow:** `wc33q498d` (8 dimensions, adversarial refutation) — *verdict reconciled below.*

> **🔁 What changed vs the prior audit (impl `0x16b66a22`, "user OK 2026-06-01", workflow `wp9ya0vnb`):** the arb path was completely redesigned. **REMOVED** the arbitrary low-level `router.call(callData)` + per-`(router,selector)` `routerSelectorAllowed` allowlist — that was the prior **CC-1 / trust-core Medium**, and it is gone. **NOW** the keeper supplies only `borrowVY` + a typed `Leg[]` route (`DexKind` enum + whitelisted router + token pair + `extra`); the contract builds each swap call itself (recipient hardcoded = bot, `minOut=0`, `amountIn`=100% balance). **ADDED** a VGO keeper-reward bracket and a `minProfitVY` anti-grief floor; **REMOVED** the caller profit-share (100% profit → Buyback Officer; keeper paid by VGO, not arb profit). Strictly safer model.

---

## Verdict (RECONCILED, workflow `wc33q498d` — 64 agents, 26 surv / 29 ref)

✅ **CLOSED for the permissionless `executeArb` flow — principal can never be exfiltrated to an arbitrary address, even by a malicious *intermediate-leg* whitelisted router.** Breakable only in two narrow **admin/upgrade-gated** ways (C-1, H-1/H-2 below) — none permissionless.

- **Every swap call is contract-built** (`_executeSwap`) with `recipient = address(this)` and `minOut = 0`; the keeper injects no calldata. The only settlement exits are **VYT** (repay `borrowVY`) and **buybackOfficer/VBBO** (profit + pre-borrow dust) — both hardcoded, none caller-supplied.
- **Principal closure is the repay invariant, not the whitelist.** A malicious whitelisted router that steals tokenIn/intermediate/borrowed-VY (even depositing 1 wei `tokenOut` to pass `SwapOutputZero`, with `TokenInNotDrained` satisfied) still ends with `finalVY < borrowVY` → `InsufficientVYToRepay` → **atomic rollback of `pullTokens`**. `VYBalanceNotZero` forces the bot to end holding 0 VY.
- **⚠ One intra-implementation crack (H-1):** `SwapOutputZero` checks a *strict increase*, not the *amount*. A malicious **final-leg** router (which outputs VY) can hand the bot exactly `borrowVY + minProfitVY` and pocket the rest to an attacker — repay + floor both pass. **Bounded to `actualProfit − minProfitVY` (principal never at risk), but 100% of profit if `minProfitVY` is ever 0.** So the whitelist IS load-bearing for *profit* integrity (not just defense-in-depth). Requires a malicious/compromised whitelisted router on a VY-terminal leg.
- **Treasury made whole every tx**, bot retains nothing, no VCO/golden-rule cap event (borrow-and-return, circulating-VY unchanged), no unbacked mint **without an upgrade**.

**Permissionless surface:** `executeArb` is open, bounded by a **7-day per-caller cooldown** + a **70 VY min-profit floor** (live). **Major design improvement** over the prior impl (`0x16b66a22`): the arbitrary `router.call(callData)` + selector allowlist (old CC-1 trust-core) is gone; residual exfil surface shrank from "any whitelisted (router,selector) with attacker calldata" to "final-leg router can skim profit-above-floor."

---

## Findings

### VMB-C1 — `_authorizeUpgrade` dominant lever: inherits VYT.OFFICER_ROLE → cushion-bounded treasury drain · **Critical (admin/upgrade-trust)**
UUPS upgrade guarded only by `ADMIN_ROLE`, **no on-contract timelock**. A malicious implementation bypasses every closed-circuit invariant and calls `vyt.pullTokens(attacker, …)` with no repay. **Corrected magnitude: NOT unbounded — the bot is a *standard* (non-priority) OFFICER on VYT, so `pullTokens`' cushion applies** (CUSHION = 350k VY, TARGET = 7M) → **per-call ceiling ≈ 6.65M VY**, repeatable as VYT auto-refills (further rate-limited by ValinityToken mint limits ≈0.07%/tx, 0.30%/epoch). Also a path to add a rescue function (none today). *Precond: `ADMIN_ROLE` compromised or governance hijacked. Acute pre-handoff: admin is still a KMS EOA-class key with no on-chain timelock.* **#1 handoff requirement.**

### VMB-H1 — Final-leg whitelisted router can skim profit above the floor · **High (router-whitelist trust)**
`SwapOutputZero` (L296) checks increase, not amount; the floor check (L330) is `netProfit >= minProfitVY`. A malicious/compromised **final-leg** router returns exactly `borrowVY + minProfitVY` and pockets the rest. **Contained:** max skim = `actualProfit − minProfitVY`; principal safe, floor never crossed. **Becomes 100%-of-profit theft if `minProfitVY` is set to 0.** This corrects the earlier "closed even against a malicious whitelisted router" claim — true for *principal*, but a malicious **final-leg** router can take profit-above-floor. *Precond: a malicious contract whitelisted on a VY-terminal route + an arb netting ≥ minProfitVY. Fix: whitelist canonical routers only (governance-voted); keep minProfitVY > 0.*

### VMB-H2 — `setMinProfitVY` has no lower bound → admin can zero the floor · **High (admin-trust)**
`setMinProfitVY` (L418) accepts 0, which removes the anti-grief floor **and** the H-1 cap, and (with `vgo != 0`) enables unbounded dust-profit VGO-reward farming (Sybil EOAs defeat the per-caller cooldown). Inert today (`vgo = 0`, floor = 70 VY). *Fix: keep `minProfitVY` > 0 permanently while VGO is/will be enabled; recommended on-chain guard `if (vgo != address(0) && newMinProfitVY == 0) revert` at next upgrade; timelock setMinProfitVY.*

### VMB-M1 — `setVgo` adds an UNAUDITED external-contract trust surface · **Medium (latent; vgo=0 today)**
When set, `vgo.beginReward()`/`payReward(msg.sender)` run inside `executeArb` and the bot must grant VGO OFFICER_ROLE on VYT — a malicious/upgraded VGO could `pullTokens` during `payReward` (damage to **VYT/system**, not VMB). **VMB itself cannot be drained**: best-effort `try/catch` (L356-360), closed loop, `nonReentrant`, and the bot **sends VGO no funds** (one-way VGO→keeper). Zero exposure today (`vgo = 0`). VGO is unaudited (ties to VCO-CC4 — VGO also holds VCO.OFFICER_ROLE). *Fix: audit VGO before `setVgo`; timelock setVgo.*

### VMB-M2 — Dual role grant at init creates an ambiguous-handoff trap · **Medium (process)**
Constructor grants `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` to the same EOA (L216-217). An incomplete handoff that transfers `ADMIN_ROLE` but forgets `DEFAULT_ADMIN_ROLE` lets the old key re-grant itself `ADMIN_ROLE` and upgrade — a live backdoor to C-1. Mitigated by the handoff script's readback gate **only if executed exactly as written.** *Fix: BOTH-roles-readback before any renounce (see handoff).* 

### Lows / Informational
- **VMB-L1 — `setBuybackOfficer` redirects 100% of future profit (admin-trust).** Treasury still repaid 100%; only profit redirected (or arbs revert if recipient rejects transfers). Live = VBBO. Timelock + receipt test.
- **VMB-L2 — Token-edge / FoT & VY-whitelist-loss are fail-safe reverts (no extraction).** FoT intermediate → `TokenInNotDrained` revert (safe griefing/wasted gas); if the bot loses its VY fee-exemption, FoT+sandwich on the final leg can push `finalVY < borrowVY` → safe revert. `minOut=0` sandwich damage is profit-suppression only, bounded by repay + floor, never principal. *Keep the bot/VYT/VBBO on the VY fee-exemption list (the proxy address is unchanged by the upgrade, so prior exemption persists).*
- **VMB-I1 (positive): arbitrary-calldata surface removed** — contract builds every swap; no `router.call(callData)`, no selector allowlist. Major reduction vs the prior version.
- **VMB-I2 (positive): closed-loop invariants sound & correctly sequenced** — start/end VY, connected chain, `SwapOutputZero`, `TokenInNotDrained`, `finalVY≥borrowVY`, `VYBalanceNotZero`, `forceApprove`→0 reset, pre-borrow dust sweep, empty-route + `tokenIn==tokenOut` rejects.
- **VMB-I3 (positive): no rescue function; holds 0 between txs.** Confirm no future upgrade adds one.
- **VMB-I4 (positive): value conservation** — 100% repay or atomic rollback; borrow cushion-bounded (~6.65M/call); no unbacked mint via the bot; VGO fund-flow one-way (bot sends VGO nothing), settlement locked before `payReward` (no race).
- **VMB-I5: reentrancy** — `nonReentrant` on `executeArb`; route swaps + best-effort VGO calls cannot reenter or break settlement.
- **VMB-I6 (defensive nit): `_executeSwap` has no explicit `DexKind` upper-bound** — out-of-range enum falls through to the DAX branch. Refuted as exploitable (ABI-decode rejects out-of-range enums; DAX not whitelisted live; canonical routers don't implement `swapExactIn`; closed loop contains it). Suggest `if (leg.kind > DexKind.ValinityDAX) revert InvalidLeg(...)`. DAX `poolId` (`extra`) not bounds-checked, but DAX not whitelisted.
- **VMB-I7: storage-layout preserved across the upgrade** — `payoutBps` (=100, inert) + `routerSelectorAllowed` retained as deprecated slots; `vgo` + `minProfitVY` appended into 2 previously-gapped slots (default 0, matching observed `vgo=0`); `__gap` 50→48. Layout compatible.

---

## Handoff requirements
**Dominant-lever ranking (most → least dangerous):**
1. **`_authorizeUpgrade` (C-1)** — total bypass; cushion-bounded (~6.65M VY/call) treasury drain via inherited OFFICER_ROLE. **MUST go behind a governance TimelockController with a real upgrade delay.**
2. **`setVgo` (M-1)** — unaudited cross-system trust with VYT-pull potential. **Do NOT call until VGO is audited.** Timelock.
3. **`setMinProfitVY` (H-2)** — zeroing the floor removes the H-1 cap + enables farming. Keep > 0; add the `vgo!=0 ⇒ minProfit!=0` guard at next upgrade; timelock.
4. **`setRouterWhitelist` (H-1)** — a malicious final-leg router skims profit-above-floor. Governance-voted, canonical routers only (live: UniV2 Router02 + UniV3 SwapRouter02); timelock + freeze.
5. **`setBuybackOfficer` (L-1)** — profit redirect. Timelock + receipt test.
6. **`setCallerCooldown` (1-30d) / `setPaused`** — lowest; `setPaused` → fast guardian.

**The DEFAULT_ADMIN + ADMIN revoke step (M-2 — get this right):** run `scripts/handoff_mevbot_v2_to_governance.ts` in order — grant both roles to governance → **readback-assert governance holds BOTH** → only then renounce ADMIN then DEFAULT_ADMIN from the KMS → final readback (governance BOTH, KMS NEITHER). Never renounce before governance holds both (DEFAULT_ADMIN can re-grant ADMIN). **No rescue function** — verify every future upgrade's bytecode adds none. Keep the bot on the VY fee-exemption list.
