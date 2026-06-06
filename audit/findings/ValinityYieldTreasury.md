# Audit: ValinityYieldTreasury (VYT) — contract 2 of 18

- **Proxy:** `0xe58E29c947013B4CBCdb67f90d659c3894BE2974` → **UUPS impl** `0x35a86beb300f2a1ac08a339c50ee46b614cc447d`
- **Source:** `contracts/treasury/ValinityYieldTreasury.sol` (165 lines) · solc 0.8.27 · UUPS + AccessControl + ReentrancyGuardTransient
- **Audited:** 6 dimension finders → 28 findings → 28 adversarial refutations → synthesis + live-state. (35 agents.)
- **Result:** NO permissionless drain, NO accounting/reentrancy/over-mint bug. 100% of risk = privileged-role / governance-handoff. **Safe to proceed: YES-WITH-CONDITIONS.**

## Gate 1 — Source == Live ✅
- Step A: workspace `.sol` sha256 == artifact embedded `solcInputs` source.
- Bytecode: artifact `deployedBytecode` vs live runtime = identical **except 2×20 bytes at offsets 1667 & 1887**, both = the live impl address `0x35a86beb…` → the **UUPS `__self` immutable**. Nothing else differs.
- → The workspace source IS the live VYT logic. (Recompile gold-check deferred: local solc-js is 0.8.26 ≠ 0.8.27; byte-diff is conclusive.)

## What it is (functions)
Minimal UUPS treasury holding VY; the **permanent sole minter** of VY (`VY.vyt` locked to this proxy, irreversible). State-changing externals — only four:
| Function | Access | Effect |
|---|---|---|
| `initialize` | once (`_disableInitializers` in ctor) | sets vyToken, grants admin roles, OFFICER/PRIORITY role-admin = ADMIN_ROLE |
| `pullTokens(recipient, amount)` | OFFICER or PRIORITY_OFFICER | auto-mints deficit toward 7M TARGET via `VY.mintAvailable`; transfers `amount` to recipient |
| `migrateTo(newTreasury)` | ADMIN | transfers **entire** VY balance to newTreasury |
| `_authorizeUpgrade` (empty body) | ADMIN | UUPS upgrade authority |
Views: `getBalance`, `getAvailableForYield`. `nonReentrant` (transient) on both mutating paths.

## Gate 0 — Atomic fund flow / CLOSED-CIRCUIT
VY leaves VYT via **exactly 3 privileged paths**; **no permissionless drain**. Every destination is full address space (only `address(0)` rejected — no allowlist/isContract/self check).

| # | Path | Role | Destination | Amount bound |
|---|---|---|---|---|
| 1 | `migrateTo` | **ADMIN** | arbitrary | **100% of balance**, 1 tx (~7.07M live), no cap/timelock |
| 2 | `pullTokens` | **PRIORITY_OFFICER** | arbitrary | full balance — cushion block is `!isPriority`, so priority **drains below the 350k CUSHION to zero** (intended, NatSpec line 89) |
| 3 | `pullTokens` | OFFICER | arbitrary | `balance − CUSHION`; reverts if `balance ≤ CUSHION` (cushion **soundly enforced**) |
| 4 | auto-refill mint | internal to pullTokens | VYT itself | ≤ VY caps (0.07%/tx, 0.30%/epoch, 70M) |

**Amplification (pullTokens only):** sub-target pulls re-mint the deficit, re-supplying the drainable pool — but hard-bounded by VY's caps; `mintAvailable` returns 0 once a cap hits, self-throttling to ~0.30%/day, terminating at 70M. `migrateTo` does **not** auto-refill (one-shot balance snapshot). **Reentrancy:** blocked by transient `nonReentrant`; VY has no receiver hook, fee-side transfers only target trusted feeRecipient/capOfficer — no reentrant entry via `recipient`.

→ **Closed circuit relative to roles: YES.** Principal can reach an arbitrary address, but **only via a held role** (ADMIN or officer). No unprivileged path exists. The valve is privilege — and after handoff that privilege is governance.

## Findings (8 confirmed; 0 exploitable code bugs — all centralization/handoff/hygiene)
| ID | Sev | Finding |
|---|---|---|
| VYT-01 | **High** | `migrateTo` = 100%-balance drain to arbitrary ADMIN-chosen address; no cap/timelock/allowlist. |
| VYT-02 | **High** | `_authorizeUpgrade` empty/ADMIN-only — because VYT is the **permanently-locked sole VY minter**, any upgrade **inherits unburnable mint authority** (mint to attacker up to VY caps; strip cushion/officer gating). **Strictly dominates migrateTo — the highest-value capability in the token system.** |
| VYT-03 | Medium | PRIORITY_OFFICER bypasses cushion → full-balance arbitrary-destination drain on one key (intended, but powerful). |
| VYT-04 | Medium | One key holds DEFAULT_ADMIN + ADMIN; plain AccessControl → no two-step/pending-admin; mis-sequenced handoff is unrecoverable. |
| VYT-05 | Low | Auto-refill is a mint-on-demand spigot (intended; bounded by VY caps). |
| VYT-06 | Low | Non-upgradeable OZ base variants mixed into a UUPS proxy; `initialize` omits parent `__init` (benign in OZ v5; upgrade-safety hygiene). |
| VYT-07 | Low | `vyToken.transfer` return unchecked; events over-report if VYT ever de-whitelisted (use SafeERC20). |
| VYT-08 | Low | No pause/circuit-breaker on the sole-minter treasury (defense-in-depth). |

**Refuted (considered & dismissed):** officer-role self-escalation (dominated by powers ADMIN already has); reinitialization (initializer + `_disableInitializers`); deficit-mint over-transfer (transfer reverts if amount > true balance); reentrancy via recipient; cushion bypass via fee (fee deducts *from* amount → sender always debited exactly `amount`, cushion intact); counter-overflow (those counters don't exist in the live source).

## Gate 3 — Live state
- Proxy → impl `0x35a86beb…` (manifest-tracked); balance **~7,073,932 VY** (≈ TARGET).
- VYT **is fee-whitelisted** on VY → intra-protocol transfers fee-free ✅.
- DEFAULT_ADMIN + ADMIN = `0x8310eA7E…4a09` (claimed KMS multisig). **← the dispositive handoff variable.**

## Governance-handoff verdict: BOUND BEFORE FASE-4
The contract delegates ALL delay/quorum off-chain (no in-contract timelock/two-step/allowlist), so handoff safety rests **entirely** on who holds ADMIN_ROLE/DEFAULT_ADMIN_ROLE.
- **Dispositive — verify on-chain at handoff, not just in the plan doc:** both roles must resolve to a **TimelockController (≥48h) fronted by the Governor** — never the Governor directly, never an EOA.
- Hardening before Fase-4 (each = fix or written risk-accept): allowlist/two-step on `migrateTo`; codehash-pin/allowlist/timelock on upgrades + dedicated `UPGRADER_ROLE`; consider AccessControlDefaultAdminRules; hold PRIORITY_OFFICER on a multisig. The reserved `__gap[46]` leaves room for an in-contract timelock/lock var via a final hardening upgrade while the trusted admin still controls it.

## Check-off
- [x] Source == live (byte-equal modulo UUPS immutable)
- [x] Deep audit, 28/28 adversarially verified — no exploitable code bug
- [x] Fund-flow mapped — closed to the privileged-role set, no permissionless drain
- [x] Live-state read (whitelist + admin confirmed)
- [ ] **User agrees → check off** (2 Highs + 2 Mediums logged as handoff conditions, not code blockers)
