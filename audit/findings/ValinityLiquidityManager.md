# Audit: ValinityLiquidityManager (VLM) — contract 7

> **RECONCILED** with multi-agent adversarial workflow `wlekavf32` (24 agents; 13 findings → 10 survived / 3 refuted, then severity-corrected on refutation). **Verdict: CLOSED (non-admin) — no arbitrary-destination leak**, exhaustively confirmed. **0 Critical / 0 High / 0 Medium / 1 Low** (bounded snapback MEV) + handoff-watchlist Info items. The adversarial pass **corrected two of my preliminary calls**: (1) the MEV is **Low not Medium** (the economic gate is TWAP-priced → no cheap bypass; `computeMinOut` recomputes at the manipulated price → no additive slippage stacking); (2) `twapInterval`/`maxTickDeviationBps` are **not "frozen forever"** — no one-tx setter, but tunable via UUPS upgrade which governance retains.

- **Proxy:** `0x920AbB09be0abeB9140fB0c69A7cD523b65D2Aa0` → **UUPS impl** `0xcB147742077f512765a7CD1D14C1ABE6684323D9`
- **External library (DELEGATECALLed):** `V3SnapbackGate` @ `0x5c3baf319CdF830c00de45aF1e7AC9535B9ef251`
- **Source:** as-deployed `ValinityLiquidityManager.sol` (1417 ln) · solc 0.8.27 · UUPS + AccessControl + ReentrancyGuardTransient + IERC721Receiver
- **Role in flow:** the protocol's **liquidity officer** — sole author of the system's Uniswap V3 positions. Holds **VLM_ROLE on VRT** (fund/receive-position/snapshot) and **OFFICER_ROLE on VGO** (keeper rewards). It is one of the four VRT role-holders (alongside VLO, VBBO, VRYO).

## Gate 1 — Source == Live ✅ (metadata-hash proven; VLO-pattern drift)
The on-disk hardhat-deploy artifact (`numDeployments:3`, solcInput `72e4f9a0…`) is the **stale V3 build** (13,494 B) — live impl is the larger **V4** (24,433 B meta-stripped). The workspace `.sol` is committed clean at `a89611b`, but recompiling `a89611b` gives metadata `9570a079…` ≠ live `d69e1a26…` (24-byte code delta). Tracing git history:
- VLM differs between `a89611b` (now) and **`c4bfc30`** by exactly **1 line** — an *added* ADMIN-only guard in `setSnapbackPairs` (`if (pairA_ != 0 && pairA_ == pairB_) revert InvalidAddress();`).
- Recompiling the **`c4bfc30`** VLM source (inside the a89611b standard-json input) → **24,433 B + metadata `d69e1a26…f149a301a9` == live, byte-for-byte.** ✅ Gold-standard proof.
- The DELEGATECALLed library `V3SnapbackGate` was deployed separately (solcInput `211db5a0…`); recompiling it → 5,129 B + metadata `08a6c1e9…` == live library `0x5c3baf31…`. ✅

