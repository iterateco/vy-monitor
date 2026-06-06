# ValinityExchangeOfficer (VEO) — Security Audit

> **STATUS: RECONCILED with multi-agent workflow `wqoqdl1g7` (46 agents, 5 survived / 32 refuted). Awaiting user check-off.**

| | |
|---|---|
| **Contract** | ValinityExchangeOfficer (VEO) — the single public-facing swap router |
| **Proxy** | `0x48C88B807B13593BAc4a5ea75EbD4fec83F827D7` (UUPS) |
| **Live impl** | `0xd20b0c8be6de08a1235ed75ed814cc1fabbe64a5` |
| **Source==live** | ✅ **PROVEN — metadata IPFS hash equality (gold standard)**: `1220f6c52b99…` recompile == live. solc 0.8.27, optimizer runs=100, cancun. Source = workspace `contracts/exchange/ValinityExchangeOfficer.sol` (HEAD `11dcc32`, git clean). Closure = 1 repo file + 22 stock OZ v5 files. |
| **Verdict** | ✅ **CLOSED non-admin — 0 Crit / 0 High / 0 Med / 0 Low permissionless.** All material items are admin-trust/handoff (resolved by Fase 4) or accepted cross-contract notes. **CC-1 fully discharged: VEO provides NO atomic sandwich primitive.** |

## Source verification note (important)
The on-disk Hardhat **deployment json** (`deployments/eth_mainnet/ValinityExchangeOfficer.json`) has metadata `122060cbd903…` and a `deployedBytecode` that does **NOT** match live — it is a stale/different-settings compile, and the live impl was UUPS-upgraded past the committed deployment record. **Do not trust it.** Proof of source==live is the **build-info `21058a62` standard-json recompile of the current workspace source**, which reproduces the live metadata IPFS hash **exactly** (`1220f6c52b99…`). Metadata-hash equality ⟹ identical source closure + compiler settings ⟹ identical bytecode. As-deployed saved to `asdeployed/ValinityExchangeOfficer/`.

## What VEO is
The only **public-facing trading router** in Valinity. Registered traders swap through it; it charges a flat **0.7%** protocol fee (`feeBps`, hard cap `MAX_FEE_BPS = 2%`), converts the skim to **VY** and sends it to **VBO** (BuybackOfficer). It is the **only public swap-whitelist member on DAX**, is **VY-fee-exempt**, and is whitelisted on each V-DAO. Swap surface:
- `swapDAX` — VY↔asset on the private DAX AMM (two-sided fee routing).
- `swapUniV3` / `swapBridged` — Uniswap V3 single-hop / multi-hop.
- `swapMintOndoGM` / `swapRedeemOndoGM` — Ondo GM tokenized assets via a fixed-selector low-level call.
- `swapVDAO` — V-DAO token ↔ {VY | pairAsset}, with the 0.7% pushed direct to the V-DAO creator.

Every swap is `nonReentrant whenLive beforeDeadline`. `whenLive` requires `isRegistered[msg.sender] && !paused`. **Registration is VARO-only** (`register(trader)` is a pure flag-flip; the legacy self-register path is removed). One swap per tx; no multicall/batch/flash primitive.

## Live state — VEO IS DORMANT
- **`varo == address(0)`** and **`TraderRegistered` count == 0.** Because `register`/`registerVDAO` require `msg.sender == varo`, with VARO unset **no one can register**, and every swap reverts `NotRegistered`. **VEO is inert today** — the safest possible state. It activates only when governance sets `varo = VARO` and traders pay VARO Tier 1.
- `feeBps = 70` (0.7%), `defaultUniFee = 3000`, `paused = false`.
- `DEFAULT_ADMIN_ROLE` & `ADMIN_ROLE` both held solely by `0x8310eA7E…4a09` (the Fase-4 handoff subject).
- Confirmed on-chain: DAX `swapWhitelist[VEO] = true`; VY `isWhitelisted[VEO] = true`.
- All wired addresses match the ecosystem: vy/usdc(canonical)/vbo/dax/uniRouter(UniV3)/vyUsdcV2Router(UniV2).

## 1. Closed-circuit (priority #1) — CLOSED in the non-admin path
Every token exit across all 7 public swap functions (and helpers `_swapVDAOLeg`/`_collectFeeAsVY`/`_collectVDAOFee`) lands at exactly one of **four hardcoded destinations**:
1. **`msg.sender`** — user output (DAX/Uni recipient = `msg.sender`, or `address(this)`→`safeTransfer(msg.sender)`): lines 370, 377, 423, 446, 484, 551, 556, 606, 614, 713.
2. **`vbo`** — protocol fee as VY, hardcoded across all 4 fee routes: 864 (ROUTE_VY), 868 (ROUTE_DAX_ASSET), 870 (ROUTE_USDC), 887 (ROUTE_EXTERNAL).
3. **`creator`** (= `vdaoCreator[vdao]`, VARO-set) — V-DAO creation fee: line 731.
4. **`address(this)`** — transient intra-tx only; always followed by a user/fee transfer in the same call frame; never persists (VEO holds ~zero between txs).

