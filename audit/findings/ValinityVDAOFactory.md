# ValinityVDAOFactory + ValinityVDAO — Findings

**Factory:** UUPS proxy `0x5C92f6Cd5280BFf0e32970fCAA0997c1E93a2B39` → impl `0x6a7a847ab26daec63ffd5dbe60b915248c0a1a28`.
**Token:** `ValinityVDAO` — immutable, CREATE2-deployed per launch (no standalone deployment; none launched yet).
**Source==live:** PROVEN — live factory-impl metadata-IPFS == deployment-json deployedBytecode == workspace `.sol` keccak256 for BOTH files (deployed from the dirty workspace; HEAD `a85f449` is behind). solc 0.8.27 / runs=100 / cancun.
**Status:** ✅ RECONCILED with workflow `wg9tl6qlr` (12 agents, 5 dims → adversarial verify → synthesis; 49 raw → 3 survived / 3 refuted / 43 Low-Info). Verdict aligned: **all 3 KEY PROPERTIES CONFIRMED** (recipient-side fee, hook-free, main-DAX-exempt → DEX assumptions discharged); closed-circuit + supply + vesting sound; ZERO permissionless-exploitable. Tally: 1 Critical · 1 High · 1 Medium · 4 Low/Info.

## Summary

A small (228 + 191 ln), clean subsystem. Its purpose for the audit chain: **confirm the V-DAO token behaves exactly as the already-completed DEX audits assumed** — and it does.

