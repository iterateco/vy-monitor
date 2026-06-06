# ValinityAcquisitionOfficer (VAO **V2**) — Fund-Flow Circuit

Proxy `0x7a0E582479579e1423bc4f1DFD0750feA9282B01` → UUPS impl `0xc364f74e…` (V2, solcInputHash `cb6d5b6c`, 64/64 ABI selectors in live bytecode). Holds ~0 between cycles (pass-through). **Two PERMISSIONLESS entrypoints** — anyone can call them; amounts are computed **on-chain** (no caller params for routes/amounts).

> **Convention:** circuit shows ONLY non-admin paths. Admin functions (`setDax`, `setBuybackOfficer`, `setVryo`, `setVgo`, `setPaused`, fee/cooldown/slippage setters, `_authorizeUpgrade`, `rescueToken`) are in the box at the bottom + the permanence watchlist.

## Operational flow (non-admin, permissionless)

```
  Anyone (keeper) ──calls──> executeAcquireByLTV()  or  executeAcquireByMTP()
       │   (gas refunded + bonus by VGO, best-effort)
       │   gates: !execPaused · per-path cooldown · a REAL disparity must exist
       │   amount computed ON-CHAIN:
       │     LTV: totalVy = capH·(ltvFH−ltvFL)/(ltvFH+ltvFL)     [capH,ltvF from VCO]
       │     MTP: netVy solved on DAX constant-product to push price 2.1x→1.9x ltvF; gross up for fee
       ▼
  ┌────────────────────── _executeCycle (shared) ──────────────────────────┐
  │ snapshot preVyBal, preAssetBal                                          │
  │                                                                         │
  │ 1) vyt.pullTokens(address(this), totalVy)   ◄── VAO = PRIORITY_OFFICER  │  VY in (recipient hardcoded self)
  │      → bypasses VYT 350k CUSHION (can pull to zero)                      │
  │ 2) VY fee → feeRecipient (=BBO)             safeTransfer(bbo, fee)       │  1% (LTV) / 2% (MTP)
  │ 3) netVy VY → DAX:  dax.swapExactIn(poolId, VY, netVy, minOut, SELF)     │  swap, recipient hardcoded self
  │      minOut = constant-product expected (from DAX's OWN reserves) − 1%   │
  │ 4) assetReceived → VRT:  safeTransfer(address(vrt), assetReceived)       │  asset out (dest hardcoded VRT)
  │ 5) vco.increaseAssetCap(capRaiseAsset, totalVy)                          │  accounting only (no value)
  │                                                                         │
  │ 6) ✅ INVARIANT: postVyBal  == preVyBal   → VAO retains ZERO net VY      │  ← closes the VY leg by physics
  │    ✅ INVARIANT: postAssetBal<= preAssetBal → VAO retains ZERO asset     │  ← closes the asset leg by physics
  │ 7) vryo.execute()  (try/catch, AFTER invariants — can't corrupt them)   │
  └─────────────────────────────────────────────────────────────────────────┘
       │ fee VY ──────────────► BBO (Buyback Officer, admin-set sink)
       │ acquired asset ──────► VRT (reserve treasury, set once in init, NO setter)
       ▼
   DAX (Valinity AMM) — the ONLY swap venue. Routing hard-wired; recipient always SELF.
```

## Edge ledger — operational (non-admin)
| # | Edge (line) | Token | Destination | Bound | Closed? |
|---|---|---|---|---|---|
| 1 | `vyt.pullTokens` (465) | VY | **VAO self (hardcoded)** | on-chain formula; PRIORITY bypasses cushion | ✅ self |
| 2 | fee `safeTransfer(bbo,fee)` (468) | VY | feeRecipient (=BBO) | ≤10% (fee cap) | ✅ not caller-chosen; admin-set sink |
| 3 | `dax.swapExactIn(…, SELF)` (476) | VY→asset | **VAO self** | minOut = DAX-reserve constant-product − `swapSlippageBps`(≤10%) | ✅ recipient hardcoded; ⚠️ minOut is self-referential (see L1) |
| 4 | `safeTransfer(address(vrt), …)` (480) | asset | **VRT (hardcoded, no setter)** | entire balance | ✅ **physics** |
| 5 | `increaseAssetCap` (483) | — | VCO accounting | `+= totalVy` (gross) | ✅ no value |
| — | `rescueToken` (842) | any **non-VY** ERC20 | arbitrary | VY **blocked** (849) | ⚠️ ADMIN-only; VY cannot be rescued ✅ |

**Verdict:** ✅ **CLOSED (non-admin), closed by physics.** The two balance invariants (lines 488-489) force VAO to retain **zero** VY and **zero** asset every cycle; the swap recipient and the VRT deposit are **hardcoded** — no caller parameter selects any destination, and there is no arbitrary `.call`. VY can only go to {BBO fee, the DAX}; the acquired asset can only go to VRT. This is materially **stronger** than the (non-deployed) V1 I previously mis-audited.

## ⚠️ The one thing the circuit depends on (cross-contract)
Because the entrypoints are **permissionless** and the swap `minOut` is derived from the **DAX's own live reserves**, the protection against "sell VY too cheaply" relies on **the DAX swap being permissioned** — the DAX interface exposes `updateSwapWhitelist` / `NotWhitelisted`, i.e. it is *not* a public AMM. If only officers can trade against the DAX pools, the public cannot move the reserves to sandwich VAO's swap. **This assumption MUST be verified when the DAX is audited** (DAX impl is a separate 🔴 contract — interface only in this closure). If DAX swaps were ever opened to the public, VAO's permissionless paths would become sandwichable. → tracked as a cross-contract dependency.

---

## ⚙️ Admin / governance powers — EXCLUDED from the circuit (handoff inventory)
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| **Swap venue** | `setDax` (748) | revokes old DAX VY-approval, grants **new DAX MAX VY approval** | highest-value: a malicious DAX could mis-price the swap. Timelock+multisig; pin/allowlist the DAX |
| Fee sink | `setBuybackOfficer` (772) | redirects fee VY | confirm = BBO before lock |
| Rebalance hook | `setVryo` (778) / `setVgo` (760) | post-cycle heartbeat / keeper-reward sink | best-effort try/catch; low risk |
| Liveness | `setPaused` (784) | halts both entrypoints | censorship/liveness lever; who holds it |
| Tunables | fee (≤10%), cooldown (≤1 day), `setSwapSlippageBps` (1–1000 bps) | all **bounded** in code ✅ | confirm values; bounds already limit abuse |
| Rescue | `rescueToken` (842) | any **non-VY** token → any address; **VY reverts (849)** ✅ | residual dust only; VY protected by design |
| Upgrade | `_authorizeUpgrade` (854) | replace all logic incl. the invariants | codehash/allowlist/timelock + UPGRADER_ROLE |

→ See `findings/ValinityAcquisitionOfficer.md` (V2). Prior V1 report quarantined in `audit/_INVALID_redo/`.
