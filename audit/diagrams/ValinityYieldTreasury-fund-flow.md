# ValinityYieldTreasury (VYT) — Fund-Flow Circuit

Proxy `0xe58E29c947013B4CBCdb67f90d659c3894BE2974` → UUPS impl `0x35a86beb…`. Holds VY; **permanent sole minter** of VY. Value = VY balances. Live balance ≈ 7,073,932 VY.

> **Convention:** the circuit below shows ONLY non-admin paths. Admin/governance functions are *excluded by design* — the audit assumes they will be constrained/removed at handoff, so the closed-circuit proof must hold **without** them. Admin powers are listed in the separate box at the bottom and tracked in the permanence watchlist.

## Closed circuit (non-admin operational flow)

```
                  ┌──────────────────────────────────────────┐
                  │   VY token (mint source, cap 70M)         │
                  │   VY.mintAvailable — caller MUST == VYT    │  ← VYT is the ONLY minter
                  └───────────────────┬──────────────────────┘   (VY.vyt locked to this proxy, permanent)
                                      │ auto-refill: mint deficit toward TARGET 7,000,000
                                      │ bounded by VY caps (0.07%/tx, 0.30%/epoch, 70M)
                                      ▼
        ╔══════════════════════════════════════════════════════════════════╗
        ║                    VYT  (holds ~7.07M VY)                          ║
        ╚══════════════════════════════════════════════════════════════════╝
                       │ pullTokens(recipient, amount)   nonReentrant
                       │ caller MUST hold OFFICER_ROLE or PRIORITY_OFFICER_ROLE
                       ▼
        ┌──────────────────────────────────────────────────────────────────┐
        │  Officer-specified recipient                                       │
        │  • OFFICER_ROLE: amount ≤ balance − 350k CUSHION  (cushion kept)   │
        │  • PRIORITY_OFFICER_ROLE: up to full balance (cushion bypassed)    │
        │  The role-holders are the next contracts in the flow (VAO, …):     │
        │  each is audited to confirm it pulls only to itself/protocol.      │
        └──────────────────────────────────────────────────────────────────┘
                       │ (flow continues into each officer's own circuit)
                       ▼
                 VAO / MEVBot / YieldOfficer / … (audited next, one by one)

   NO permissionless path. The ONLY way VY leaves VYT operationally is an officer
   calling pullTokens — so the circuit is closed IFF every role-holder keeps funds
   internal. That is exactly what the per-officer audits verify (follow-the-flow).
   Reentrancy: nonReentrant(transient); VY has no receiver hook → safe.
```

## Edge ledger — operational (non-admin)
| # | Path | Role | Destination | Amount | Closed? |
|---|---|---|---|---|---|
| 1 | auto-refill mint | internal to pullTokens | VYT itself | ≤ VY caps (0.07%/tx, 0.30%/epoch, 70M) | ✅ bounded by VY |
| 2 | `pullTokens` (standard) | OFFICER | officer-named recipient | balance − 350k cushion | ✅ cushion-bounded; closed iff officer is honest (audited) |
| 3 | `pullTokens` (priority) | PRIORITY_OFFICER | officer-named recipient | up to full balance | ⚠️ cushion bypassed — closed iff priority officer is honest (audit VAO/MEVBot) |

**Verdict (operational circuit):** CLOSED — no unprivileged drain; VY can only leave to an officer-chosen recipient, and the officers are the next audited nodes. Standard officers are cushion-bounded; priority officers are not, so the priority role-holders (VAO, MEVBot) get the most scrutiny.

---

## ⚙️ Admin / governance powers — EXCLUDED from the circuit (handled at handoff)
These are NOT part of the operational fund flow. They exist today under ADMIN_ROLE and are the subject of the governance-handoff analysis — to be constrained/removed/timelocked before Fase 4, not relied on for the closed-circuit guarantee.

| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| Drain | `migrateTo(newTreasury)` | transfers 100% of balance to an admin-named address | bound (allowlist/two-step/cap) or risk-accept; admin must be Timelock+multisig |
| Upgrade | `_authorizeUpgrade` (UUPS) | replaces all logic → **inherits the permanent sole-VY-minter** | codehash/allowlist/timelock + dedicated UPGRADER_ROLE; **highest-value power in the token system** |

→ See `findings/ValinityYieldTreasury.md` (VYT-01/02) and the permanence watchlist in `diagrams/INDEX.md`. The operational circuit above is closed **regardless** of these — which is the point: if admin is removed/constrained, no fund-escape path remains except honest-officer pulls.
