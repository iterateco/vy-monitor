# ValinityGasOfficer (VGO) — Findings · **RE-AUDIT (curve+tip v5, now LIVE)**

**Address:** `0x0a6C21174d039f5D85dA93FCB3FE7ad5F5f5E827` (UUPS proxy) → impl `0x70F4416607a7ea762bDB32fdB393D3060705Dc36` (8,090 B)
**Source==live:** PROVEN (gold standard, both legs) — live impl metadata-IPFS `1220db78d60935722be462b89be8804c6478e9c9add7e2190fa4a8180a07474bd6b0` == hardhat artifact deployedBytecode metadata == build-info `c3d525c0` compile of workspace `contracts/officer/ValinityGasOfficer.sol` (514 ln, source keccak `0xd21acfdd…` == workspace; deployed-from-workspace, git-`M` but workspace == live). solc 0.8.27 / runs=100 / cancun.
**Audit workflow:** `wu2ofpcrf` (joint VFO+VGO, 7 dimensions, 86 agents, adversarial 2-skeptic default-refute) — **0 permissionless-exploitable; reward math + emission bound PROVEN sound.**

> ⚠️ **OVERWRITES the prior VGO audit** (impl `0x7c35d9d7`, fixed-1.25× model, dormant). Same proxy, **UPGRADED IN-PLACE** (`reinitializer(5)` / `initializeRewardsV2`) to the **premium-on-base + capped-tip + decay-curve** model. **TWO MAJOR STATE CHANGES:** (1) the prior **BLOCKING item VGO-H1 is RESOLVED** — `VCO.OFFICER_ROLE(VGO) = FALSE` on-chain (revoked); (2) VGO is now **LIVE/ACTIVE** — VGC wired (`minter()==VGO`), `isPayoutReady=true`, **59 RewardPaid events**.

---

## Verdict

✅ **NO VY CUSTODY DRAIN — VGO holds no user funds, pulls no VY, and mutates no VCO cap (VCO.OFFICER revoked). It ONLY mints VGC** (a separate gas-credit/governance token) to a keeper supplied by a roled officer, **HARD-BOUNDED by VGC's own per-epoch ceiling** (enforced inside the VGC token's `mint`, NOT in VGO — proven sound in the VGC audit, `project_vgc_token`). **The entire blast radius of VGO — even a fully malicious upgrade — is contained to VGC emission within that ceiling; it provably cannot touch VY, reserves, or caps.** 0 permissionless-exploitable findings.

Reward model (`payReward`): `gasUsed = gasStart − gasleft() + 21000 + finalOverheadGas`; `perGasWei = mulDiv(premBase, mult, BPS) + min(tip, tipCap)`; `ethValue = min(gasUsed·perGasWei, maxRewardPerCallWei)`; `vgcAmount = midPriceQuote(ethValue)`; `vgc.mint(keeper, vgcAmount)`. **DOUBLE-bounded per call** (maxRewardPerCallWei 0.005 ETH **and** VGC epoch ceiling). The 7×→1.25× premium rides on `block.basefee` only (keeper-unmanipulable); the tip (the only keeper input) is reimbursed ≤1:1 and capped ⇒ **no overpay incentive** (workflow VGO-MATH-1/2, VGO-FARM-2/3 — the farming/overpay attacks were **refuted**).

**Officer set:** `beginReward`/`payReward` are OFFICER_ROLE-gated. Live holders = **{VBBO `0x4B97D45d`, VAO `0x7a0E5824`, VMB `0x6f2F4580`, VARO `0x514F0ABf`, VFO `0x79A9028…`}** — all five are audited Valinity officers (the prior "unknown `0x7a0E5824`" is **VAO**, impl `0xc364f74E`). Transient gas slot keyed per-officer `keccak(seed, msg.sender)` → no cross-officer collision; `gasStart==0` guard.

---

## Findings (reconciled with workflow `wu2ofpcrf` — both skeptics in agreement)

### VGO-D (dominant lever) — `_authorizeUpgrade` controls the sole VGC minter, but the blast radius is capped by the VGC epoch ceiling · **Info→handoff** (admin-trust; NO VY exposure)
`_authorizeUpgrade` (L513) is `onlyRole(ADMIN_ROLE)`. VGO is VGC's **sole, irreversibly-locked minter**. A fully malicious VGO impl could call `VGC.mint(attacker, x)` — but every mint is **re-clamped inside the VGC token** to `epochMintBps·(MAX_SUPPLY − totalSupply)/BPS` per 7-day epoch (VGC L225-227), `epochMintBps ≤` immutable `MAX_EPOCH_MINT_BPS=25` (0.25%/wk), and `VGC.admin` can set `epochMintBps=0` to halt. So the worst case is a **weekly-ceiling-bounded VGC inflation nuisance** to an attacker address — it **provably cannot** mint VY, withdraw reserves, or move any VCO cap (VGO holds no VY custody; VCO.OFFICER revoked; inert legacy `vyt`/`vco` slots never called). *Handoff: co-locate VGO.ADMIN_ROLE (upgrade) and VGC.admin (epoch-bps halt) behind the **same** timelock so the minter and its kill-switch are co-controlled. [VGO-D3]*

