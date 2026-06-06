# ValinityGasOfficer (VGO) — Findings · **BRAND-NEW redesign** (keeper-reward engine)

**Proxy:** `0x0a6C21174d039f5D85dA93FCB3FE7ad5F5f5E827` · **live impl `0x7c35d9d7e66066ffee0b68ea2970df42250b8c46`** (V4 redesign; upgraded in place over V3, `reinitializer(4)`). Prior v1 was a different address (`0x6d6AE9de…`).
**Source==live:** PROVEN (gold standard) — build-info `d7b281e8…` compiled VGO to deployedBytecode metadata IPFS `1220552ad640…` == live impl; embedded source byte-identical to the dirty workspace `contracts/officer/ValinityGasOfficer.sol` (keccak `0xa08a0dcf…`, 391ln). Deployed from the uncommitted workspace. solc 0.8.27/runs=100/cancun. As-deployed saved.
**Audit workflow:** `wdvoxe1c0` (8 dimensions, adversarial refutation) — *verdict reconciled below.*

> **🔁 Redesign + major de-risking.** The prior VGO pulled VY / mutated VCO caps. The new VGO is **purely a keeper-reward engine** (`IKeeperRewards`): officers bracket their permissionless pokes with `beginReward()`…`payReward(keeper)` and VGO mints the keeper **1.25× the metered base-fee gas cost** in **VGC** (a separate gas-credit token VGO is the *sole locked minter* of). `vyt`/`vco`/`vy`/`weth` are now **inert legacy storage slots, never read**. The emission cap + kill-switch is **VGC's per-epoch mint ceiling** (enforced inside the VGC token). **Engine is DORMANT live** (`vgc=0` → `payReward` reverts `VgcNotWired`).

---

## Verdict (RECONCILED, workflow `wdvoxe1c0` — 71 agents, 51 surv [many positive validations] / 10 ref)

✅ **No custody drain — VGO holds no user funds and pulls no VY.** Its only value creation is VGC minted to officer-supplied keepers, globally capped by VGC's per-epoch ceiling (enforced inside the VGC token). The prior cap-touching/VY-pulling surface is gone (inert slots; byte-for-byte V3 layout preserved). Auth/reentrancy/storage are sound; engine is **dormant today** (`vgc=0` → `payReward` reverts `VgcNotWired`), so no VGC is mintable. **The single real residual blocking handoff is the unrevoked `VCO.OFFICER_ROLE` (VGO-H1)**, weaponizable only via admin upgrade. Economic risks (gas-burn farming, VGC ceiling, DAX quote-skew) are officer/DAX-trust-bounded and gated by the VGC epoch ceiling — which must be audited before `wireVgc`.

---

## Findings

### VGO-H1 — VCO-CC4 NOT resolved on-chain: VGO still holds `VCO.OFFICER_ROLE` · **High (admin-upgrade-gated)**
The source comment claims the VCO OFFICER_ROLE was "revoked at upgrade (dead)," and the new logic indeed **makes zero `vco.*` calls** (the `vco` slot + the `IValinityCapOfficer` stub are inert). **But on-chain `VCO.hasRole(OFFICER_ROLE, VGO) == true` — the revoke was never executed.** Because VGO is UUPS-upgradeable (`_authorizeUpgrade`, ADMIN_ROLE), a malicious/compromised admin can upgrade VGO to logic that calls **any OFFICER_ROLE-gated VCO cap-mutation** → **phantom cap inflation / under-backed VY headroom** (violates the VCO golden rule). **The exposure is the *role*, not any signature** — the inert stub happens to declare `addToHighestLTVFCap`, but a new impl can declare and call whatever it wants (`increaseAssetCap`, etc.). A gas-reward officer has no cap responsibility → least-privilege violation. **Exact required action (blocking pre-handoff):** on the **VCO contract**, `vco.revokeRole(OFFICER_ROLE, 0x0a6C21174d039f5D85dA93FCB3FE7ad5F5f5E827)` from a VCO DEFAULT_ADMIN holder, then verify `hasRole == false`. One-line governance action, no VGO code change. *(VYT.OFFICER_ROLE was correctly revoked = false.)* Severity High (admin-upgrade-gated + engine dormant), not Critical.

### VGO-H2 — `_authorizeUpgrade` (ADMIN_ROLE, no timelock) is the dominant lever, amplified by H1 · **High (admin-trust)**
A single EOA admin (`0x8310eA7E`) can instantly replace all logic with no upgrade delay. Because VGO **still holds VCO.OFFICER_ROLE (H1)** and is **VGC's sole minter**, a malicious upgrade can weaponize cap inflation and/or unbounded VGC mint (subject to VGC's ceiling). `initialize` doesn't lock the ADMIN↔DEFAULT_ADMIN hierarchy, so a botched handoff that moves only one role leaves a backdoor. *Fix: migrate DEFAULT_ADMIN_ROLE **and** ADMIN_ROLE atomically to a TimelockController + upgrade delay; renounce from the EOA.*

