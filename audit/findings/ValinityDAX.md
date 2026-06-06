# Audit: ValinityDAX (DAX) — contract 10 · the CC-1 lynchpin

> **RECONCILED** with multi-agent adversarial workflow `w91m0w9q5` (31 agents; 21 findings → 16 survived / 5 refuted, severities corrected; 13 substantive survivors dedup to ~3 facts). **Verdict: CLOSED relative to roles/whitelists — ZERO permissionless entry, no DAX-internal break.** **0 permissionless-exploitable.** AMM/LP math verified **SOUND & value-conserving**. The long-pending **CC-1 resolves with a pivot**: DAX correctly gates swaps; the officers' `minOut=0` no-sandwich guarantee rests on **VEO + StakingRouter** (the public-facing whitelist members) — the residual Critical, if any, lives in *those* contracts, not DAX. As a DAX finding CC-1 is **Medium**; remaining items are Low/Info (one gated LP round-trip leak + basket non-standard-asset hygiene + admin handoff powers).

- **Proxy:** `0xD256C672616f7c5DEE3e42a8199f121EE08401B7` → **UUPS impl** `0x8efde23edc99a4736d1c3e4aba3e75e6830b86f8`
- **Source:** as-deployed `ValinityDAX.sol` (877 ln, solcInputs `cb6d5b6c`) + `VDAX.sol` (166 ln, basket LP) · solc 0.8.27 · UUPS + AccessControl + ReentrancyGuardTransient + Initializable. No external library.
- **Role in flow:** the protocol's **private constant-product AMM** — N pools each `{asset, reserveVY, reserveAsset}`, one basket LP token (VDAX). Officers swap reserve-asset↔VY here at protocol-controlled prices. **No fee.**

## Gate 1 — Source == Live ✅ (triple-confirmed)
artifact.deployedBytecode **== live impl** (bytediff: only 2 UUPS immutables differ). metadata ipfs `7598b902…` **identical** across artifact, recompile-from-solcInputs(`cb6d5b6c`), and live impl. The recorded solcInputs IS the deployed source. As-deployed saved to `audit/asdeployed/ValinityDAX/`.

## What it is — private basket DEX (VY/asset pools, VDAX basket LP)
| Function | Access | Effect |
|---|---|---|
| `swapExactIn(poolId,tokenIn,amountIn,minOut,recipient)` | **swap-whitelist** | constant product (no fee); enforces `minOut`; out→`recipient` |
| `depositVYOnly(vyAmount,recipient)` | **liquidity-whitelist** | VY-only, distributed pro-rata across pools; mint VDAX = `vy×supply/(2×totalVYReserves)` |
| `withdraw(shares,recipient)` | **liquidity-whitelist** | burn VDAX, pro-rata VY+asset from all pools, convert asset→VY internally, return 100% VY |
| `addPool(asset,vySeed,assetSeed)` | POOL_CREATOR_ROLE (VARO) ‖ ADMIN | add a VY/asset pool (arbitrary asset) |
| `initializeFirstPool`/`adminWithdrawRaw`/`adminExtractLiquidity`/`adminInjectLiquidity`/`updateSwapWhitelist`/`updateLiquidityWhitelist`/`updatePauseStatus`/`rescueTokens`/`_authorizeUpgrade` | ADMIN | seed / rebalance / whitelist / pause / rescue / UUPS |
| views (`getPoolReserves`/`getNumPools`/`getTotalVYReserves`/`getUserShare`/`previewWithdraw`/`previewDepositVYOnly`) | view | — |

**Live state (mainnet):** VY=`0x597b2952`, vdax=`0xd985c0ea`; **6 pools** (LINK / token`0xf6b111` / WBTC / WETH / token`0x2d1f72` / PAXG — the basket includes non-reserve "launched/alliance" tokens); totalVYReserves≈174k VY; no pauses.
**Live swap whitelist = {VBBO, VAO, VEO, StakingRouter, VGO}.** Liquidity whitelist includes StakingRouter. (VRYO + live MEVBot `0x6f2F4580` are **not** swap-whitelisted.)

