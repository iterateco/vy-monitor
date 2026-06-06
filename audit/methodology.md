# Audit Methodology

## Cardinal safety rules (read-only audit)

1. **No mainnet state changes, ever.** RPC is used only for `eth_call`, `eth_getCode`, `eth_getStorageAt`, `eth_getLogs`, `eth_getBalance`. No transactions are signed or sent against mainnet.
2. **Exploit PoCs run only on a local fork** (anvil/hardhat `--fork-url <alchemy>`), never live.
3. **Secrets never enter chat or git.** Alchemy/Etherscan keys live in an untracked `.env` (already covered by `.gitignore`); referenced via env vars only.
4. **Audit the deployed code, not the repo.** For each proxy we resolve the implementation on-chain (`eth_getStorageAt` of the EIP-1967 impl slot), pull verified source from Etherscan, and diff it against the local repo. Drift is itself a finding.
5. **Trust nothing as documented.** Roles, owners, caps, and config in docs/deploy scripts are treated as claims to verify against live state.

## Per-contract audit (Phase 1, each spoke)

For each contract, in order:

1. **Resolve identity** — proxy vs. impl address, proxy pattern (UUPS/Transparent/Beacon), admin/owner, init status, verified-source match vs. repo.
2. **Map authority** — every role, modifier, and `onlyX`; who holds each on-chain; what each gated function can do; blast radius if that key is compromised.
3. **Trace value** — what tokens/assets it custodies or can move; every path that moves value out; mint/burn authority.
4. **External calls** — every call to another contract (internal or external like Uniswap/HyperSwap/bridges); reentrancy surface; return-value & approval handling; CEI adherence.
5. **Arithmetic & economics** — rounding, over/underflow, decimals mismatches, fee math, share/price math, donation/inflation attacks, first-depositor, slippage/MEV.
6. **Oracle/price** — price sources, manipulation surface (spot vs. TWAP), staleness, sanity bounds.
7. **Upgrade safety** — storage layout vs. prior impl (from `.openzeppelin` manifest), initializer protection, `_disableInitializers`, gap usage, unsafe `delegatecall`/`selfdestruct`.
8. **Failure modes** — pause/emergency paths, stuck-funds, griefing, DoS via gas or revert.
9. **Adversarial verification** — every candidate finding is independently re-checked by a skeptic that tries to *refute* it; only survivors are recorded.

## System-level audit (Phase 2, cross-cutting passes)

Run as separate themed sessions, each reading all spoke findings:

- **Access-control graph** — full role map across contracts; privilege-escalation chains; can any single key (or the multisig) drain the system; orphaned/over-broad grants.
- **Economic invariants** — does VY stay collateralized; can the floor price be gamed; mint/burn ↔ treasury accounting consistency; can acquisition/buyback/loan loops be exploited for value extraction.
- **Oracle & price manipulation** — cross-contract: can a manipulated Uniswap spot price move VAO/Loan/DAX in attacker's favor in one tx/flashloan.
- **Upgradeability** — who can upgrade what, timelock presence, storage-collision across the officer mesh.
- **Governance** — committee/executor/officer powers; proposal → execution path; can governance rug; emergency override.
- **Liquidity** — pool depth vs. position sizes; LP NFT ownership (note: LP NFTs live on VRT, not VLM); withdrawal/redemption under stress.
- **Integration** — Uniswap V2/V3, HyperSwap, bridges, KMS-controlled backend wallets; trust assumptions and failure of each dependency.

## Severity rubric

Severity = Impact × Likelihood.

| Severity | Meaning |
|----------|---------|
| **Critical** | Direct loss/theft of funds or unbounded mint; practical to execute. |
| **High** | Loss/freeze of funds under plausible conditions, or full privilege escalation. |
| **Medium** | Conditional loss, significant griefing/DoS, or broken invariant with limited blast radius. |
| **Low** | Minor/edge-case issue, defense-in-depth gap. |
| **Informational** | Code quality, gas, docs, drift from spec. |

Each finding: ID, contract+address, category, severity, impact, reproduction (fork PoC where applicable), affected addresses, recommended fix, status. Template in `findings/_TEMPLATE.md`.
