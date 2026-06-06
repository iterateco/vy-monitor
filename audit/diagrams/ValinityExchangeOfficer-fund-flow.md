# ValinityExchangeOfficer (VEO) — Fund-Flow Circuit · the public swap router (CC-1 discharge)

Proxy `0x48C88B80…7D7` → UUPS impl `0xd20b0c8b…64a5`. The protocol's **single public-facing trading router**. Charges a flat **0.7%** (`feeBps`, hard cap 2%) on every swap; the skim is converted to **VY → VBO** (BuybackOfficer). V-DAO swaps instead push 0.7% (in V-DAO) **direct to the creator**. Source==live **PROVEN by metadata IPFS hash equality** (`1220f6c52b99…`, solc 0.8.27 / runs=100 / cancun). Holds ~zero balance between txs.

> **Convention:** atomic-flow shows ONLY non-admin paths (admin is being removed at Fase 4 — the closed-circuit must hold without it). Admin/governance powers are in the separate box + the permanence watchlist.

> **LIVE STATE — VEO IS DORMANT:** `varo == address(0)` and `TraderRegistered == 0`. Registration is VARO-only; with VARO unset, **nobody can register and every swap reverts `NotRegistered`**. VEO becomes operational only once admin wires `varo = VARO` and traders pay VARO Tier 1. The circuit below describes the *operational* state.

## Access model — gated entry (registered traders only), CLOSED non-admin exits

```
   whenLive = isRegistered[msg.sender] && !paused      (registration flips ONLY via VARO.register)
   every swap fn: nonReentrant + whenLive + beforeDeadline(deadline) ; ONE swap per tx (no multicall/batch)

   ── PUBLIC (registered-trader) SWAPS ──────────────────────────────────────────────
   swapDAX(tokenIn,tokenOut,amountIn,minAmountOut,poolId,minFeeVYOut,uniFeeForFeeLeg,deadline)
        pull tokenIn from msg.sender → skim 0.7% fee (→VY→VBO) → DAX swapExactIn(poolId,…)
        user leg carries minAmountOut (fromInput: forwarded to DAX; !fromInput: 0 then netOut<min check)
        OUTPUT → msg.sender                                            [one side is always VY ⇒ fee = ROUTE_VY direct]

   swapUniV3 / swapBridged          → UniV3 exactInputSingle / exactInput, recipient = msg.sender
   swapMintOndoGM / swapRedeemOndoGM→ ondoGM.call(FIXED_SELECTOR ‖ userCalldata); minted/redeemed → msg.sender; dust → msg.sender
   swapVDAO(vdao,otherToken,sellingVDAO,…)
        0.7% of V-DAO leg → vdaoCreator (VARO-set) ; route VY→DAX V-DAO/VY pool | pairAsset→V2 ; else revert
        OUTPUT → msg.sender

   ── FEE CONVERSION (_collectFeeAsVY) — always lands as VY at VBO ───────────────────
   ROUTE_VY (1)        fee is VY            → vy.safeTransfer(VBO)
   ROUTE_DAX_ASSET (2) asset has DAX pool   → dax.swapExactIn(pool, fee, minOut=0, recipient=VBO)   ⚠ minOut=0
   ROUTE_USDC (3)      fee is USDC          → V2 [USDC,VY] (minFeeVYOut) → VBO
   ROUTE_EXTERNAL (4)  other                → V3 token→USDC → V2 USDC→VY (minFeeVYOut) → VBO

   ── NO permissionless arbitrary-destination. Every non-admin exit ∈ {msg.sender, VBO, vdaoCreator}. ──
```

## Edge ledger (non-admin)
| Edge | Token | Destination | Gate / guard |
|---|---|---|---|
| swap output (all swap fns) | tokenOut / minted | **`msg.sender`** (hardcoded recipient) | whenLive + minAmountOut |
| protocol fee | VY | **`vbo`** (admin-set sink) | feeBps≤2%; user-leg minAmountOut unaffected |
| V-DAO creator fee | V-DAO token | **`vdaoCreator`** (VARO-set) | 0.7% bps |
| dust refund (Ondo) | USDC / GM | `msg.sender` | balance-delta |
| pulls (safeTransferFrom) | tokenIn | from `msg.sender` | — |