- **Three load-bearing properties HOLD (discharge prior assumptions):**
  - **Recipient-side fee ✅** — `_update` burns the 0.7% out of `value` (sender's balance drops by exactly `value`; recipient gets `value−fee`). So a non-exempt DEX sending `amountOut` has its balance drop by exactly `amountOut` → reserve stays in sync. **Discharges VDAO-DAX-M3** (the V-DAO is *not* a sender-side-FoT token).
  - **Hook-free ✅** — plain ERC20+Burnable+Permit; `_update` only calls `super._update` (no external calls / ERC777 hooks). **Discharges the DEX no-reentrancy assumption.**
  - **Main-DAX exempt, VDAO-DAX not ✅** — `feeExempt`={factory, address(this), varo, veo, vdax(main DAX)}; the VDAO-DAX is deliberately non-exempt (balance-delta accounting makes its burn safe + deflationary).
- **#1 closed-circuit (PASS).** Token is fully immutable (no admin/owner/upgrade/setter); the only V-DAO exits are: active half → VARO (the launch caller), vest → the immutable `creator`, fee → burn. No arbitrary-recipient path, no rescue/sweep. Factory holds V-DAO only transiently. Neither contract holds VY/USDC/asset.
- **Supply/vesting (PASS).** Only the constructor mints, exactly 2× activeSupply; burns only shrink. Vesting is linear, capped at `vestTotal`, CEI-correct, creator-only, no over-claim, no reentrancy.
- **Residual = factory admin/upgrade trust** (affects FUTURE tokens only) + a tokenomics note (creator vest = 50% of max supply over 1yr).

**Live: ready, no V-DAO launched yet.** Factory wired (varo/veo/mainDax = real contracts), admin=KMS.

---

## Findings (RECONCILED — lead-auditor + workflow `wg9tl6qlr`)

**Headline: the 3 load-bearing properties the DEX audits assumed are all CONFIRMED in code** — recipient-side fee (sender drops exactly `value`), hook-free `_update`, main-DAX-exempt / VDAO-DAX-not. This **discharges VDAO-DAX-M3 and the DEX no-reentrancy assumption.** Closed-circuit + supply (exactly 2× activeSupply, only-shrinks) + vesting (linear, capped, CEI, creator-only, no over-claim) all sound. Workflow refuted 3 of 6 Crit/High/Med over-claims (incl. the "previewNames permanently locks names" claim — refuted: `previewNames` runs *before* the reserve, so any revert is atomic). **ZERO permissionless-exploitable.**

### VDF-C1 [Critical — factory admin/upgrade, deferred-handoff] `_authorizeUpgrade` controls all FUTURE V-DAO minting
[ValinityVDAOFactory.sol:114](../asdeployed/ValinityVDAOFactory/contracts/alliance/ValinityVDAOFactory.sol#L114) — `_authorizeUpgrade(address) onlyRole(DEFAULT_ADMIN_ROLE)`, no timelock. A malicious upgrade rewrites `launch` for **future** V-DAOs: redirect the active half away from VARO, mint extra to an attacker, bake attacker exemptions, or rotate VARO. Since VARO launches continuously, the attacker steals every subsequent launch's `activeSupply`. **Already-deployed V-DAOs are immutable** and unaffected. Dominant lever. **Handoff:** migrate DEFAULT_ADMIN_ROLE to governance + external TimelockController **before** VARO is granted launch authority / starts launching; renounce the EOA. (Workflow rated this High as a "governance requirement"; I keep **Critical** for consistency with the other UUPS dominants — blast radius is all future minting.)

### VDF-H1 [High — factory admin/trust] `setVeo` / `setMainDax` weaponize permanent exemptions on all future V-DAOs
[ValinityVDAOFactory.sol:126-136](../asdeployed/ValinityVDAOFactory/contracts/alliance/ValinityVDAOFactory.sol#L126) — these set the `veo`/`mainDax` addresses baked as **permanent fee-exempt** into every FUTURE V-DAO (only a zero-check, no timelock). A malicious admin can (1) `setVeo(attacker)` → all future V-DAOs exempt a fee-skimming router; (2) `setMainDax(fakeDAX)` → poison the reserve-accounting DEX / break the main-DAX-exempt invariant; (3) set either to an EOA/0 → break the "blessed router." Irreversible per cohort (deployed tokens frozen). Foundational to the DEX audits, hence **High** (bumped from my preliminary Medium per the workflow). **Handoff:** timelock with `_authorizeUpgrade`; confirm `veo`=`0x48C88B80` / `mainDax`=`0xD256C672` (verified live).

### VDF-M1 [Medium — tokenomics, by-design] Creator vest = 50% of max supply over 1 year
[ValinityVDAO.sol:133-138](../asdeployed/ValinityVDAOFactory/contracts/alliance/ValinityVDAO.sol#L133) — total minted is 2× activeSupply; the locked half (= 100% of the tradeable/active supply, i.e. 50% of max) vests linearly to the creator over 1yr, on top of the ~10% launch cut. As the creator claims and sells into the VY/V-DAO + asset/V-DAO pools, they can extract the VY/asset that *they themselves* seeded (the launcher's payment). Transparent on-chain (`vestTotal`/`vestStart`/`vestedTotal` public). **Touches only the creator's own token + the launcher's own seeded liquidity — NOT protocol VY/backing.** Buyer-beware tokenomics, not a Valinity-core security issue; flag for V-DAO buyer disclosure.

### VDF-L1 [Low] Fee rounds to zero for tiny transfers
[ValinityVDAO.sol:182](../asdeployed/ValinityVDAOFactory/contracts/alliance/ValinityVDAO.sol#L182) — `fee = value·70/10000`; for `value < ~143` wei-units the fee is 0 (no burn, full transfer). Dust-only; negligible.

### VDF-L2 [Low — operational] Layer `previewNames` external-calls `parent.symbol()`
[ValinityVDAOFactory.sol:157](../asdeployed/ValinityVDAOFactory/contracts/alliance/ValinityVDAOFactory.sol#L157) — a nested layer's derived name reads `IERC20Metadata(parent).symbol()`. Parent is always a VARO-vetted launched V-DAO (VARO checks `isLaunchedVDAO[parent]`), so it's a benign factory-deployed token; a revert merely reverts the launch **atomically** (the workflow confirmed `previewNames` runs *before* the name reservation → no permanent name-locking). Operational nit; VARO should validate `parent` before `launch(layer>1)`.

### VDF-L3 [Low — operational, NEW from workflow] `setVaro` rotation sequencing
[ValinityVDAOFactory.sol:118-124](../asdeployed/ValinityVDAOFactory/contracts/alliance/ValinityVDAOFactory.sol#L118) — `setVaro` skips the old-role revoke when `varo==address(0)` (the initial state — `initialize` does not set `varo`). Call `setVaro` carefully on rotation so a stale VARO_ROLE holder can't linger in parallel. Live: `varo`=real VARO ✅ (set once).

### VDF-L4 [Info — upgrade hygiene, NEW from workflow] Storage gap sizing
[ValinityVDAOFactory.sol:227](../asdeployed/ValinityVDAOFactory/contracts/alliance/ValinityVDAOFactory.sol#L227) — `uint256[44] __gap` after 5 used slots. Standard UUPS gap; recompute on any future upgrade that appends storage.

### VDF-Info [confirmed] CREATE2 address can't be griefed
`launch` is VARO_ROLE-only and the only path that CREATE2-deploys a `ValinityVDAO`; no external party can deploy at a creator's predicted address. Salt=keccak256(creator); VARO's `vdao[creator]` mapping enforces one-per-creator. Confirmed safe.

---

## Handoff checklist (surfaced for governance — not subsystem bugs)
1. Migrate the factory's DEFAULT_ADMIN_ROLE to governance + external timelock with an upgrade delay, **before** VARO starts launching V-DAOs; renounce the EOA (VDF-C1). The factory upgrade lever controls every future V-DAO.
2. Timelock `setVeo`/`setMainDax` (fold with the upgrade lever); confirm they equal the real VEO `0x48C88B80` / DAX `0xD256C672` (verified live) (VDF-H1).
3. Disclose the creator vesting schedule (50% of max over 1yr) to V-DAO buyers (VDF-M1).
4. The deployed `ValinityVDAO` tokens are immutable — no handoff action (no admin/owner/upgrade).
5. ⚠️ Workspace VARO `.sol` shows `M` (pending edit); live VARO impl `0xeC4B6401` is unchanged = audited → re-audit VARO only if it is redeployed.
