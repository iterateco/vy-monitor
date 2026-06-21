# ValinityExecutor — Governance Timelock · **the handoff destination (executor side)**

Address `0x710AE2116B3EDd566D3594bd8191a4e6EFcE3449` — **NON-PROXY, NON-UPGRADEABLE** (plain contract; no EIP-1967 slot; logic frozen). The **7-day timelock** that will hold DEFAULT_ADMIN/ADMIN/owner of EVERY governed Valinity contract and execute governance-approved batches. Source==live **PROVEN** (live metadata-IPFS `1220745fbf…` == artifact == build-info `3221a1b0` compile of workspace `ValinityExecutor.sol`, keccak match). solc 0.8.27 / runs=100 / cancun.

> **Constructor-immutable config:** `MIN_DELAY = 7 days` (hardcoded), sole PROPOSER = the Governor `0x4548…` (set once, no setter). **No admin role, no canceller role, EXECUTOR_ROLE = anyone.**

## Atomic flow — the only two state-changing entries

```
 Governor (sole PROPOSER) ── schedule(targets[], values[], calldatas[], salt) ──▶ Executor   [onlyProposer]
        │   operationId = keccak256(abi.encode(targets,values,calldatas,salt))      (collision-safe; salt = bytes32(proposalId))
        │   require readyAt[operationId] == 0   (no reschedule)
        └── readyAt[operationId] = block.timestamp + 7 days

 …7-day delay…

 anyone ── execute(targets[], values[], calldatas[], salt) ──▶ Executor   [permissionless by design]
        │   require readyAt != 0  &&  block.timestamp >= readyAt  &&  !executed         (gates)
        │   executed[operationId] = true     ◀── set BEFORE the calls (CEI / reentrancy + replay guard)
        └── for i: (ok, ) = targets[i].call{value: values[i]}(calldatas[i]); revert CallFailed on !ok   ◀── ATOMIC batch
            → the governed contracts (VCO/VYT/VRT/officers/…): grantRole / upgradeToAndCall / setters / etc.
 receive() external payable {}   ── accepts ETH for value-bearing batches
```

## Token/authority flow — the Executor holds AUTHORITY, not protocol funds
| Movement | Who | Gate | Note |
|---|---|---|---|
| schedule an op | **Governor only** | `onlyProposer` (immutable set) | `isProposer` written once in constructor; no setter |
| execute a ready op | **anyone** | `readyAt`+7d+`!executed` | runs the exact hash-pinned batch once; CEI-guarded |
| arbitrary admin actions | the Executor (as admin of governed contracts) | a passed proposal only | this IS the handoff power — grant/upgrade/set on every contract |
| ETH | forwarded `values[i]` per call | — | over-sent ETH rests in `receive()` |

**Closed/sound:** only the Governor can schedule; `execute` can only run a Governor-scheduled, 7-day-aged batch, exactly once (CEI), with the exact voted actions (the Governor pins `hashActions` at queue+execute and the Executor re-derives `operationId`). No replay, no collision, no double-execution, no unprivileged scheduling (workflow EXEC-1/2/3/4 refuted as exploits).

**Verdict (RECONCILED, workflow `wapagthnp`):** ✅ **Timelock core mechanics sound — 0 permissionless break, 0 replay/collision.** Residual is ALL **deliberate design trade-offs** for the irreversible handoff: **EXEC-1 (High-design)** NO CANCELLER — a passed-but-malicious/buggy batch is unstoppable once scheduled (only the 7-day window to react off-chain); **EXEC-2 (Medium)** immutable proposer — a buggy Governor can't be replaced without redeploy + full re-handoff; **EXEC-3 (Medium)** the 7-day delay is the only emergency lever (~28-day bug-fix latency); **EXEC-4 (Low)** permissionless direct `execute()` desyncs the Governor's `p.executed` (cosmetic — actions still run once; fix pre-handoff); **EXEC-5 (Low)** no op expiry. See `findings/ValinityExecutor.md`.

---

## ⚙️ Handoff decisions — PERMANENT once the Executor becomes admin of everything
| Decision | Effect | Recommendation |
|---|---|---|
| **Add a guardian `cancel`?** | Without it, a malicious/buggy passed proposal is unstoppable on-chain (EXEC-1) | Strongly consider a cancel-only guardian (multisig that can only cancel) and/or per-contract pause guardians on VRT/VYT/VCO independent of admin |
| **Accept immutable proposer?** | A buggy Governor can never be replaced (EXEC-2) | Decide consciously; ossification is the trade-off for credible neutrality |
| **Accept ~28-day change latency?** | No fast emergency lane (EXEC-3) | Pair with per-contract pause guardians for time-critical defense |
| **Apply EXEC-4 fix?** | Keeps governance dashboards accurate | Cheap pre-handoff fix (gate execute to PROPOSER, or reconcile the flag) |
| **Role-transfer ordering** | The Executor becomes sole admin/owner of the whole system | See Governor diagram GCE-4 checklist; verify after each transfer; revoke the EOA |
