# ValinityReserveTreasury (VRT) — Fund-Flow Circuit

Proxy `0x06087789B7122fA92E7F9868B10A286Dd4e4C832` → UUPS impl `0x5a2ce62e…`. The protocol's **reserve vault**: holds WBTC/WETH/PAXG + VY collateral, manages Uniswap-V3 positions. **NO permissionless entrypoint** — every value-moving function is role-gated (same trust shape as VYT).

> **Convention:** circuit shows ONLY non-admin paths. Admin (`migrateTo`, `_authorizeUpgrade`, `initializeV2`) in the box at the bottom + the permanence watchlist.

## Operational flow (role-gated; no permissionless entry)

```
        VAO (acquired BTC/ETH/PAXG) ──┐         VLO repays asset ──┐
                                      ▼                            ▼
        ╔══════════════════════════════════════════════════════════════════════╗
        ║   VRT  — reserve vault                                                 ║
        ║   holds: ~0.018 WBTC · ~0.74 WETH · ~0.29 PAXG · ~10.47M VY (collat)   ║
        ║   2 active Uniswap-V3 positions (NPM 0xc36442b4)                       ║
        ╚══════════════════════════════════════════════════════════════════════╝
            │ processLoan          │ withdrawForBuyback   │ deployForYield      │ fundLiquidityManager
            │ [OFFICER=VLO]        │ [BUYBACK=VBBO]       │ [VRYO]              │ [VLM]
            │ asset → borrower     │ assets → recipient   │ assets → recipient  │ pinned pair tokens → VLM
            ▼ (arbitrary addr,     ▼ (arbitrary addr,     ▼ (arbitrary addr,    ▼ (to msg.sender=VLM,
            │  role-gated)         │  role-gated)         │  role-gated)        │  pinned tokens only)
            │                      │                      │                     │
            │ applyInterest VY → recipient(VYT) [OFFICER]                       │
            │ releaseLoan   VY → msg.sender(VLO) [OFFICER]                      │
            ▼                      ▼                      ▼                     ▼
       VLO borrowers          VBBO buyback           VRYO yield            VLM V3 mint
       (audited next)         (audited later)        (audited later)       (audited later)

   NO permissionless path. Reserves leave ONLY via OFFICER/BUYBACK/VRYO/VLM — the
   role-holders are the next contracts in the flow; each is audited to confirm it
   sends only to protocol-rightful destinations. Closed RELATIVE TO the role set.
   Reentrancy: nonReentrant(transient) on all mutators; reserve assets are a trusted
   non-rebasing set; VY has no transfer hook.
```

## Edge ledger — operational (role-gated, non-admin)
| # | Edge | Token | Destination | Role | Closed? |
|---|---|---|---|---|---|
| 1 | `processLoan` | asset | `borrower` (arbitrary) | OFFICER=VLO `0x8fd8d5eb…` | ✅ rel. to VLO |
| 2 | `releaseLoan` | VY | `msg.sender` (VLO) | OFFICER | ✅ caller-role |
| 3 | `applyInterest` | VY | `recipient` (→VYT) | OFFICER | ✅ rel. to VLO |
| 4 | `depositCollateral` | VY (in) | — (inbound) | OFFICER | ✅ inflow |
| 5 | `withdrawForBuyback` | assets | `recipient` (arbitrary) | BUYBACK=VBBO `0x4b97d45d…` (+`0x3d9d78cd…`?) | ✅ rel. to VBBO |
| 6 | `deployForYield` | assets | `recipient` (arbitrary) | VRYO `0xa95749f5…` | ✅ rel. to VRYO |
| 7 | `fundLiquidityManager` | **pinned** pair tokens | `msg.sender` (VLM) | VLM `0x920abb09…` | ✅ caller-role, pinned only |
| 8 | `decreasePositionLiquidity` | V3 LP proceeds (both pool tokens, incl. unmanaged counterparty) | `msg.sender` (VRYO), **fixed** | VRYO `0xa95749f5…` | ✅ caller-role; collect recipient hardcoded, cannot redirect |
| — | `migrateTo` | all tokens+VY | `newTreasury` (arbitrary) | **ADMIN** | ⚠️ admin path (handoff) |

**Verdict:** ✅ **CLOSED relative to roles. NO permissionless drain.** Reserves can only exit through the officer role-set; closure of *where* they go is delegated to those officers (VLO/VBBO/VRYO/VLM), each audited as its own node. Same model as VYT. The V3 machinery is anti-spoofed (factory-pool validation) and migration is blocked while NFTs are outstanding.

---

## ⚙️ Admin / governance powers — EXCLUDED from the circuit (handoff inventory)
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| Drain | `migrateTo(newTreasury, tokens[])` | ADMIN sends all listed tokens + all VY to newTreasury; blocked while V3 NFTs active ✅ | bound/allowlist newTreasury; timelock+multisig |
| Upgrade | `_authorizeUpgrade` (UUPS) | replace all logic | codehash/allowlist/timelock + UPGRADER_ROLE |
| Wiring | `initializeV2(npm, factory)` | sets V3 NPM/factory (already done) | confirm not re-callable (reinitializer(2)) |
| Role admin | OFFICER/BUYBACK (init), VLM/VRYO (initV2) — admin = ADMIN_ROLE | grants the above roles | confirm holders = intended officers before lock |

→ See `findings/ValinityReserveTreasury.md`. **Source==live proven by metadata-hash equality** (`a1875f40…`); full 816-line source, `decreasePositionLiquidity` IS live and audited (edge #8). The earlier "reconstruction" note was retracted (a leading-zero-selector tooling bug) — see `findings/VRT-source-reconstruction.md`.
