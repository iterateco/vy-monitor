# ValinityVDAODAX — Findings

**Address:** UUPS proxy `0x37Cd61b3EF849805E598023f8C14bFcafE5f222E` → impl `0xe2883b425168F1FFf70E1F4cED3bB2cC86b288dc`.
**Source==live:** PROVEN by metadata-IPFS-hash equality + per-file source keccak256 (`.sol` + interface byte-identical, git-clean HEAD `a85f449`). solc 0.8.27 / runs=100 / cancun.
**Status:** ✅ RECONCILED with workflow `wvrnl84j3` (23 agents, 5 dims → adversarial verify → synthesis; 24 raw → 8 survived / 9 refuted / 7 Low-Info). Verdict aligned: locked-liquidity CONFIRMED, AMM math sound, `donate` safe — all residual is admin/trust/handoff or operational. Tally: 1 Critical · 3 Medium · 7 Low. ZERO permissionless-exploitable.

## Summary

A small (495 ln), clean constant-product AMM holding the **second leg** of every V-DAO's liquidity (asset/V-DAO + V-DAO/V-DAO pools). Sibling of the main ValinityDAX, but pairs **arbitrary** tokens and is structurally **simpler and stronger**:

- **#1 Locked-liquidity (PASS).** **No LP token, no deposit/withdraw/remove/collect/skim path.** Pool reserves can only grow (`addPool` seed, `donate`, swap input) or shrink via a **value-conserving, k-preserving swap** (`swapExactIn`, whitelist-gated). `rescueTokens` **reverts on any `isPoolToken`** — the admin can never pull pool reserves. The only material drain vector is a malicious UUPS upgrade.
- **AMM math (PASS).** No-fee constant product `out = reserveOut·actualIn/(reserveIn+actualIn)` ⇒ `k` preserved exactly; `out < reserveOut` structurally (no underflow); `out==0`/`<minOut` rejected. Fee-on-transfer handled Uniswap-V2-style via `_pullToken` balance-delta on input; output burn borne by recipient (reserve decremented by full `amountOut`).
- **Permissionless surface (minimal).** Only `donate` (one-way add) + views. A donor can't swap (not whitelisted) so can't profit from the price skew it creates; `minAmountOut` protects whitelisted swappers.
- **Residual = trust:** dominant `_authorizeUpgrade`; whitelist/asset curation; dependency trust (main-DAX listing oracle, V-DAO token hook-free).

**Live: dormant** — getNumPools=0 (no pools/liquidity), no swappers whitelisted (swaps impossible), VARO has POOL_CREATOR, assetAllowed={USDC,WBTC,WETH,PAXG}, mainDax=real DAX. Activates with the first V-DAO launch.

---

## Findings (RECONCILED — lead-auditor + workflow `wvrnl84j3`)

**Severity tally: 1 Critical · 3 Medium · 7 Low — ALL admin/trust/handoff or operational. ZERO permissionless-exploitable.** Workflow refuted 9 of 17 Crit/High/Med (reentrancy defeated by nonReentrant; donor-profit impossible without swap-whitelist; rounding favors the pool; no permissionless drain) — confirming the core safety.

### VDX2-C1 [Critical — admin/upgrade, deferred-handoff] `_authorizeUpgrade` IS the liquidity-safety boundary
[ValinityVDAODAX.sol:492](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L492) — `_authorizeUpgrade(address) onlyRole(ADMIN_ROLE)`, no on-contract timelock. The permanently-locked-liquidity guarantee rests **entirely** on the implementation having no withdraw path; a malicious upgrade can add a drain and pull **all** pool reserves of every V-DAO in one tx (no mempool window). The single dominant lever — more acute than for most contracts here because the liquidity is *permanent by design* (there is NO legitimate exit), so any exit added by upgrade is 100% irreversible theft. (Workflow rated this High as "governance risk not code defect"; I keep **Critical** for consistency with VSR/VYO/VCO/VARO and because the blast radius is total-liquidity-loss.) **Handoff:** migrate DEFAULT_ADMIN_ROLE + ADMIN_ROLE atomically to governance + external TimelockController with a real upgrade delay; renounce the EOA.

### VDX2-M1 [Medium — admin/trust] `updateSwapWhitelist` curation / rogue-swapper MEV
[ValinityVDAODAX.sol:386](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L386) — swaps are gated to the whitelist and carry **no AMM fee**. A whitelisted swapper **cannot drain reserves** (k preserved), but a *rogue* admin-added swapper could sandwich honest swappers/donors for MEV (front/back-run the permissionless `donate` skew, fee-free). Impact is MEV-vs-other-participants, not pool theft. (Workflow rated High; I keep **Medium** — admin-trust, no pool drain, consistent with the main-DAX swap-whitelist watchlist + VGO-M3.) **Handoff:** freeze the whitelist to audited contracts (the MEV bot) only; never add an unvetted swapper. Live: none whitelisted.