### VGO-L1 — Compromised/buggy OFFICER can farm VGC by burning gas between begin/payReward (or drain the weekly budget) · **Low** (bounded; no VY/reserve impact)
A compromised OFFICER_ROLE holder can bracket a call, burn gas, and mint up to `maxRewardPerCallWei` (0.005 ETH) of VGC per call to a chosen keeper — and, by repetition, consume the **entire weekly VGC emission budget** to an attacker address. **Bounded three ways:** per-call cap, the VGC per-epoch ceiling (hard halt past it), and the fact that VGC is a separate token (no VY/reserve/cap impact). The premium rides on `block.basefee` (un-inflatable); the tip is capped 1:1. *Accept-with-monitoring; keep OFFICER_ROLE = audited officers only; VGC.setEpochMintBps(0) is the kill-switch. [VGO-MATH-3 / VGO-FARM-1]*

### VGO-L2 — Whitelisted DAX swapper can skew the mid-price spot quote to inflate VGC minted · **Low** (bounded; privileged-only)
`_quoteVgcForWeth` (L406-413) uses a **mid-price reserve ratio** (not a swap sim) across `wethPoolId` (VY/WETH) and `vgcVyPoolId` (VGC/VY). DAX swaps are `onlySwapWhitelisted`, so a plain keeper **cannot** move reserves in its own tx. A whitelisted swapper (VBBO is on both VGO-OFFICER and the DAX swap-whitelist) **could** push the mid-price to inflate `vgcAmount` — but the realized mint is re-clamped by the VGC epoch ceiling, VGC is disjoint from VY/reserves, and the swapper pays AMM slippage with no clean profit loop. *Accept-with-monitoring; keep the DAX swap-whitelist tightly held. [VGO-D2]*

### VGO-L3 — Cached DAX pool-ids go stale on admin pool removal (swap-and-pop reindex) → wrong-pool quote or payReward DoS · **Low** (admin/ops; bounded)
`wethPoolId`/`vgcVyPoolId` are cached integers set by `wireVgc` (L443). If an admin removes a DAX pool such that the WETH or VGC/VY pool's **index** shifts, the cached id either points at a removed pool (→ `getPoolReserves` reverts → `payReward` reverts, caught by the officer's try/catch → rewards silently halt) or a **wrong** pool (→ garbage mid-price → mis-mint, still hard-capped by the VGC epoch ceiling, which reverts an over-quote past the weekly budget). **No VY/reserve impact, no permissionless trigger** (needs DAX ADMIN + a skipped `wireVgc` re-run). *Fix/handoff: re-run `wireVgc` after any DAX pool add/remove (its NatSpec already says it is re-runnable), or resolve ids dynamically / validate the returned asset address in `_quoteVgcForWeth`. [VGO-D1, downgraded from Medium]*

### Info / positive validations (confirmed; some refuted as non-attacks)
- **VGO-MATH-1/2:** reward math fully bounded (per-call cap + monotonic 7×→1.25× decay, no overflow/underflow; tip underflow-safe since `tx.gasprice ≥ basefee`); **global VGC emission hard-bounded by the VGC token's own per-epoch ceiling**, independent of any officer behavior. ✅
- **VGO-FARM-2 (REFUTED):** a permissionless VFO keeper **cannot** farm VGC without performing a genuine, settled floor defense (the poke reverts unless real work happens). ✅
- **VGO-FARM-3 (REFUTED):** **no** keeper-controlled input can inflate the payout — premium on `block.basefee`, tip capped 1:1, quote on the permissioned DAX. ✅
- **VGO-FARM-4 (Info):** the shared global VGC epoch ceiling lets a heavy officer **starve** honest keepers' rewards within an epoch (reward DoS) — no fund impact.

---

## Handoff checklist
1. **VGO-H1 (prior blocker) — DONE:** `VCO.OFFICER_ROLE(VGO)` is revoked on-chain (verified `false`). ✅
2. Migrate VGO **DEFAULT_ADMIN + ADMIN → timelock**, and co-locate with **VGC.admin** (epoch-bps halt) under the same governance so minter + kill-switch are co-controlled (VGO-D).
3. Keep OFFICER_ROLE limited to audited officers; keep the DAX swap-whitelist tight (VGO-L1/L2).
4. Re-run `wireVgc` after any DAX pool reindex (VGO-L3).
5. Emission safety ultimately rests on the **VGC token** (sole-minter lock + per-epoch ceiling) — audited ✅ `project_vgc_token`.