## Gate 0 — CLOSED relative to roles/whitelists — NO permissionless entry
**Every** state-changing function is gated (`onlySwapWhitelisted` / `onlyLiquidityWhitelisted` / `onlyRole` / `POOL_CREATOR_ROLE`). There is **no permissionless entry point and no whitelist-disable toggle**. All token sinks (swap-out, withdraw, extract, rescue) go to a `recipient`/`to` chosen by a **whitelisted or admin** caller; pulls are `safeTransferFrom(msg.sender)`. → DAX is a permissioned vault; its security is the **whitelist composition** + the **AMM/LP math** + **admin powers**, not a permissionless surface.

## The CC-1 resolution (the pivot) — preliminary
The officers' (VBBO/VAO) `minOut=0` swaps assume "DAX is private → no sandwich." **DAX delivers the gating** (only whitelisted addresses swap). **But the whitelist includes public-facing contracts:**
- **VEO (ExchangeOfficer `0x48C88B80`)** — "the only public swap address" → the public can swap on DAX pools via VEO → can move a pool's VY/asset price.
- **StakingRouter (`0x664b3A81`)** — public staking; `depositVYOnly`/`withdraw` move `reserveVY` across **all** pools → moves prices.

→ **The no-sandwich guarantee for officers' `minOut=0` is NOT provided by DAX alone; it rests on VEO + StakingRouter** not exposing a same-block price-move on the officer pools. *The workflow is enumerating the exact VEO + SR obligations.* This is the CC-1 item carried since VAO — it resolves into **obligations on VEO + StakingRouter**, to be discharged in those audits.