### VDX2-M2 [Medium — admin/trust] `updateAssetAllowed` poison-asset
[ValinityVDAODAX.sol:396](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L396) — admin allows non-VDAO asset legs. A malicious/odd allowed asset (extreme-FoT, conditional-revert, rebasing, callback) could brick its own pool's swaps or skew its accounting. **Confirmed contained:** each pool is *isolated* (no shared basket, unlike the main DAX), `addPool` is VARO/admin-only, all externals are `nonReentrant`, and balance-delta + checks-effects-interactions (output transfer after reserve update) defeat reentrancy/standard-FoT — so the workflow downgraded this from "callback exploit" to contained-pool griefing/DoS. **Handoff:** curate `assetAllowed` to vetted assets (live: USDC/WBTC/WETH/PAXG).

### VDX2-M3 [Medium — by-design assumption, NEW from workflow] Output-leg uses fixed decrement, not balance-delta
[ValinityVDAODAX.sol:324-338](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L324) — the **input** leg books the true received amount (`_pullToken` balance-delta), but the **output** leg decrements `reserveOut` by the full `amountOut` and does a plain `safeTransfer` without re-measuring. **Correct for recipient-side-FoT or no-FoT** (every current token: USDC/WBTC/WETH/PAXG + the V-DAO's recipient-side 0.7% burn) — the documented assumption "the burn is borne by the recipient, not the pool." It would **desync** reserves only for a *non-standard sender-side / bidirectional-FoT* token (the contract's balance drops by more than `amountOut`), after which later swaps price off an inflated reserve. Gated entirely by `assetAllowed`/listing curation (VDX2-M2); there is **no runtime `reserve==balance` check** (balance-delta auto-corrects on the next use of that token as *input*; admin can `setPoolSwapPaused` to quarantine). **Handoff:** document the "recipient-side-FoT only" assumption; never whitelist a sender-side-FoT token; optionally add output-side balance-delta on a future upgrade. (Subsumes the workflow's two dependent Lows — "multi-swap compounding" + "no runtime invariant check.")

### VDX2-L1 [Low] `donate` permissionless price-skew (no profit path)
[ValinityVDAODAX.sol:356](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L356) — anyone can donate to any pool, shifting its price toward the donated side. One-way (add-only) so it can't drain; a donor can't swap (not whitelisted) so can't directly profit from the skew. Could grief by skewing before a whitelisted swap, but `minAmountOut` protects the swapper. Net effect = a gift. Low; confirm no indirect-profit path (e.g. via the main-DAX VY/V-DAO pool or an external venue) in the workflow.

### VDX2-L2 [Low] Direct (non-`donate`) transfers of a pool token are permanently stuck
A pool token sent directly to the contract (not via `donate`/swap) increases balance but not reserve, and `rescueTokens` reverts on `isPoolToken` — so it's locked forever. Safer than a rescue-skim (deliberate); a footgun for the sender only. Info/Low.

### VDX2-L3 [Low — by-design] `mainDax.hasPool` is a creation-time-only listing check
The listing rule is enforced only at `addPool`; if a V-DAO's main-DAX VY pool is later removed, the VDAO-DAX pool keeps trading. By design — the admin can `setPoolSwapPaused` to quarantine such a pool ([:416](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L416)). Operational note.

### VDX2-L4 [Low — handoff] DEFAULT_ADMIN + ADMIN on same address
[ValinityVDAODAX.sol:145-146](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L145) — migrate BOTH atomically at handoff (folds into C1).

### VDX2-L5 [Low — NEW from workflow] `donate` has no pause guard
[ValinityVDAODAX.sol:356](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L356) — `donate` lacks `whenSwapsNotPaused`. While swaps are paused, a donor can still skew a pool's price (one-way add) with no way to swap it back until unpause. No value loss (add-only, reserves stay locked); purely a transient price-skew during a pause. Optional: add a pause guard on `donate`.

### VDX2-L6 [Low — separation of duties, NEW from workflow] `addPool` also callable by ADMIN
[ValinityVDAODAX.sol:236-239](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L236) — `addPool` accepts `POOL_CREATOR_ROLE` **or** `ADMIN_ROLE`. Design intent is VARO-only pool creation; ADMIN can also create pools (no code vuln, governance-process ambiguity). **Handoff:** policy that pool creation goes through VARO, or drop ADMIN from the check on a future upgrade.

### VDX2-L7 [Info — design gap, NEW from workflow] No runtime reserve==balance invariant assertion
The contract never asserts `reserve == pool-attributed balance` (line 324 comment states the intent only). In practice balance-delta accounting auto-corrects on the next input-side use and the admin can quarantine via `setPoolSwapPaused`; relevant only under the VDX2-M3 non-standard-FoT precondition. Recommend an off-chain reserve-vs-balance monitor. (Same root as M3.)

---

## Handoff checklist (surfaced for governance — not VDAO-DAX bugs)
1. Migrate DEFAULT_ADMIN_ROLE + ADMIN_ROLE together to governance + external timelock with an upgrade delay; renounce the EOA (VDX2-C1, L4). The upgrade lever IS the liquidity boundary — strongest control required.
2. Freeze `swapWhitelist` to audited contracts (the MEV bot) before lock (VDX2-M1).
3. Curate `assetAllowed` to vetted assets (VDX2-M2).
4. `mainDax` is init-only immutable (✅ strength — confirm it equals the real ValinityDAX `0xD256C672`, verified live).
5. Dependency trust: the V-DAO token must be hook-free (plain ERC20+Permit+Burnable, no reentrancy callback) — audit when the V-DAO factory/token is audited.
