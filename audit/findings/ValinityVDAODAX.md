# ValinityVDAODAX — Findings

**Address:** UUPS proxy `0x37Cd61b3EF849805E598023f8C14bFcafE5f222E` → impl `0xe2883b425168F1FFf70E1F4cED3bB2cC86b288dc`.
**Source==live:** PROVEN by metadata-IPFS-hash equality + per-file source keccak256 (`.sol` + interface byte-identical, git-clean HEAD `a85f449`). solc 0.8.27 / runs=100 / cancun.
**Status:** ⏳ preliminary — awaiting workflow `wvrnl84j3`.

## Summary

A small (495 ln), clean constant-product AMM holding the **second leg** of every V-DAO's liquidity (asset/V-DAO + V-DAO/V-DAO pools). Sibling of the main ValinityDAX, but pairs **arbitrary** tokens and is structurally **simpler and stronger**:

- **#1 Locked-liquidity (PASS).** **No LP token, no deposit/withdraw/remove/collect/skim path.** Pool reserves can only grow (`addPool` seed, `donate`, swap input) or shrink via a **value-conserving, k-preserving swap** (`swapExactIn`, whitelist-gated). `rescueTokens` **reverts on any `isPoolToken`** — the admin can never pull pool reserves. The only material drain vector is a malicious UUPS upgrade.
- **AMM math (PASS).** No-fee constant product `out = reserveOut·actualIn/(reserveIn+actualIn)` ⇒ `k` preserved exactly; `out < reserveOut` structurally (no underflow); `out==0`/`<minOut` rejected. Fee-on-transfer handled Uniswap-V2-style via `_pullToken` balance-delta on input; output burn borne by recipient (reserve decremented by full `amountOut`).
- **Permissionless surface (minimal).** Only `donate` (one-way add) + views. A donor can't swap (not whitelisted) so can't profit from the price skew it creates; `minAmountOut` protects whitelisted swappers.
- **Residual = trust:** dominant `_authorizeUpgrade`; whitelist/asset curation; dependency trust (main-DAX listing oracle, V-DAO token hook-free).

**Live: dormant** — getNumPools=0 (no pools/liquidity), no swappers whitelisted (swaps impossible), VARO has POOL_CREATOR, assetAllowed={USDC,WBTC,WETH,PAXG}, mainDax=real DAX. Activates with the first V-DAO launch.

---

## Findings (preliminary — to be reconciled with workflow)

### VDX2-C1 [Critical — admin/upgrade, deferred-handoff] `_authorizeUpgrade` is the liquidity-safety boundary
[ValinityVDAODAX.sol:492](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L492) — `_authorizeUpgrade(address) onlyRole(ADMIN_ROLE)`, no on-contract timelock. The permanently-locked-liquidity guarantee rests **entirely** on the implementation having no withdraw path; a malicious upgrade can add a drain and pull **all** pool reserves of every V-DAO. This is the single dominant lever (more than for most contracts here, because the liquidity is *permanent* — there is no legitimate exit by design, so any exit added by upgrade is pure theft). **Handoff:** migrate DEFAULT_ADMIN_ROLE + ADMIN_ROLE atomically to governance + external TimelockController with a real upgrade delay; renounce the EOA.

### VDX2-M1 [Medium — admin/trust] `updateSwapWhitelist` curation
[ValinityVDAODAX.sol:386](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L386) — swaps are gated to the whitelist. Swaps are value-conserving (k preserved, no free drain), so a whitelisted swapper cannot steal reserves; but it can arbitrage/sandwich the pools (extracting price-skew value vs other venues) and is the only party that can move reserves at all. **Handoff:** freeze the whitelist to audited contracts (the MEV bot) before lock; never add an unvetted swapper. Live: none whitelisted.

### VDX2-M2 [Medium — admin/trust] `updateAssetAllowed` poison-asset
[ValinityVDAODAX.sol:396](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L396) — admin allows non-VDAO asset legs. A malicious/odd allowed asset (extreme-FoT, conditional-revert, reentrant, rebasing) could brick its own pool's swaps or skew accounting. Each pool is **isolated** (no shared basket, unlike the main DAX), so blast radius is contained to that pool. `addPool` is still VARO/admin-only and balance-delta accounting handles standard FoT. **Handoff:** curate `assetAllowed` to vetted assets (live: USDC/WBTC/WETH/PAXG). Confirm cross-pool isolation in the workflow.

### VDX2-L1 [Low] `donate` permissionless price-skew (no profit path)
[ValinityVDAODAX.sol:356](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L356) — anyone can donate to any pool, shifting its price toward the donated side. One-way (add-only) so it can't drain; a donor can't swap (not whitelisted) so can't directly profit from the skew. Could grief by skewing before a whitelisted swap, but `minAmountOut` protects the swapper. Net effect = a gift. Low; confirm no indirect-profit path (e.g. via the main-DAX VY/V-DAO pool or an external venue) in the workflow.

### VDX2-L2 [Low] Direct (non-`donate`) transfers of a pool token are permanently stuck
A pool token sent directly to the contract (not via `donate`/swap) increases balance but not reserve, and `rescueTokens` reverts on `isPoolToken` — so it's locked forever. Safer than a rescue-skim (deliberate); a footgun for the sender only. Info/Low.

### VDX2-L3 [Low — by-design] `mainDax.hasPool` is a creation-time-only listing check
The listing rule is enforced only at `addPool`; if a V-DAO's main-DAX VY pool is later removed, the VDAO-DAX pool keeps trading. By design — the admin can `setPoolSwapPaused` to quarantine such a pool ([:416](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L416)). Operational note.

### VDX2-L4 [Low — handoff] DEFAULT_ADMIN + ADMIN on same address
[ValinityVDAODAX.sol:145-146](../asdeployed/ValinityVDAODAX/contracts/dex/ValinityVDAODAX.sol#L145) — migrate BOTH atomically at handoff (folds into C1).

---

## Handoff checklist (surfaced for governance — not VDAO-DAX bugs)
1. Migrate DEFAULT_ADMIN_ROLE + ADMIN_ROLE together to governance + external timelock with an upgrade delay; renounce the EOA (VDX2-C1, L4). The upgrade lever IS the liquidity boundary — strongest control required.
2. Freeze `swapWhitelist` to audited contracts (the MEV bot) before lock (VDX2-M1).
3. Curate `assetAllowed` to vetted assets (VDX2-M2).
4. `mainDax` is init-only immutable (✅ strength — confirm it equals the real ValinityDAX `0xD256C672`, verified live).
5. Dependency trust: the V-DAO token must be hook-free (plain ERC20+Permit+Burnable, no reentrancy callback) — audit when the V-DAO factory/token is audited.