## Findings (reconciled): 0 permissionless-exploitable · 1 Medium (cross-contract) · several Low · rest Info
| ID | Sev | Finding |
|---|---|---|
| **DAX-M1 (CC-1)** | **Medium** (cross-contract) | Officers VBBO/VAO swap with **`minOut=0`**. DAX **correctly** restricts swaps to the whitelist and *offers* a `minAmountOut` guard (enforced, L617/640) — the exposure exists only because officers pass 0. The price lever is real: `depositVYOnly` raises **every** pool's `reserveVY` proportionally (L411-417); a `swapExactIn` moves one pool. So a swap-whitelisted (**VEO**) or liquidity-whitelisted (**StakingRouter**) actor can skew the price an officer's minOut=0 swap sees and reverse it same-block. **No DAX-internal break** — the no-sandwich guarantee lives in VEO + StakingRouter (obligations below). The true Critical, if any, is proven there. |
| **DAX-L1** | **Low** | **Single-sided deposit/withdraw round-trip leak** (NOT the divisor-2, which cancels — that root cause was *refuted*). A single-sided VY `depositVYOnly` self-skews each pool's price; an immediate `withdraw` re-values the asset at that skew and pays surplus VY from reserves → a **wealth transfer from other VDAX holders to the round-tripper** (~8–11% worst case), value-conserving system-wide (not minted from thin air), **zero for a lone holder**. Realizable ONLY if **StakingRouter** exposes an atomic deposit+withdraw round-trip → mitigation is a StakingRouter obligation. |
| **DAX-L2** | **Low** | **Basket non-standard-asset desync.** DAX uses **virtual reserves** (no `balanceOf` reconciliation). A fee-on-transfer / rebasing / reverting pool asset (added via `addPool`/VARO or `initializeFirstPool`/admin) drifts `reserveAsset` from real balance; a reverting asset bricks the global `adminWithdrawRaw` loop (but `adminExtractLiquidity` is **per-pool** so healthy pools stay rebalanceable, and `withdraw` returns 100% VY so LP exits are unaffected). All introduction paths role-gated. **Live note: PAXG (pool 5) is fee-on-transfer — verify desync within tolerance / accept.** |
| **DAX-L3** | **Low** | `addPool` (L671) does **no asset-implementation validation** (structural only) → FoT/rebasing onboarding hygiene gap. Reentrancy sub-claim refuted (transient `nonReentrant` everywhere). |
| **DAX-I-inject** | Info | `adminInjectLiquidity` (L844) arbitrary-ratio price lever (admin) + the **stale "MEV bot rebalances afterward" comment** (L840) — the named MEVBot `0x6f2F4580` is **not swap-whitelisted** and cannot rebalance → a post-inject skew persists until a whitelisted swapper acts (operational/doc defect to fix). |
| **DAX-I-rescue** | Info | `rescueTokens` can desync reserves (admin footgun, self-warned L755); grants no extraction beyond existing admin levers. |
| **DAX-I-rori** | Info | Read-only reentrancy via `getTotalVYReserves` during `adminWithdrawRaw` asset transfer — no closed-circuit consumer (officers read single-pool slots only); defensive hardening note. |
| **DAX-I-vault** | Info | No permissionless entry; AMM enforces minOut + InsufficientLiquidity; constant product, no fee; `mulDiv` rounds down (pool's favor). |

## AMM/LP math verdict — SOUND & value-conserving
- **Swap rounding sound:** `Math.mulDiv` rounds down (pool's favor), output bounded by tracked reserves (`InsufficientLiquidity`), `minAmountOut` enforced. Constant product, no fee, prices off live reserves. No rounding exploit, k never decreases via rounding.
- **divisor-2 mint is NOT asymmetric** (original suspicion *refuted*): the 2× scale-down on mint is fully recovered in `withdraw`'s `shares/totalSupply` fraction; round-trip net is invariant. Lone-holder deposit→withdraw-all returns exactly the VY deposited.
- **`withdraw` internal asset→VY conversion conserves value system-wide** (+0). The only leak is DAX-L1 (single-sided round-trip inter-holder transfer), gated + mitigated at StakingRouter.

## ⚠️ Cross-contract obligations (these carry the residual Critical — discharge in those audits)
### VEO (ExchangeOfficer) — the only public swap address on DAX
1. No public path may **atomically move-then-revert** a DAX pool price around an officer tx (no same-block round-trip swap primitive on reserve-asset pools).
2. VEO must apply its **own slippage/price-band** on the DAX swaps it routes (DAX accepts whatever `minOut` VEO passes).

### StakingRouter — public staking (swap + liquidity whitelisted)
3. `depositVYOnly`/`withdraw` must be **non-atomically-round-trippable** (fee / timelock / share-lockup / per-block guard) — this simultaneously closes the **CC-1 sandwich lever (DAX-M1)** AND the **LP round-trip leak (DAX-L1)**.
4. No public staker may drive a large transient all-pool VY injection that sandwiches an officer swap.

### VARO (POOL_CREATOR_ROLE) — the only gate against a basket poison-asset
5. Must never list FoT/rebasing/reverting assets (DAX has no validation + virtual reserves). Audit VARO's listing controls.

### Officer policy
6. VBBO/VAO's `minOut=0` is safe ONLY under (1)–(4) — document it as a guarantee inherited from VEO+StakingRouter, not from DAX.

## Check-off
- [x] Source == live (triple-confirmed: bytediff + metadata ipfs `7598b902` across artifact/recompile/live)
- [x] Fund-flow mapped — CLOSED relative to roles/whitelists, no permissionless entry (my read)
- [x] Live-state read (pools, whitelist membership, pauses — VEO/SR are the public-facing members)
- [x] Multi-agent adversarial workflow `w91m0w9q5` reconciled (31 agents; 16 survived / 5 refuted; severities corrected)
- [ ] **User agrees → check off**

## Final tally (reconciled): **0 permissionless-exploitable**, **1 Medium** (DAX-M1/CC-1 — cross-contract, lives in VEO+SR), **3 Low** (DAX-L1 LP round-trip leak; DAX-L2 basket non-standard-asset desync; DAX-L3 addPool no-validation), rest Info.
**DAX is CLOSED relative to roles/whitelists — no permissionless entry, no DAX-internal closed-circuit break.** AMM/LP math is sound and value-conserving (swap rounds in pool's favor; divisor-2 cancels; no honest-holder round-trip profit). The entire CC-1 risk + the LP leak are **cross-contract obligations on VEO + StakingRouter** — the Fase-4 handoff must be conditioned on those audits. Permanent admin powers (whitelist membership #1, + UUPS upgrade which dominates all) must be vested in **timelocked governance**; **both DEFAULT_ADMIN_ROLE and ADMIN_ROLE** must transfer (initialize grants both to one address; DEFAULT_ADMIN is role-admin of ADMIN). **Token-onboarding policy:** never list FoT/rebasing assets via `addPool` (note PAXG is FoT — accept/verify).