**There is no caller-supplied recipient parameter anywhere in the non-admin surface.** Ondo output is validated by `balanceOf` delta (mint 543/548/549, redeem 586/590/591) and pushed to `msg.sender` — `quoteCalldata` cannot redirect it. The only arbitrary-`to` is `rescueToken` (line 995), `onlyRole(ADMIN_ROLE)`, bounded to dust. Every swap is `nonReentrant`; no external venue calls back into VEO. **No drain path exists.**

## 2. CC-1 resolution (priority #2 / headline) — NO atomic sandwich via VEO
The DAX audit deferred the officers' `minOut=0` no-sandwich guarantee to VEO + StakingRouter. **Decisive structural fact: the officers do NOT route through VEO** — VAO/VBBO call DAX *directly*. A registered VEO trader front/back-running an officer's DAX-direct tx is ordinary block-builder ordering MEV; a VEO-side price-band would not reduce officer exposure because officers never call VEO.

The three logged DAX obligations, discharged:
1. **No atomic move-then-revert around an officer tx — DISCHARGED.** One swap per tx, `nonReentrant`, no multicall/callback/flash. An attacker's `swapDAX` moves the pool price (a real swap) but cannot reverse it within the same call frame.
2. **VEO applies its own slippage on routed DAX swaps — DISCHARGED on every user leg.** `swapDAX` forwards caller `minAmountOut` to DAX (370) or enforces `netOut < minAmountOut` (376); V-DAO leg enforces minOut (754 sell / 712 buy net); public-pool fee legs enforce `minFeeVYOut` (870, 887). The **only** residual `minOut=0` is the `ROUTE_DAX_ASSET` fee leg (868) on the *private* DAX pool — recipient hardcoded `vbo`, ≤0.7% of one leg, accruing to the protocol's own sink, non-atomic.
3. **No same-block round-trip primitive on reserve-asset pools — DISCHARGED.** Each call executes exactly one directional `dax.swapExactIn` (370 XOR 373); no asset→VY→asset in one call. A buy-then-sell round trip needs two separate txs, each paying VEO's 0.7% + DAX spread on a value-conserving pool = net-negative generic MEV.

**Conclusion:** the atomic-exploit question is answered **NO**. The residual is multi-tx mempool MEV against the officers' own DAX-direct submissions — to be mitigated **officer-side** (private relay / non-zero minOut). It is **not** a VEO defect.

## 3. Findings (reconciled severities)
**Permissionless-exploitable (non-admin drain): NONE.** All 32 attack-claims refuted (non-atomic MEV, self-harm, FoT-reverts-not-slippage, or admin-gated).

### Cross-contract obligation
| ID | Sev | Title | Disposition |
|---|:--:|---|---|
| VEO-CCO1 | Info | `ROUTE_DAX_ASSET` fee leg `minOut=0` (line 868) on the private DAX pool | Obligations (1)/(3) discharged; (2) N/A (no atomic sandwich on the private leg). Recipient hardcoded `vbo`; ≤0.7% of fee notional to the protocol's own sink; non-atomic. **Accepted by design.** MEV-submission discipline pushed to officers + StakingRouter. |

### Admin-trust / handoff (neutralized at Fase 4)
| ID | Sev | Title | Line |
|---|:--:|---|---|
| VEO-AC-007 | Info | **`_authorizeUpgrade` gated on `ADMIN_ROLE` (NOT `DEFAULT_ADMIN_ROLE`)** — the DOMINANT vector; subsumes every setter below | 1002 |
| VEO-AC-001 | Info | `setVBO` can redirect the future fee stream (≤2% cap) | 963 |
| VEO-AC-002 | Info | `rescueToken` arbitrary `to` — bounded to dust (zero resident balance); intended escape hatch | 990-996 |
| VEO-AC-003/004 | Info | `setVyUsdcV2Router` / `setDAX` / `setUniRouter` repoint + max approve — in-flight-only damage; subsumed by upgrade | 965-966, 977-980 |
| VEO-AC-005 | Info | `setPaused` griefing/DoS — standard emergency control, no fund movement | 969-972 |
| VEO-AC-006/008 | Info | `varo` gatekeeps registration (intended); dormant `varo==0` / 0 traders (safest state) | 964, 187/324/642 |
| VEO-AC-010 / CC1-005 | Info | Fee hard-capped 2% (`MAX_FEE_BPS`); `setFeeBps`/`setDefaultUniFee` reversible + caller-overridable | 114/953, 952-961 |
| VEO-ONDO-2 | Info | Max USDC approve to `ondoGM` — `setOndoGM` ADMIN-only; subsumed by upgrade | 967 |
| VEO-VDAO-010 | Info | **VARO must validate `daxPoolId`/`pairAsset` on registration** — VEO does not; bounded by user minOut | 636-660 |
| VEO-VDAO-002 | Info | Malicious VARO `creator` → fee misdirection (≤0.7% V-DAO vol); not a drain | 656, 731 |

