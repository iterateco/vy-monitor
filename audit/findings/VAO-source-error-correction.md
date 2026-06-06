# CORRECTION: VAO was audited against the WRONG (non-deployed) source — redone

**Date:** 2026-05-31. **Severity of the process error:** high (an entire contract report was invalid).

## What happened
The first VAO audit (now quarantined in `audit/_INVALID_redo/`) analyzed a **587-line `acquire()`-based V1** contract that **is not deployed**. The user caught it: the live VAO is the **permissionless V2** with two unguarded entrypoints (`executeAcquireByLTV()` / `executeAcquireByMTP()`) that route VY→asset through the **Valinity DAX** and deliver to VRT — exactly the contract in the workspace.

## Root cause
`extract_asdeployed.mjs` read `artifact.solcInputHash` and trusted it. At the time of first extraction the `ValinityAcquisitionOfficer.json` artifact was in an **inconsistent state**: its `.solcInputHash` pointed at the stale V1 source (`d5fc10e8…`) while its `deployedBytecode` was already V2. The artifact was re-saved during the session (mtime 2026-06-01T01:20, `numDeployments: 2`) and its hash corrected to the V2 source (`cb6d5b6c…`).

Critically, my `bytediff.mjs` **correctly** showed artifact-bytecode == live (because the artifact's *bytecode* was genuinely V2). The bug was that I extracted *source* from a hash that did **not** compile to that bytecode, and never cross-checked that the live functions appeared in the extracted source. That selector cross-check is the guard I had earlier identified as essential and dropped.

## Proof of the correct source==live
- Live impl `0xc364f74e…`; `executeAcquireByLTV()` (`0xc5764fa7`) and `executeAcquireByMTP()` (`0x89ea873b`) are **PRESENT** in live bytecode; `acquire(...)` (`0xf31ad8b6`) is **ABSENT**.
- Workspace `ValinityAcquisitionOfficer.sol` (858 ln) sha256 == solcInputs[`cb6d5b6c`] source sha256 == `72e44493…` (**identical**).
- Artifact `deployedBytecode` == live runtime (diff = only the 2 UUPS immutables @6319/6522).
- Re-extracted via hardened extractor: **64/64 ABI selectors in bytecode (100%)**, guard PASS.

## Fix to prevent recurrence
`extract_asdeployed.mjs` now runs a **selector-presence guard**: it derives selectors from the artifact ABI, requires ≥95% to appear in `deployedBytecode` (hard fail otherwise), and writes the rate into `_MANIFEST.json.guard`. **Negative test confirmed:** the old V1 ABI selectors score 0/5 against V2 bytecode → the guard now FATALs on exactly this mistake.

## Lesson (added to methodology)
"artifact-bytecode == live" proves the *artifact* matches live, but NOT that the *solcInputs source* matches the artifact — those are linked only by `solcInputHash`, which can be stale. **Always confirm the extracted source's functions are the live functions** (selector presence) before auditing. The workspace file, in this case, was actually correct — but the rule stands: verify, don't assume drift direction.
