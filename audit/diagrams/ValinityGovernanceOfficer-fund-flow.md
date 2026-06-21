# ValinityGovernanceOfficer — the Governor · **dual-chamber stake-to-vote (handoff destination, governance side)**

Address `0x4548963212390B1E44eFc69BcC672dd84d09bbA1` — **NON-PROXY, NON-UPGRADEABLE** (plain contract + ReentrancyGuard; all links immutable; **NO admin roles**). The only PROPOSER on the Executor timelock; its two-stage vote gates every governance action. Source==live **PROVEN** (live metadata-IPFS `1220303368…` == artifact == build-info `3221a1b0` compile of workspace `ValinityGovernanceOfficer.sol`, keccak match). solc 0.8.27 / runs=100 / cancun.

> **Immutable links:** vgc `0xe595309a` · vy `0x597b2952` · vrt `0x06087789` · vyt `0xe58E29c9` · executor `0x710AE211` · premiumRegistry=VYO `0xA245C9D2` · stakingRouter=VSR `0x664b3A81`.

## Atomic flow — escrow IN/OUT + the pipeline (admin functions: none exist)

```
 STAGE 1 — VGC DRAFT chamber (7 days)
   anyone ── propose(targets,values,calldatas,desc, escrowVGC) ──▶ Governor   [nonReentrant; one in-flight; proposer cooldown]
        │   weight = escrowVGC (safeTransferFrom → locked till draftEnd) + VSR-staked VGC (unlockTime>draftEnd, counted once)
        │   require weight >= 1% of VGC.totalSupply ; vgcSnapshot = VGC.totalSupply
   anyone ── supportDraft/opposeDraft(id, escrowVGC) ──▶ Governor      (same weight rules; can't vote both sides)
   anyone ── promote(id) ──▶ Governor   [after draftEnd, if premiumYES + vgcCast>=50%snapshot + vgcYes>=51%cast]
        │   circulatingVY = VY.totalSupply − VY.bal(VRT) − VY.bal(VYT)   (snapshot)   ◀── GOV-M1 timing lever
        └── opens Stage 2

 STAGE 2 — VY PROPOSAL chamber (7 days)
   anyone ── voteYes/voteNo(id, escrowVY) ──▶ Governor
        │   weight = escrowVY (safeTransferFrom → locked till voteEnd) + VSR-staked VY principal (unlockTime>voteEnd, counted once)
        │   (Governor IS VY-fee-whitelisted → escrow exact)

 STAGE 3 — QUEUE + EXECUTE
   anyone ── queue(id, targets,values,calldatas) ──▶ Governor   [after voteEnd, if premiumYES + vyCast>=50%circ + vyYes>=70%cast]
        │   require hashActions(...) == p.actionsHash    ◀── binds executed actions to voted actions
        └── executor.schedule(targets,values,calldatas, salt=bytes32(id))     → 7-day Executor delay
   anyone ── execute(id, targets,values,calldatas) ──▶ Governor   [after delay]
        │   require hashActions(...) == p.actionsHash
        └── executor.execute{value}(targets,values,calldatas, salt)            → the governed contracts

 ESCROW RECLAIM (the only token outflow from the Governor)
   voter ── withdrawVGC/withdrawVY(amount) ──▶ Governor   [after their unlockTime; bal-checked; recipient = msg.sender ONLY]
```

## Token flow — the Governor custodies ONLY voter escrow, returnable to the depositor
| Movement | Token | Destination | Gate |
|---|---|---|---|
| escrow in (vote weight) | VGC / VY | Governor (locked) | `safeTransferFrom(msg.sender)`; locked until window end |
| escrow out (reclaim) | VGC / VY | **msg.sender only** | after `unlockTime`; `vgcLocked`/`vyLocked` checked then decremented |
| (no other token sink) | — | — | the Governor never sends escrow anywhere but back to its depositor |

**Closed/sound (workflow VGO-VOTE-5, ESC-3/4):** voter escrow can only return to the depositor; no theft, no over-withdraw, no drain (even by a proposal targeting the Governor). The same tokens cannot vote twice (lockups + `stakeCounted` + `unlockTime>windowEnd` defeat flash-loan / cross-wallet re-use). Executed actions are bound to voted actions (`hashActions` re-checked at queue+execute). **0 fund-theft, 0 vote-forgery.**

**Verdict (RECONCILED, workflow `wapagthnp` — 27 raw→21 surv/6 ref):** ✅ **SAFETY PROVEN (vote integrity + escrow custody + action-binding sound); the real risks are LIVENESS/RIGIDITY.** **GOV-H1 (High, permissionless DoS — FIX BEFORE HANDOFF):** the single in-flight slot is monopolizable with ~1-2% VGC via fresh proposer EOAs (cooldown is per-`msg.sender`, dodged) → can perpetually freeze ALL governance. **GOV-M1 (Medium):** `circulatingVY` quorum denominator shrinkable at the permissionless, attacker-timed `promote()` (bounded — can't beat the 70% supermajority). **GOV-M2 (Medium):** the supply-anchored 50% quorum is strong anti-capture but a turnout dependency (circulating VY only ~418k of 17.9M); capture collapses to ~50% VY + ~50% VGC; premium gate is a weak single-wallet binary. Lows: VY-fee-whitelist dependency (governance could de-whitelist itself), cheap premium gate (anti-spam only), self-relock (delay not loss), no Governor-side veto once Succeeded. See `findings/ValinityGovernanceOfficer.md`.

---

## ⚙️ Governance design parameters — PERMANENT once handoff completes (the Governor is non-upgradeable)
| Parameter | Value | Implication |
|---|---|---|
| Draft threshold / quorum / majority | 1% / 50% / 51% (VGC) | Stage-1 gate; 1% propose threshold is the DoS lever (GOV-H1) |
| Proposal quorum / supermajority | 50% / 70% (circulating VY) | Strong anti-capture; **liveness risk if turnout < 50%** (GOV-M2) |
| Windows | 7d draft + 7d promote + 7d vote + 7d Executor delay | ~28-day minimum to enact anything; no fast path |
| Electorate | circulating VY ~418k of 17.9M (VRT 10.4M + VYT 7.1M excluded) | small voting base — confirm 50% turnout is achievable |
| Premium gate | 1 premium YES per chamber | weak (cheap to obtain) — anti-spam only |
| Proposer cooldown | per-`msg.sender`, 7d | **dodgeable via fresh EOAs → GOV-H1** |

→ **Before the irreversible handoff:** fix GOV-H1 (un-dodgeable cooldown / slashable bond / multiple drafts); confirm the 50% quorum is reachable; keep the Governor permanently fee-whitelisted; decide the Executor's guardian-cancel (EXEC-1). See both findings docs.
