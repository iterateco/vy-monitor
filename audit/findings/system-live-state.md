# Finding: Live-state certification (Step B, on-chain via default-profile Alchemy)

- **ID:** VAL-001
- **Category:** operational / upgrade
- **Severity:** High (upgrade-tracking + stale-source integrity gaps on funds-moving contracts) + a system-wide centralization observation.
- **Status:** confirmed, self-verified. chainId 1, block ~25,217,820. Each EIP-1967 impl slot read **twice and asserted stable**; bytecode compared metadata-stripped.
- **Method:** `audit/scripts/step_b.mjs` via `audit/scripts/rpc.mjs`, resolving RPC from the repo **default profile** (`Valinity/secrets.ts` → `eth_mainnet.rpc_url`, Alchemy). Read-only methods only (`eth_getCode`/`eth_getStorageAt`/`eth_call`/`eth_chainId`/`eth_blockNumber`).

> **Correction:** an earlier non-self-verified pass wrongly claimed the YieldOfficer address resolves to a VDAX token. **Retracted** — that was a tooling error (arbitrary manifest addresses were conflated). Verified: YieldOfficer impl `0x3cfd40d0…` ≠ VDAX impl `0xb6860e90…`; YieldOfficer `name()` is empty (not a token). Trust only this file + `live-state-report.md`.

## What is certain
- **All 18 addresses have code, none are paused, and Admin `0x8310eA7EC55A7Ad6A4288aF683155A124A524a09` holds DEFAULT_ADMIN_ROLE on every one** (FloorOfficer included, on this rerun). No shared implementations.
- **Bytecode buckets vs the recorded deploy artifact:**
  - `EXACT` (1): ValinityToken.
  - `EQUIVALENT-IMMUTABLES, 40–297B differ` (11): VDAX, VAO, BuybackOfficer, FloorOfficer, VLM, VLO, MEVBotV2, Portal, **VRT**, ReserveYieldOfficer, **VYT**. Same length, differing only in the byte-count expected for baked-in immutable addresses → almost certainly the same source as the artifact (to be spot-checked that diffs sit at immutable offsets).
  - `MISMATCH, live larger than artifact` (6): **VCO**, ValinityDAX, ExchangeOfficer, GasOfficer, StakingRouter, **YieldOfficer**. Live impl is a **newer build than the recorded artifact** → the artifact (and therefore the Step A `solcInputs` as-deployed source) is **stale**; must audit these from Etherscan-verified live source.

## VAL-001a — 7 live impls are UNTRACKED by the OZ manifest (High)
Live impls **not present** in `.openzeppelin/mainnet.json` (39 tracked impls):
`ValinityReserveTreasury` (P0), `ValinityBuybackOfficer` (P0), `ValinityLiquidityManager`, `ValinityDAX`, `ValinityYieldOfficer`, `ValinityReserveYieldOfficer`, `ValinityMEVBotV2`.
→ These were upgraded **outside the OZ Upgrades plugin**, so storage-layout collision safety was never machine-checked for those upgrades. VRT holds all reserve assets — an unchecked storage-layout change there is a direct solvency risk. **Action:** reconstruct storage layout for each live impl (Etherscan source + `forge inspect`/manual) and diff against the prior tracked impl before trusting them; this is a pre-condition to clearing the capital gate.

## VAL-001b — 6 contracts: artifact stale vs live; 2 of those have no local source at all (High/Med)
- MISMATCH set above: the recorded artifact ≠ live, so local source is not authoritative → **audit from Etherscan live impl**. Includes **CapOfficer** (P0, caps/floor accounting).
- BuybackOfficer (`0x4B97…`) and MEVBotV2 (`0x6f2F…`) artifacts are **proxy-pointer only** (no `solcInputs` source bundle — NO-DEPLOYED-SRC in Step A) **and** UNTRACKED here → **no local source for the live code**; recover from Etherscan before any review. BuybackOfficer is P0 (withdraws reserves from VRT, burns VY).

## VAL-001c — central authority = single role over all proxies (High, by design; verify custody)
One admin (`0x8310eA7EC…`) holds DEFAULT_ADMIN_ROLE on all 18 UUPS proxies = sole upgrade authority. Its compromise = full-system compromise via malicious upgrade (and VY token, being non-proxy/immutable, is the only thing outside its reach). Docs claim this is an AWS-KMS multisig. **Phase 3 action:** confirm on-chain what this address *is* (EOA / Gnosis Safe / custom) and its signer set + threshold — this single fact bounds the entire upgrade-risk surface.

## Definitive "audit source" per contract (combines Step A + Step B)
| Live code source to audit | Contracts |
|---|---|
| **Workspace** (Step A green ∧ Step B EXACT/equiv) | ValinityToken, VRT*, VYT*, Portal, VDAX, GasOfficer→*see note |
| **As-deployed `solcInputs`** (Step A drift ∧ Step B equiv) | VAO, VLO, VLM, ReserveYieldOfficer, FloorOfficer |
| **Etherscan live impl** (Step B MISMATCH — artifact stale) | VCO, ValinityDAX, ExchangeOfficer, GasOfficer, StakingRouter, YieldOfficer |
| **Etherscan (no local source)** | BuybackOfficer, MEVBotV2 |

\*VRT/VYT show `EQUIVALENT-IMMUTABLES` not byte-EXACT; treat as workspace-auditable only after confirming the byte diffs are immutables (constructor/`immutable` addresses), not logic. GasOfficer is Step A green but Step B MISMATCH → its live impl is newer than the green artifact, so audit from Etherscan, not workspace.

## Net
The clean, no-caveat starting point is **ValinityToken** (immutable, non-proxy, byte-EXACT). VRT and VYT are next pending the immutables spot-check. Everything in the MISMATCH/UNTRACKED sets needs its live source pinned (Etherscan) and, for the UNTRACKED set, a manual storage-layout safety check before it can gate capital.
