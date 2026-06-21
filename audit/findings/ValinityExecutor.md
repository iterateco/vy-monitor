# ValinityExecutor — Findings · **the governance timelock ("executioner")**

**Address:** `0x710AE2116B3EDd566D3594bd8191a4e6EFcE3449` (NON-PROXY / NON-UPGRADEABLE, 2,104 B)
**Source==live:** PROVEN (gold standard) — live runtime metadata-IPFS `1220745fbf…` == hardhat artifact metadata == build-info `3221a1b0` compile of workspace `contracts/governance/ValinityExecutor.sol` (233 ln, src keccak == workspace). solc 0.8.27 / runs=100 / cancun.
**Audit workflow:** `wapagthnp` (joint Governor+Executor, 6 dimensions, 60 agents, adversarial 2-skeptic default-refute) — **27 raw → 21 survived / 6 refuted; 0 fund-theft, 0 vote-forgery, 0 replay/collision.**

> **Role:** THE HANDOFF DESTINATION (executor side). Designed to become DEFAULT_ADMIN/ADMIN/owner of EVERY governed Valinity contract. **Handoff NOT yet done** — currently holds admin on none of VCO/VYT/VRT (KMS still holds all), so all findings below can still be addressed by **redeploy before the irreversible role transfer.**

---

## Verdict

✅ **Timelock CORE mechanics PROVEN sound — no permissionless break, no replay, no double-execution, no operationId collision.** The entire residual is **deliberate design trade-offs** that the protocol must consciously accept for an irreversible, credibly-neutral handoff.

**Proven correct (workflow EXEC-1/2/3/4 refuted as exploits, both skeptics):**
- `schedule()` is **Governor-only** — `isProposer` is set once in the constructor (the Governor) with **no setter**; `onlyProposer` gates it; `readyAt` is written only inside `schedule`. No unprivileged actor can inject a scheduled op (L76-79, L93-97, L111-131).
- `execute()` is permissionless **by design** (EXECUTOR_ROLE = anyone) but can only run a batch that was already scheduled by the Governor and whose 7-day delay elapsed (L150-156). `executed[operationId]=true` is set **before** the call loop (CEI) → no replay / reentrant double-execution (L158-163).
- `hashOperation = keccak256(abi.encode(targets,values,calldatas,salt))` uses `abi.encode` (length-prefixed) → **no collision** between distinct batches; `salt = bytes32(proposalId)` is unique per proposal (L190-197).
- Batch is **atomic** (any failed call reverts the whole `execute`, L166-173).

---

## Findings (reconciled with `wapagthnp`)

### EXEC-1 — No canceller / guardian: a passed-but-malicious or buggy batch is unstoppable once scheduled · **High (design)** — not permissionless
The Executor has **no cancel path and no canceller role**. Once the Governor schedules a batch, it **cannot be stopped on-chain** — it can only be waited out (7 days) and then anyone executes it. For the irreversible handoff this means: if a malicious proposal passes both chambers (or a *buggy* well-intentioned one), the only defense is the 7-day window for off-chain reaction (e.g. users exit). There is no on-chain emergency stop. *This is a deliberate credible-neutrality choice; surface it explicitly. **Mitigation options (pre-handoff):** add a narrowly-scoped guardian `cancel(operationId)` (e.g. a multisig that can only cancel, never propose/execute), and/or keep an independent pause guardian on the highest-value governed contracts (VRT/VYT/VCO) separate from admin.*

### EXEC-2 — Immutable proposer: a buggy Governor can never be replaced · **Medium (design/rigidity)**
`isProposer` is set only in the constructor and has no setter. If the Governor (`ValinityGovernanceOfficer`) is later found buggy, governance **cannot be migrated** without deploying a new Executor and re-handing-off every admin role — which itself would require either a working proposal through the (buggy) Governor or the pre-handoff KMS. *Consider whether the Executor should allow the *current proposer* to schedule a proposer rotation (still gated by a full governance vote), or accept the rigidity as intentional ossification.*

### EXEC-3 — The 7-day MIN_DELAY is the ONLY reaction window and the ONLY emergency lever · **Medium (operational)**
`MIN_DELAY` is hardcoded immutable (7 days). Combined with the Governor's ~21-day pipeline, **fixing any bug in a governed contract takes ~28 days minimum**, with no fast lane. There is no expedited path for emergencies. *Accept consciously, or pair with per-contract pause guardians for time-critical defense.*

### EXEC-4 — Permissionless direct `execute()` desyncs the Governor's `p.executed` flag · **Low (cosmetic)** — not permissionless-harmful
After the Governor queues a proposal and the delay elapses, anyone can call `executor.execute(...)` **directly** (bypassing the Governor wrapper). The actions still run **exactly once** (Executor's `executed` flag), with the identical hash-pinned payload — but the Governor's `proposals[id].executed` stays `false`, so `Governor.state()` keeps returning `Queued` and `ProposalExecuted` is never emitted; a later `Governor.execute()` reverts inside the Executor (`OperationAlreadyExecuted`), leaving the flag stuck `false` forever. **No double-execution, no fund loss, no vote bypass** — purely off-chain/indexer confusion. *Fix pre-handoff: gate `Executor.execute()` to PROPOSER too, OR have `Governor.execute()` tolerate an already-executed op (read `Executor.executed` / try-catch) so the flag reconciles.*

### EXEC-5 — No expiry on a queued operation · **Low (design)**
A scheduled op never expires; it remains executable forever after the delay (unless executed). Benign (the action was approved), but worth noting alongside the no-cancel property. Leftover ETH sent to the Executor rests harmlessly via `receive()`.

---

## Handoff requirements (Executor)
1. Decide on **EXEC-1**: add a guardian-cancel and/or independent pause guardians before making the Executor admin of everything. This is the single most consequential decision.
2. Apply the **EXEC-4** fix (cheap, pre-handoff) to keep governance dashboards accurate.
3. Document the **~28-day** worst-case change latency and **immutable-proposer** rigidity (EXEC-2/3) as accepted properties.
4. Transfer admin/owner of each governed contract to `0x710AE211` **in a controlled order**, verifying after each that the Executor (not the EOA) holds it and that the EOA's roles are revoked. See `findings/ValinityGovernanceOfficer.md` (GCE-4) for the full ordering checklist.