### VGO-M1 — VGC gas-burn farming via the 1.25× multiple (officer-trust; bounded by VGC ceiling) · **Medium**
`payReward` mints `1.25× · gasUsed · baseFee` worth of VGC, where `gasUsed` is metered by VGO (`gasStart − gasleft() + 21000 + finalOverheadGas`). A **compromised OFFICER** can burn gas between `beginReward` and `payReward` (or a keeper can inflate the gas of an officer's permissionless poke) to mint VGC at **~25% over the burned base-fee cost** — a positive-EV loop, repeatable up to **VGC's per-epoch ceiling**. With `maxBaseFeeWei = 0`, a base-fee spike scales rewards up. *Bounded by: OFFICER_ROLE being trusted contracts; the VGC epoch ceiling (the global cap, in VGC); VGC liquidity/value. Fix: keep the VGC ceiling sane + low; consider a `maxBaseFeeWei` cap; only grant OFFICER_ROLE to audited officers.*

### VGO-M2 — VGC token is an UNAUDITED hard dependency (the emission cap lives there) · **Medium (dependency)**
VGO is VGC's sole minter, but the **per-epoch mint ceiling (`epochMintBps`, 0=halt) — the emission cap + kill-switch — is enforced inside the VGC token**, not in VGO. If VGC lacks/mis-sets the ceiling, or doesn't actually lock the minter as VGO, VGC emission is unbounded (combines with VGO-M1). **VGC must be audited and its ceiling confirmed/set before `wireVgc` enables rewards.**

### VGO-M3 — DAX swap-whitelist is a quote-integrity knob (whitelisted-swapper skew) · **Medium**
`_quoteVgcForWeth` uses DAX reserve-ratio **mid-price with no slippage guard**. A **whitelisted swapper** can move the VY/WETH or VGC/VY reserves to skew the quote and inflate a reward (note **VBBO is on both VGO's OFFICER_ROLE and the DAX swap-whitelist**). Bounded by the VGC ceiling. *Fix: freeze the DAX swap-whitelist to the audited set before lock; keep the VGC ceiling sane.* Keepers themselves can't move reserves (the private DAX is swap-permissioned — see VGO-L1).

### Lows / Informational
- **VGO-L1 — spot-quote integrity rests on private-DAX permissioning.** `_quoteVgcForWeth` mid-price is safe to spot-read **iff** the private DAX (`0xD256C672616f…`) has no permissionless swap and keepers aren't whitelisted. *Confirm before `wireVgc`.* Unseeded pool → quote returns 0 → no mint (safe).
- **VGO-L2 — `wireVgc` pool discovery takes the *last* pool whose `asset == weth`/`== vgc`** (loop has no `break`). DAX `hasPool[asset]` enforces singleton assets so duplicates can't coexist; the real (admin-gated, reversible) risk is re-seeding a pool with toxic reserves then re-running `wireVgc`. Curate DAX; re-run after any reseed.
- **VGO-L3 — `maxBaseFeeWei = 0` (uncapped).** Rewards scale linearly with block base fee; a spike inflates VGC mint (bounded by the epoch ceiling). Set a sane cap (e.g. 100–200 gwei) via `setMaxBaseFeeWei`.
- **VGO-L4 — `rescueEth`/`rescueToken` arbitrary `to` (ADMIN).** VGO holds ~dust; negligible blast radius. Timelock.
- **VGO-L5 — `wireVgc` does not validate pools are seeded.** It succeeds even if reserves are 0; then `payReward` silently returns (no mint/event). *Gate activation on `isPayoutReady() == true` after `wireVgc`.*
- **VGO-I1 (positive): no VY pull / no VCO cap mutation in the new logic** — the dangerous prior surface is gone (inert slots); VYT.OFFICER_ROLE revoked.
- **VGO-I2 (positive): auth + reentrancy** — `beginReward`/`payReward` are OFFICER_ROLE only; transient gas slot keyed per-officer (`keccak(seed, msg.sender)`, no cross-officer collision); `payReward` is `nonReentrant`, clears the slot (no double-claim off one `beginReward`), `gasStart==0` → `NoBeginReward`; best-effort on the officer side (reverts don't brick the poke).
- **VGO-I3: DORMANT live** — `vgc=0`, `isPayoutReady=false`; no VGC mintable until `wireVgc`. No live emission today.
- **VGO-I4: storage** — in-place V3→V4 upgrade preserves the inert legacy layout; appended `vgc`/`vgcVyPoolId`/`rewardMultipleBps`/`maxBaseFeeWei` consume old `__gap` (41→37). *(Workflow scrutinizing layout integrity.)*
- **VGO-I5: no runtime setter for `rewardMultipleBps`/`finalOverheadGas`** — re-tune = re-upgrade (reduces admin surface; a strength).

---

## Handoff / activation requirements
1. **Revoke `VCO.OFFICER_ROLE` from VGO** (on the VCO) — the standing fix for VGO-H1 / VCO-CC4. A gas officer needs no cap-mutation power.
2. **Before calling `wireVgc` (the activation switch):** audit the **VGC token** (sole-minter lock + per-epoch ceiling — VGO-M2) and confirm the **private DAX** has no permissionless swap + the VY/WETH and VGC/VY pools are seeded/curated (VGO-L1/L2). Set the VGC epoch ceiling low/sane (VGO-M1).
3. Migrate **`DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE`** (`0x8310eA7E`) → TimelockController + upgrade delay; **revoke both from the EOA** (DEFAULT_ADMIN administers ADMIN). `_authorizeUpgrade` is the dominant lever (amplified by the still-held VCO role until revoked).
4. Consider setting a `maxBaseFeeWei` cap (VGO-L3). Only grant OFFICER_ROLE to audited officers (VLM/VBBO/`0x7a0E5824` today + the MEV bot if/when wired).
