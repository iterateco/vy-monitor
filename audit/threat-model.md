# Threat Model & Risk Taxonomy

Covers the risk classes you named, mapped to this protocol. Phase 0 synthesis populates the live **risk register** at the bottom; this top section is the standing checklist every audit pass works through.

## 1. Permission / access-control risk
- Over-broad roles (`DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, `OFFICER_ROLE`, `BUYBACK_ROLE`, `WALLET_ROLE`).
- Backend/keeper EOAs (KMS-controlled) that can trigger value-moving functions — what's the worst a compromised keeper does?
- Single-key control of multi-million-dollar functions; multisig threshold/signers.
- Missing `onlyRole` checks; functions callable by anyone that assume a trusted caller.

## 2. Economic / accounting exploits
- VY mint authority: VYT `pullTokens` auto-mints deficit — can an officer be coerced to mint unbounded VY? Rate-limit correctness.
- Floor price (TVL / circulating VY) manipulation; cap increase/decrease loops (fees → cap, buyback → cap).
- Acquisition Officer: MTP/LTV trigger math, swap slippage, sandwich exposure during VY↔USDC↔asset hops.
- Loan Officer: collateral/principal/interest math; under-collateralized loans; repayment rounding.
- Buyback Officer: VRT withdrawal vs. burn accounting; cap decrease consistency.
- Cross-officer value-extraction loops in a single tx / flashloan.

## 3. Oracle / price risk
- Spot price from Uniswap pools (`VyUsdcPool`) — manipulable vs. TWAP?
- Staleness / sanity bounds; what happens if a pool is drained or a feed reverts.
- Decimals/precision across PAXG(?)/WBTC(8)/WETH(18)/USDC(6).

## 4. Upgrade risk
- UUPS/Transparent/Beacon mix; who holds upgrade authority; timelock?
- Storage-layout collisions across the many V2/V3/V4/V5 upgrades already shipped (manifest has a `before_v3_upgrade` backup — high-signal).
- Initializer protection on impls; `_disableInitializers`; re-init exposure.

## 5. Liquidity risk
- Uniswap V2/V3 pool depth vs. acquisition/buyback/loan sizes.
- LP NFT custody: NFTs are owned by **VRT**, managed by VLM — confirm on-chain and check manager authority can't redirect.
- Redemption/withdrawal under stress; can the protocol be left unable to honor loans/buybacks.

## 6. Governance risk
- ValinityGovernanceCommittee / ValinityExecutor / ValinityGovernanceOfficer powers; proposal→execution path; timelock; can governance unilaterally drain or mint.
- VDAO / alliance registration powers.

## 7. Integration risk
- Uniswap V2/V3 routers & factory; HyperSwap; any bridge (DeBridge seen in earlier notes); KMS backend wallets.
- Reentrancy / unexpected callbacks from external protocols; approval hygiene; failure-mode handling.

## 8. Code-level / generic
- Reentrancy (cross-function & cross-contract), CEI violations.
- Unchecked external call return values, ERC20 non-standard returns, fee-on-transfer interactions (VY itself has a 1% transfer fee — every internal VY transfer must account for it).
- DoS via revert/gas, unbounded loops (`getAssetsSortedByLTV`), front-running.

## 9. Operational / off-chain
- KMS key handling, deployer key residual permissions, drift between repo and on-chain code.

---

## Live risk register
_(populated by Phase 0 synthesis — see workflow output)_
