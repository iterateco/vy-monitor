# ValinityToken (VY) — Fund-Flow Circuit (Gate 0: closed-circuit by physics)

**What "value" is here:** VY token balances. Every path below is *every* place in the bytecode where VY is created or moved. If all destinations are bounded/internal/rightful-holder, the circuit is closed — money cannot physically exit to an arbitrary attacker address regardless of who calls.

Address: `0x597b29520098d6aaca3B2e0D1a380315c9240454` · immutable, non-proxy · source = live (byte-EXACT).

```
                         ┌───────────────────────────────────────────────┐
                         │            VY SUPPLY (mint source)             │
                         │     _mint()  — creates new VY balance          │
                         │     HARD CAP: MAX_SUPPLY = 70,000,000 VY       │
                         └───────────────────────────────────────────────┘
                            │ (1) constructor                │ (2) mintAvailable(to,amt)
                            │     one-time, 17,000,000 VY     │     caller MUST == vyt  (else revert OnlyVYT)
                            │     to = adminAddress           │     amount = min(req, remaining,
                            ▼                                 │              0.07%/tx, 0.30%/epoch)
                 ┌──────────────────┐                        ▼
                 │   Admin address  │              ┌────────────────────────┐
                 │ 0x8310eA7E…4a09  │              │  VYT (Yield Treasury)  │  ← only minter post-deploy
                 │ (initial 17M)    │              │  0xe58E29c9…2974       │     'to' is chosen by VYT
                 └────────┬─────────┘              └───────────┬────────────┘
                          │                                    │
                          │            both are just HOLDERS   │
                          ▼                                    ▼
        ╔══════════════════════════════════════════════════════════════════════════╗
        ║                         ANY VY HOLDER  (the pool)                          ║
        ║   users · VYT · VRT · officers · DAX · LP pools · any EOA/contract         ║
        ╚══════════════════════════════════════════════════════════════════════════╝
            │                                              │
            │ (3) transfer / transferFrom                  │ (4) 1% fee on (3), if NOT whitelisted
            │     holder moves THEIR OWN VY                │     _collectFee → transferFeeRecipient
            │     net = amount − fee                       │     fee = amount × transferFeeBps/10000
            ▼                                              ▼
   ┌──────────────────────┐                  ┌─────────────────────────────────────┐
   │  recipient (anyone)  │                  │  transferFeeRecipient = VBBO        │
   │  = the holder's own  │                  │  0x4B97D45d…2F6 (Buyback Officer)   │
   │  money being sent    │                  │  ⚠ ADMIN-SETTABLE; LIVE = VBBO       │
   │  ✅ rightful holder   │                  │  → 1% fee funds the buyback engine  │
   │                      │                  │  if == address(0) ⇒ fee = 0         │
   └──────────────────────┘                  └─────────────────────────────────────┘

   ⚠ GOVERNANCE NOTE: after the irreversible admin→governance handoff (Fase 4),
     transferFeeRecipient can only be changed by a passed governance proposal —
     effectively PERMANENT at its handoff value (currently VBBO).
     ⇒ Confirm transferFeeRecipient == VBBO is correct BEFORE locking governance.

   NO BURN PATH:  no public burn, no ERC20Burnable, _burn unreachable (OZ _transfer reverts to addr(0)).
                  ⇒ supply is monotonically NON-DECREASING up to the 70M cap.
```

## Edge ledger (the physics)

| # | Path | Destination | Amount bound | Trigger | Closed? |
|---|------|-------------|--------------|---------|:------:|
| 1 | `constructor → _mint` | Admin (fixed at deploy) | 17,000,000 VY, one-time | deploy only | ✅ |
| 2 | `mintAvailable → _mint` | `to` (chosen by VYT) | ≤ rate caps (0.07%/tx, 0.30%/epoch) & ≤ 70M | **VYT only** (`OnlyVYT`) | ✅ bounded |
| 3 | `transfer / transferFrom → _transfer` | any recipient | = holder's own balance/allowance | any holder | ✅ holder's funds |
| 4 | `_collectFee → _transfer` | `transferFeeRecipient` = **VBBO** `0x4B97…2F6` | 1% (max 10%) of transfer | any non-whitelisted transfer | ⚠️ **settable dest; permanent at handoff** |

## Verdict for VY (Gate 0)

**Closed circuit: YES, with one bounded valve.**
- Minting can only be triggered by VYT and is hard-capped (70M) and rate-limited — no unbounded mint, no permissionless mint.
- Ordinary transfers move only the holder's own funds — not a leak.
- **The single exit valve is edge 4: `transferFeeRecipient` is an admin-settable arbitrary address.** It does *not* let anyone touch *other* holders' balances — it only skims the **1% (≤10%) fee** off transfers, and only while a recipient is set. So the leak is **bounded to fee flow**, not principal.

### Why this matters for the governance handoff
After handoff, *governance* inherits the power to point `transferFeeRecipient` anywhere. That's the only VY value-routing lever it gets (VY is immutable, so governance can never change mint logic, the cap, or the fee ceiling). Decision to make explicit before Fase 4:
- **Accept**: fee routing to a governance-controlled address is intended (fees fund the protocol). Bounded at ≤10%, principal untouchable. → safe to delegate.
- **Tighten** (optional): hard-pin `transferFeeRecipient` to a fixed protocol address, or cap it to a known allowlist, removing even the fee valve.

No path moves principal to an arbitrary destination. **VY cannot be drained by physics.**
```
```
