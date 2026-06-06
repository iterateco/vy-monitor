# CORRECTION: VRT source==live — NO reconstruction needed (my earlier excision was a tooling bug)

**Status: RETRACTED.** This file previously claimed the live VRT was missing `decreasePositionLiquidity` and that the source had to be reconstructed by excising it. **That was wrong** — caused by a false-negative in my selector-presence check. The user caught it via the metadata-hash argument.

## The actual truth
- **Live impl `0x5a2ce62e…` metadata IPFS hash == artifact metadata hash** (`a1875f40…`, solc 0.8.27), byte-identical. The CBOR metadata hash is computed over the source + settings, so **identical hash ⇒ identical source.** The live VRT IS the full `c5719033` source (816 lines), `decreasePositionLiquidity` included.
- The only on-chain vs artifact `deployedBytecode` difference is the **2×20-byte UUPS `__self` immutable** (impl address) at offsets 4920 & 6257 — not logic.
- The workspace `.sol` == this source except a NatSpec doc expansion on `applyInterest`'s `recipient` param (comment-only, zero bytecode impact).

## My bug (now fixed)
`decreasePositionLiquidity`'s selector is **`0x006b09c4` — it has a leading zero byte.** The optimizer pushes such selectors with a shorter opcode (`PUSH3 6b09c4`), dropping the leading `00`. My guard searched the runtime for the full 4-byte hex `006b09c4`, which is NOT present as a literal substring → **false negative** → I wrongly concluded the function wasn't deployed and excised it.

**Fix applied to `extract_asdeployed.mjs` and `match_source_to_live.mjs`:** strip leading `00` byte-pairs from each selector before substring-searching the bytecode (minimal PUSH-immediate form). After the fix the VRT guard reports **43/43 (100%)**. Re-checked VAO (64/64) and MEVBot (36/36) — neither had leading-zero selectors, so neither was affected; only VRT.

## Consequence
- The audited source has been **restored to the full 816-line `c5719033` source** (no excision). `decreasePositionLiquidity` + its internal caller `_reSnapshotAfterDecrease` are IN SCOPE and have been audited (see `findings/ValinityReserveTreasury.md`).
- The earlier VRT multi-agent workflow ran on the *reduced* source, so it did NOT cover `decreasePositionLiquidity`. That function is audited here in the follow-up so VRT coverage is complete.

## Lesson (reinforced, generalized)
1. **Lead with the metadata-hash check.** Identical on-chain vs artifact CBOR metadata hash ⇒ identical source. It's the strongest, simplest source==live proof — stronger than per-selector heuristics. (The user used exactly this.)
2. Selector substring search MUST account for leading-zero selectors (PUSH-opcode sizing). Fixed.
3. "artifact-bytecode == live" + "metadata hash == artifact" together = source==live, full stop. The VAO drift was a genuinely different/stale artifact; VRT was NOT — my method, not the artifact, was wrong here.
