# Audit: ValinityToken (VY) — contract 1 of 18 ✅

- **Address:** `0x597b29520098d6aaca3B2e0D1a380315c9240454` (ETH mainnet, non-proxy, **immutable**)
- **Source:** `contracts/token/ValinityToken.sol` · solc 0.8.27 · OZ ERC20 + AccessControl + hand-rolled EIP-712
- **Audited:** 7 dimension finders → 40 findings → 40 adversarial refutations → synthesis, plus independent live-state read.
- **Result:** No Critical/High/Medium survived. **Closed circuit: YES (one bounded fee valve).** Safe-to-proceed: **YES-WITH-CONDITIONS.**

---

## What the contract is (functions)
A fixed-cap fee-bearing ERC-20. No proxy, no upgrade, no burn, no selfdestruct/delegatecall.

| Function | Access | What it does |
|---|---|---|
| `constructor` | deploy | mints `INITIAL_SUPPLY` 17M to admin; sets fee=1%; grants admin roles; builds DOMAIN_SEPARATOR |
| `mintAvailable(to, requested)` | **VYT only** (`OnlyVYT`) | the only post-deploy mint; returns `min(requested, remaining, 0.07%/tx, 0.30%/epoch)`; hard-capped at 70M |
| `transfer` / `transferFrom` | any holder | move own VY; routes through `_transferWithFee` |
| `_transferWithFee` / `_collectFee` | internal | takes `fee = amount×bps/10000`, sends net to recipient + fee to `transferFeeRecipient`; batches fee notice to CapOfficer every N transfers |
| `permit` | anyone w/ sig | custom EIP-712 (`VYPermit`/`amount`, not EIP-2612) approval |
| `setVYT` | ADMIN, **one-time lock** | wires the sole minter, then `vytLocked` forever |
| `setTransferFeeBps` | ADMIN | fee, capped at `MAX_FEE_BPS`=10% |
| `setTransferFeeRecipient` / `setWhitelisted` / `setCapOfficer` / `setTransfersPerProcess` | ADMIN | fee destination / fee-exempt list / accounting hook / batch size |

