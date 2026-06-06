# Roles & Permissions Matrix (v0 seed)

> Seeded from `docs/ECOSYSTEM-ARCHITECTURE.md`. These are **documented** grants — every row must be confirmed against live state in Phase 3 (`getRoleMember`/`hasRole`/`owner()` via RPC). Discrepancies are findings.

| Contract | Role | Documented holders | Capability | Blast radius if compromised |
|----------|------|--------------------|------------|------------------------------|
| VY Token | DEFAULT_ADMIN / ADMIN | Governance | Configure fees, whitelist | Disable fees, whitelist attacker (fee bypass) |
| VY Token | MINTER_ROLE | VYT, VAO | Mint VY | **Unbounded VY mint → dilute/drain** |
| VYT | OFFICER_ROLE | VAO, (MEVBot), (YieldOfficer) | pullTokens (auto-mint deficit) | **Trigger VY mint** |
| VRT | OFFICER_ROLE | VLO, VAO | Transfer assets, update collateral | **Move reserve assets out** |
| VRT | BUYBACK_ROLE | BuybackOfficer | withdrawForBuyback | **Withdraw reserves** |
| VRT | ADMIN_ROLE | Governance | Pause/unpause, migration | Migrate/redirect reserves |
| VCO | OFFICER_ROLE | VAO, VLO, YieldOfficer | Update caps | Distort caps/floor accounting |
| VAO | WALLET_ROLE | Backend (KMS) wallets | Trigger acquisitions | Force swaps / sandwichable mints |

## Authority questions to resolve (Phase 3)
- What is `0xAAaA…F39B` (Admin)? EOA, Gnosis Safe, or contract? Threshold/signers?
- Who holds `DEFAULT_ADMIN_ROLE` on each contract on-chain right now?
- Who can `upgradeTo` each proxy? Is there a timelock between grant and execution?
- Which backend/keeper EOAs hold `WALLET_ROLE`/keeper roles, and are they KMS-custodied?
- Does any single key hold MINTER + OFFICER + upgrade authority simultaneously?