**Conclusion:** Live VLM = commit `c4bfc30`; live library = as-deployed source. The workspace is **1 ADMIN-only hardening line ahead** of live (not yet redeployed) — does not affect the permissionless circuit. As-deployed sources saved to `audit/asdeployed/ValinityLiquidityManager/` (+ `_MANIFEST.json`). See [VLM doesn't own its NFTs] memory.

## What it is — Uniswap V3 position manager ("snapback")
VLM mints/rebalances concentrated-liquidity positions for VRT-owned reserves. **NFTs are minted DIRECTLY to VRT** (`recipient: address(vrt)`, L1083); VLM never holds the NFT — it acts as an NPM-approved operator. Per pair it keeps a canonical `PositionSnapshot` in VRT.

| Function | Access | Effect |
|---|---|---|
| `snapbackHome()` | **PERMISSIONLESS**, nonReentrant | Re-center oldest cooldown-eligible registered pair: close (decreaseLiquidity+collect→VLM+burn), zap via swapRouter, mint new position→VRT. **No VRT pull, no VRT push** (dust stays on VLM). Pays `msg.sender` a VGO reward (try/catch; skipped if caller==vryo). **Silent-skips** (returns (0,0), no revert) on paused/cooldown/TWAP-misaligned/uneconomic. |
| `refreshSnapshot(pairKey)` | **PERMISSIONLESS**, nonReentrant | Update VRT snapshot. TWAP-guarded. Throttled by `minRefreshInterval` (silent return). No token movement. |
| `assertTwapAligned`, `previewSnapback`, `snapbackConfig` | view | read-only |
| `mintPosition`, `adminRebalance`, `burnPosition` | ADMIN, nonReentrant | lifecycle (mint pulls seed from VRT once per pair via `seedConsumed`) |
| `configurePair`, `setRangeBps`, `setSlippage`, `setPaused`, `setSnapbackPairs/Params`, `setSnapbackV4`, `rescueTokens`, `_authorizeUpgrade` | ADMIN | config / rescue / UUPS |
| `onERC721Received` | view | always reverts (NFTs never enter VLM) |

**Live state (mainnet):** paused=false; vrt=`0x06087789…`; **vryo=`0xa95749f5…` (matches VRT's VRYO role-holder ✅)**; vgo=`0x0a6c2117…`; npm/factory/swapRouter = **canonical Uniswap V3** ✅; nearBandBps=2500; snapback **defaultBps=200 (2%)**, **cooldown=21600s (6h)**, 2 registered pairs. twapInterval/maxTickDeviationBps internal (defaults **1800s / 300bps = ±3%**).

## Gate 0 — Atomic fund flow / CLOSED-CIRCUIT (permissionless) — my read: CLOSED, no arbitrary-destination leak
Every permissionless token movement has a **hardcoded** destination:

| Edge (line) | Token | Destination | Class |
|---|---|---|---|
| `_mint` mint (1083) | token0/1 (LP) | **`address(vrt)`** (position owner) | fixed-internal |
| `_execSwap` swap out (1396) | token | **`address(this)`** (VLM) | fixed-self |
| `_closePosition` collect (1040) | token0/1 | **`address(this)`** (VLM) | fixed-self |
| `_sweepToVRT` (1295) | token | **`address(vrt)`** | fixed-internal |
| forceApprove (1067-68, 1390) | — | npm / swapRouter only | bounded approval |
| `rescueTokens` (524) | any | arbitrary `to` | **ADMIN only — excluded** |

→ **No permissionless path sends any token or LP value to a caller-chosen address.** Mint→VRT, swap→self, collect→self, sweep→VRT are all hardcoded. The DELEGATECALLed `V3SnapbackGate` is **`view`-only** (no SSTORE/transfer/value-CALL; reads only the passed pool/NPM) → cannot redirect funds or corrupt VLM storage. The only `msg.sender`-facing value is the **VGO gas-reward**, bounded by VGO + cooldown + economic gate.

## Findings (reconciled): 0 Critical, 0 High, 0 Medium, 1 Low, rest Info
| ID | Sev | Finding |
|---|---|---|
| **VLM-L1** | **Low** | **Bounded snapback zap MEV (sandwich).** `snapbackHome` re-centers on **slot0**, and `V3ZapMath.computeMinOut` derives the zap's `minOut` floor from the **same slot0** (`_execSwap` uses `sqrtPriceLimitX96: 0`, line 1400) — so the floor moves *with* a price nudge. A sandwicher can push spot within the **±maxTickDeviationBps (±3%)** alignment tolerance, trigger snapback, extract, and restore. **Refuted amplifiers (kept it off High/Medium):** the economic gate (`V3SnapbackGate.check`) computes `inRange`/`nearBand`/`Y`/`C` entirely from the **1800s TWAP tick, never slot0** → a single-block sandwich can't flip the gate; and `computeMinOut` recomputes expected output *at the manipulated price* then subtracts fee+slippage → the band does **not** stack additively with the manipulation. **Bounded:** extractable ≲ `swapAmt × (300 + zapSlippageBps + poolFee)/1e4 − attacker round-trip cost`, where `swapAmt` is one leg's imbalance (never the full position); ≤**4 cycles/day** (6h cooldown); typically **<1% of position value/cycle**. Closed circuit holds (no redirect). Scales with admin params (hard caps: maxTickDev≤1000, slippage≤500). |
| **VLM-I-gate** | Info | Economic gate decides on **TWAP** (not slot0) → manipulation-resistant; execution guarded by slot0-vs-TWAP ±3%. Sound design. `costMgd` confirmed a reasonable lower bound; the `!inRange`/`nearBand` bypass is **not cheaply abusable** (TWAP-priced — needs sustained multi-block capital to move the 30-min window). *(My preliminary VLM-L1 "cheap cost-gate bypass" was refuted here.)* |
| **VLM-I-lib** | Info | `V3SnapbackGate` **is** delegatecalled (linked-library `check` L849 / `assertTwapAligned` L1280 — one finder wrongly said staticcall) but is **safe**: zero state vars, zero state-writing/value-moving opcodes (no SSTORE/.call/transfer/forceApprove/selfdestruct/assembly), all view/pure → no storage collision, no recipient/approval mutation. |
| **VLM-I-approve** | Info | `_mint` `forceApprove`s the *desired* (not consumed) amounts (1067-68) → small residual allowance left to the **canonical immutable npm** (overwritten next cycle, attacker can't become spender). `_execSwap` approves exact amountIn. No leftover-allowance surface. |
| **VLM-I-dust** | Info | `V3ZapMath.computeRebalanceSwap` line 105 can floor a few-wei deficit to `s=0` — but functionally identical to the deliberate sub-1bp dust-skip (L1345); self-correcting next cycle, no value loss. |
| **VLM-I-snapshot** | Info | `refreshSnapshot` (permissionless) moves no tokens — only TWAP-guarded VRT snapshot writes; throttled; can't capture a manipulated spot (reverts on deviation). |
| **VLM-I-nft** | Info | NFTs minted to VRT (permanent owner); VLM never owns them; `onERC721Received` always reverts. Matches [project_vlm_nft_ownership]. |
| **VLM-I-vryo** | Info | `vryo` exempt from VGO reward (avoids double-pay); live vryo == VRT's VRYO role-holder ✅. VGO reward pays from a separate contract (try/catch, non-blocking) — not a VLM egress. |

## Governance-handoff watchlist (reconciled — confirm before irreversible lock)
- **`twapInterval` / `maxTickDeviationBps`** — set in `initialize` (1800s/300bps); **confirmed NO external setter**. **Correction:** they are NOT "frozen forever" — they're ordinary mutable storage and governance retains `_authorizeUpgrade` (UUPS), so they're retunable **via an implementation upgrade**, just not a one-tx setter. The bounds constants `MIN/MAX_TWAP_INTERVAL`/`MAX_ALLOWED_TICK_DEVIATION_BPS` (170-176) are **dead code** (never referenced). **Decide deliberately:** accept 1800s/300bps as long-term defaults, OR ship a runtime-tunable setter in an impl upgrade **before** handoff (cheaper than post-handoff). ±3% is the live MEV ceiling for VLM-L1.
- **`zapSlippageBps` / `mintSlippageBps` / `closeSlippageBps`** per pair (≤500bps=5% hard cap) — these feed the slot0-derived floors → directly bound VLM-L1. Confirm tight values now. **Note:** `setSlippage` does NOT touch `zapSlippageBps` — it's set only in `configurePair` (reverts on active pair), so retuning it post-handoff requires `burnPosition` + reconfigure. Verify it now.
- **Pool observation cardinality** of the 2 registered snapback pools — low cardinality ⇒ weak TWAP ⇒ wider MEV + gate manipulation. Verify high-cardinality before lock.
- **snapback `cooldown` (6h) / `defaultBps` (2%) / `nearBandBps` (2500)** — confirm intended; a too-wide `nearBandBps` increases benign-but-frequent (TWAP-priced) rebalances → more VLM-L1 cycle opportunities.
- **`vgo` / `vryo` wiring** — vryo ✅ matches VRT role-holder; confirm vgo reward economics can't be farmed (assess at VGO audit).
- **`rescueTokens`** — admin/governance can pull any ERC20 from VLM post-handoff (VLM holds only transient dust + in-flight amounts); no in-contract timelock/whitelist/cap → governance timelock+quorum is the safeguard.
- **`_authorizeUpgrade` (UUPS)** — master permanent power: replaces all logic incl. every guard above. codehash/timelock + dedicated UPGRADER_ROLE.

## Cross-contract dependencies
- **VRT (VLM_ROLE):** fund/receive-position/snapshot/clear — VRT audited (closed relative to roles) ✅.
- **VGO (OFFICER_ROLE):** keeper reward bracket (try/catch; non-blocking) — VGO to-audit; assess reward-farming there.
- **VRYO:** calls snapbackHome/refreshSnapshot permissionlessly; reward-exempt — to-audit node.
- **Uniswap V3 (NPM/Factory/SwapRouter):** canonical addresses ✅.
- **Shared admin key** across the officer set.

## Check-off
- [x] Source == live (**metadata-hash proven**: live VLM = `c4bfc30`; live library matches; workspace 1 admin line ahead)
- [x] Fund-flow mapped — CLOSED, no arbitrary-destination leak (my read)
- [x] Live-state read (recipients, roles, snapback params — all consistent)
- [x] Multi-agent adversarial workflow `wlekavf32` reconciled (24 agents; 10 survived / 3 refuted; severities corrected on refutation)
- [x] **User agrees → checked off 2026-06-01**

## Final tally (reconciled): 0 Critical, 0 High, 0 Medium, **1 Low** (VLM-L1 bounded snapback zap MEV — no redirect, ≤4 cycles/day, <1% position value/cycle), rest Info.
**The closed circuit HOLDS** — no permissionless path sends any token or LP value to an attacker-chosen address (mint→VRT, swap→self, collect→self, sweep→VRT all hardcoded; delegatecalled library is view-only; only arbitrary-`to` transfer `rescueTokens` is admin-gated). The single real residual is a small, well-bounded, no-redirect MEV leak on the permissionless `snapbackHome`, governed by admin params with hard ceilings. The only material handoff-ergonomics gap is the absence of a runtime setter for `twapInterval`/`maxTickDeviationBps` (adjustable only via UUPS upgrade). **Recommended pre-handoff:** confirm tight per-pair slippage (esp. `zapSlippageBps`, which needs burn+reconfigure to change), verify the 2 snapback pools are high-cardinality, and decide whether to ship a TWAP-guard setter before lock.