## Atomic fund flow (the physics)
See diagram: [diagrams/ValinityToken-fund-flow.md](../diagrams/ValinityToken-fund-flow.md). Four value edges:
1. constructor mint → admin (17M, once) ✅
2. `mintAvailable` → `to` chosen by VYT, **VYT-only, ≤ rate caps, ≤ 70M** ✅ bounded
3. `transfer/transferFrom` → anyone (holder's own funds) ✅
4. `_collectFee` → `transferFeeRecipient` (**admin-settable**, ≤10% of transfer, **never principal**) ⚠️ bounded valve

→ **No path moves principal to an arbitrary address. VY cannot be drained by physics.** Mint is VYT-only and cap-bounded; no burn, no selfdestruct, no delegatecall.

## Gate 1 — Closed-circuit match ✅
sha256(workspace) == sha256(as-deployed) == live runtime bytecode (byte-EXACT). Import closure empty (only version-pinned OZ). **The file on disk is the code on mainnet.**

## Gate 2 — Findings (all Low/Informational; every drain/unbounded-mint hypothesis REFUTED)
| ID | Sev | Finding |
|---|---|---|
| VY-01 | Low | EIP-712 domain name "ValinityToken" ≠ ERC-20 name() "VALINITY" → standard tooling derives wrong separator; permit works only with the hardcoded name. |
| VY-02 | Low | DOMAIN_SEPARATOR cached at deploy, no chainId-change recompute → cross-fork permit replay (nonce-bounded, fork-only). |
| VY-03 | Low | `transferFeeRecipient` arbitrary + fee up to 10% = admin fee-skim lever (bounded, principal-safe). **The one circuit valve.** |
| VY-04 | Info | No burn path; totalSupply monotonic. Docs claiming buyback "burns" VY are wrong at token level (buyback reduces *circulating*, not *total*). |
| VY-05 | Info | `mintAvailable` epoch-boundary burst ≈2× the 0.30% epoch cap in seconds; VYT-only, cap-bounded, self-decaying. |
| VY-06 | Info | Single mutable `vyt` minter, one-time-locked; no MINTER_ROLE. |
| VY-07 | Info | Plain AccessControl: one-step, renounceable, no timelock on admin (key-mgmt foot-gun, not externally exploitable). |

**Refuted (considered & dismissed):** capOfficer-hook reentrancy, fee-on-transfer "allowance mismatch", MAX_SUPPLY overshoot/uint192 truncation, stale-snapshot epoch cap, fee-counter wrap, ecrecover malleability. All shown non-exploitable against the source.

## Gate 3 — Live on-chain state (confirms the safe config is actually set)
Read at mainnet (deterministic, stable):
- `totalSupply` 17,935,219 / `MAX_SUPPLY` 70,000,000 ✅
- `vyt` = `0xe58E…2974` = **the real VYT**, `vytLocked` = **true** ✅ (VY-06 residual closed)
- `transferFeeBps` = **100 (1%)** ✅ ; `transferFeeRecipient` = `0x4B97…2F6` (= BuybackOfficer)
- admin `0x8310…4a09` holds DEFAULT_ADMIN_ROLE ✅

### ⚠️ New finding from live state — VY-08 (Low/Med, config not code)
- **`capOfficer` = address(0)** → `_processAccumulatedFees` early-returns; **fee→cap accounting is currently inert.** Fees still move to the recipient, but the CapOfficer is never notified, so the documented "transfer fee adjusts caps" mechanism is **not operating** on mainnet. Either intended (capOfficer retired) or a missing wire-up — **confirm with team.**
- **`transfersPerProcess` = 255** (not the documented 7) → fee batching to CapOfficer would only fire every 255 transfers even if capOfficer were set.
- **VLM (`0x920AbB09…`) and ReserveYieldOfficer (`0xA957…`) are NOT fee-whitelisted** → intra-protocol VY transfers touching VLM/RYO are taxed 1%. Every other protocol contract is whitelisted. Likely a **missing whitelist entry** (small value leak on protocol-internal moves, and it skews accounting). Confirm intended.

## ⚠️ Fee destination = VBBO, becomes permanent at handoff (document for dev)
The live `transferFeeRecipient` = `0x4B97D45d276084c1C5BDBd0aa29B417cE02bE2F6` = **ValinityBuybackOfficer (VBBO)**. So the 1% transfer fee feeds the buyback engine (this is the "fees → buyback → VY buy-pressure" loop). **After the irreversible admin→governance handoff (Fase 4), this address can only be changed via a passed governance proposal** — it is effectively **set forever** at its handoff value. **Action: confirm `transferFeeRecipient == VBBO` is the intended final value before locking governance.** Edge 4 in the fund-flow diagram is updated to reflect this.

## Decisions before governance handoff (must fix or formally accept)
1. **Fee valve (VY-03):** the fee already routes to VBBO (buyback). Accept this as the permanent value (it can still be re-pointed only via governance after Fase 4), **and confirm VBBO is correct before locking**.
2. **VY-08 config:** decide whether `capOfficer` should be set (fee→cap accounting) and whether `transfersPerProcess=255` is intended; whitelist VLM + RYO if intra-protocol fee-free is intended.
3. **Docs (VY-04):** correct "burn"/"deflationary" wording.
4. **Permit (VY-01/02):** publish exact EIP-712 domain for integrators.

Since VY is **immutable**, governance can never change mint logic, the 70M cap, or the 10% fee ceiling — so its inherited powers are just the 5 bounded setters. Nothing here blocks the handoff once items 1–2 are decided.

## Check-off
- [x] Closed-circuit match (workspace == as-deployed == live, byte-EXACT)
- [x] Deep audit, adversarially verified — no surviving Critical/High/Medium
- [x] Fund-flow proven closed (one bounded fee valve, no principal exit)
- [x] Live config read; surfaced VY-08
- [ ] **User agrees → check off in progress.md**
