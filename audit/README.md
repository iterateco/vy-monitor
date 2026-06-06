# Valinity Ecosystem Security Audit — Master Ledger

> Single source of truth for the full security review of the deployed Valinity protocol.
> Every focused audit chat reads from and writes back to this directory.

**Status:** Phase 0a (Reconciliation) COMPLETE — Step A (local source vs as-deployed) + Step B (on-chain live-impl certification via default-profile Alchemy, block ~25,217,820) done. See `reconciliation.md`, `live-state-report.md`, `findings/system-reconciliation.md`, `findings/system-live-state.md`. Next: Phase 1 deep audits, starting with ValinityToken (byte-EXACT). Open Highs: VAL-001a (7 untracked live impls incl. VRT/BuybackOfficer), VAL-001b (CapOfficer/DAX/etc. artifacts stale; BuybackOfficer+MEVBotV2 no local source).
**Scope (this pass):** Live ETH-mainnet contracts only. Perps/HyperEVM + not-yet-deployed contracts are a later pass.
**Audit basis:** What is actually on-chain — Etherscan-verified source + deployed bytecode + live state via Alchemy RPC. Local repo source is used as cross-reference and to detect drift.
**Capital gate:** No new capital is added and no new contracts are deployed until every Critical and High finding is resolved or formally risk-accepted in writing (see `findings/`).

---

## Why this structure (one chat vs. many)

We do **not** run the whole audit in one chat, and we do **not** do pure isolated per-contract audits. We use a **hub-and-spoke** model:

- **The hub** is this `audit/` directory — it persists across every chat and holds the registry, roles matrix, dependency graph, threat model, and findings. Context windows reset; this does not.
- **The spokes** are focused sessions, one per contract or tightly-coupled cluster. Each spoke loads only what it needs from the hub, goes deep, and writes findings back.
- **System passes** are separate focused sessions per cross-cutting theme (access control, oracle/price, economic invariants, upgradeability, governance, liquidity, integration) that read *all* spoke findings.

Rationale: a single mega-chat dilutes attention and overflows context (the worst place for a missed reentrancy path). Pure per-contract isolation misses the bugs that *only* exist between contracts — and in a treasury/officer mesh like this, that is where the money is. The hub gives us both depth and the whole-system view.

---

## Phase map

| Phase | Goal | Output | Status |
|------|------|--------|--------|
| 0 | Inventory & scoping | `registry.md`, `roles-matrix.md`, `dependency-graph.md`, `threat-model.md` | running |
| 1 | Per-contract deep audits (spokes) | `findings/<contract>.md` | pending |
| 2 | System-level cross-cutting passes | `findings/system-<theme>.md` | pending |
| 3 | Live-state verification via RPC (roles, owners, impls, balances) | `live-state-report.md` | pending (needs RPC key) |
| 4 | Synthesis, severity triage, remediation, re-test | `FINAL-REPORT.md` | pending |

## Index

- `inputs-needed.md` — what I still need from you to proceed
- `methodology.md` — how each contract and the whole system is audited; severity rubric; read-only safety rules
- `threat-model.md` — risk taxonomy and per-class checklist
- `registry.md` — every in-scope contract: address, impl, proxy type, value held, status
- `roles-matrix.md` — role → holder → capability → blast radius
- `dependency-graph.md` — who calls/trusts/funds whom (generated in Phase 0)
- `findings/` — one file per contract/theme; `_TEMPLATE.md` is the finding format
