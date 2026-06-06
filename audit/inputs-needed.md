# Inputs Needed To Proceed

## Blocking (needed for Phase 3 live-state verification + fork PoCs)
1. **Alchemy RPC URL** for Ethereum mainnet. Put it in `vy-monitor/.env` as `ALCHEMY_MAINNET_URL=...` (do **not** paste the key in chat). I'll read it via env var only.
2. **Etherscan API key** → `.env` as `ETHERSCAN_API_KEY=...` (to pull verified source + confirm bytecode + read proxy impl history). Free tier is fine.

## Important (sharpens scope & priority)
3. **Confirm the live address list.** `Admin.json` is incomplete/hand-maintained. Confirm which of these are actually live and holding value today, and the canonical address for: VLM, ExchangeOfficer, ReserveYieldOfficer, GasOfficer, FloorOfficer (artifacts exist, no `Admin.json` entry).
4. **What is `0xAAaA…F39B` (Admin)?** EOA, Gnosis Safe, or a contract — and if a Safe, the signer set and threshold.
5. **Upgrade authority & timelock.** Who can `upgradeTo`/`upgradeToAndCall` each proxy? Is there a timelock or is it immediate?
6. **Backend/keeper wallets.** Which EOAs hold keeper/`WALLET_ROLE` powers, and are they all KMS-custodied? (Affects "compromised keeper" blast-radius analysis.)
7. **Intended invariants / economic model.** Confirm the must-always-hold properties (e.g., VY collateralization, floor = TVL/circulating, mint rate limits, 7B cap). I'll extract a draft from `VALINITY-SOURCE-OF-TRUTH.md` and you confirm/correct.
8. **The capital plan being gated.** How much new capital, into which contracts, and what new contracts are next to deploy — so Phase 1 prioritization matches what's actually at risk.
9. **Prior audits / known concerns**, if any.

## Nice to have
10. Read access to `/Users/sergiosolano/Valinity` as a working dir (currently I can read it, but explicit access avoids friction and lets findings reference exact line numbers).
11. The `VALINITY-SOURCE-OF-TRUTH.md` and `GOVERNANCE-TRANSFER-PLAN.md` confirmed as current.

> Until 1–2 arrive, I can fully complete Phases 0–2 from local + Etherscan-public data. Phase 3 (live state) and fork PoCs need the RPC key.