### Informational / not-a-bug
| ID | Sev | Title |
|---|:--:|---|
| VEO-AC-009 | Info | No atomic VEO sandwich on officers' minOut=0 (inverted finding — confirmed correct) |
| VEO-VDAO-008 | Info | `daxPoolOf` cache survives DAX upgrade/pause; stale poolId reverts safely |
| VEO-VDAO-003…007 | Info | V-DAO config-poison / FoT / V2 multi-tx MEV / no secondary band — all bounded by user minOut, value-conserving, no drain |
| VEO-ONDO-1/3 | not-a-bug | `quoteCalldata` + balanceOf-delta sound; self-harm only |
| VEO-ERC20-1…5, CC1-002/004, VEO-FEE-002 | not-a-bug | FoT-as-tokenIn **reverts** (not silent slippage), per docs 94-97; V2-router guard `V2RouterNotSet` (780); DAX-oracle dep = admin-trust; `registerVDAO` pause-asymmetry cosmetic |

**Net: 0 Critical / 0 High / 0 Medium / 0 Low. All items Info — admin-trust/handoff or accepted design.**

## 4. Fase-4 handoff conditions (VEO-specific)
VEO is safe to hand off **only if**:
1. **Migrate `ADMIN_ROLE`, not merely `DEFAULT_ADMIN_ROLE`.** `_authorizeUpgrade` is gated on `ADMIN_ROLE` (line 1002) — transferring DEFAULT_ADMIN alone does NOT neutralize upgradeability. **Explicitly revoke `ADMIN_ROLE` from the legacy admin `0x8310eA7E…4a09`** and place it under a TimelockController (≥48h) controlled by on-chain gov. DEFAULT_ADMIN is the role-admin of ADMIN_ROLE — migrate both atomically.
2. **Timelock-gate all ADMIN_ROLE knobs:** `_authorizeUpgrade` (1002, dominant), `setVBO` (963), `setVaro` (964), `setDAX` (965), `setUniRouter` (966), `setOndoGM` (967), `setVyUsdcV2Router` (977), `rescueToken` (990), `setFeeBps` (952), `setDefaultUniFee` (958), `setPaused` (969).
3. **Going live (gov action):** with `varo==0`, VEO cannot swap. Verify `dax`/`uniRouter`/`vbo`/`ondoGM`/`vyUsdcV2Router` are correct canonical addresses, then call `setVaro(governance_VARO)` to activate. Until then VEO is inert — do not rush this.

## 5. Obligations pushed to other contracts
- **VARO** (control plane — audit separately): sole `register`/`registerVDAO`/`vdaoCreator`/`daxPoolOf`/`vdaoPairAsset` authority; must off-chain validate `daxPoolId == dax.assetToPoolId(vdao)` and that `pairAsset` is a vanilla hook-free/fee-free ERC20 (VEO does not). Mis-registration → DoS one V-DAO leg or misdirect that V-DAO's 0.7% creator fee; bounded, no drain. Also the consumer of `cumulativeUserFeeVY` (monotonic per-trader counter VEO records at 803-805) for **referral payouts** — verify VARO's consumption at the VARO audit. Gov must control which contract is VARO post-handoff.
- **StakingRouter** (the OTHER half of CC-1 — also a DAX swap-whitelist member): the same 3 DAX obligations must be independently discharged there. **Open — not covered here.**
- **Officers (VAO/VBBO):** the residual `minOut=0` sandwich risk is theirs — mitigate **submission-side** (private relay/Flashbots, or non-zero `minAmountOut`). Not a VEO defect.

---
**Bottom line:** VEO's non-admin path is provably closed — zero permissionless drain, zero arbitrary-destination leak. CC-1 atomic-sandwich resolved **NO**; all 3 DAX obligations discharged at VEO. VEO is **SAFE to hand off** provided `ADMIN_ROLE` (not merely `DEFAULT_ADMIN_ROLE`) is migrated to timelocked governance. StakingRouter's half of CC-1 is the only major open ecosystem obligation.