## CC-1 discharge — does VEO enable an ATOMIC sandwich of officers' minOut=0 DAX swaps?
```
   officers (VAO/VBBO) swap on DAX with minOut=0, trusting "no sandwich (DAX private)".
   VEO is the PUBLIC swap-whitelist member ⇒ a registered trader CAN move a DAX pool price via swapDAX.
   BUT:  • one swap per tx, nonReentrant (VEO + DAX) ⇒ NO atomic move-then-revert primitive on the same pool
         • swapDAX always has VY on one side ⇒ the fee leg is ROUTE_VY (direct transfer), never a 2nd same-pool DAX swap
         • the user's own leg is slippage-protected (minAmountOut)
   ⇒ The officer-sandwich is GENERIC MULTI-TX MEMPOOL MEV (needs the victim's tx between two attacker txs),
     NOT an atomic VEO exploit. Mitigation lives OFFICER-SIDE (private/MEV-protected submission, or non-zero minOut),
     NOT in VEO. (StakingRouter handles the other half — see its audit.)
   Residual VEO-local: the ROUTE_DAX_ASSET FEE leg uses minOut=0 — but it is only 0.7% of the caller's own swap,
     and a sandwich of it steals from VBO (protocol fee), not the user; economically non-viable. (Low/Info.)
```

**Verdict (RECONCILED, workflow `wqoqdl1g7` — 46 agents, 5 surv/32 ref):** ✅ **CLOSED in the non-admin path — no arbitrary-destination leak** (every exit ∈ {msg.sender, VBO, vdaoCreator, transient self}; VEO holds ~zero between txs). **0 Crit / 0 High / 0 Med / 0 Low permissionless** — all items Info (admin-trust/handoff or accepted design). **CC-1 fully discharged: VEO provides NO atomic sandwich primitive**; all 3 DAX obligations met. Decisive: **officers don't route through VEO** (they call DAX directly) → the minOut=0 residual is officer-side multi-tx MEV. **Handoff load-bearing nuance:** `_authorizeUpgrade` is gated on `ADMIN_ROLE`, NOT `DEFAULT_ADMIN_ROLE` — must explicitly revoke/migrate `ADMIN_ROLE` to timelocked gov.

---

## ⚙️ Admin / governance powers — permanent at handoff
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| **Activate / set VARO** | `setVaro` | flips VEO from dormant→live; VARO becomes the sole register/registerVDAO gate | **#1 knob** — VARO must be the audited contract; both to timelocked gov |
| Fee rate | `setFeeBps` (≤2%) | sets the protocol skim | cap is hard (2%); to gov |
| Sinks/venues | `setVBO/setDAX/setUniRouter/setOndoGM/setVyUsdcV2Router` | arbitrary addr + **max approval**; a malicious router could pull **in-flight** funds of the current caller only (zero held between txs) | to timelocked gov; curate venues |
| Default V3 tier | `setDefaultUniFee` | fallback fee-leg tier | to gov |
| Pause | `setPaused` | halt all swaps | — |
| Rescue | `rescueToken(token,to,amount)` | arbitrary `to` — but bounded to dust (zero held between txs) | to gov |
| Upgrade | `_authorizeUpgrade` | replace all logic | codehash/timelock + role to gov |

→ See `findings/ValinityExchangeOfficer.md`. **CC-1 obligation discharged here**: VEO is not the sandwich vector; the residual pivots to **officer-side MEV-protected submission** + **StakingRouter** (the other public whitelist member). Both `DEFAULT_ADMIN_ROLE` and `ADMIN_ROLE` (today: `0x8310eA7E…4a09`) must go to timelocked governance.
