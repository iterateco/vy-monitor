# ValinityVDAODAX — Atomic Fund-Flow Circuit · the V-DAO second-leg AMM

Proxy `0x37Cd61b3…f222E` → impl `0xe2883b42…288dc` (UUPS). Source==live **PROVEN** by metadata-IPFS-hash equality (deployment-json deployedBytecode meta == live impl) + per-file source keccak256 (`.sol` + interface byte-identical, git-clean HEAD `a85f449`). solc 0.8.27 / runs=100 / cancun. 495 ln.

> **Convention:** non-admin / permissionless paths only. Admin/upgrade powers in the separate trust box.

Sibling of the main **ValinityDAX**: a private, VY-agnostic **constant-product AMM (no AMM fee)** pairing **arbitrary** tokens. It holds the **second leg** of every V-DAO launch (asset/V-DAO and V-DAO/V-DAO pools); the main DAX simultaneously holds the VY/V-DAO leg. **The defining property: liquidity is permanently LOCKED — there is no LP token and no withdraw/remove/extract path.**

## Liquidity circuit (reserves can only grow or shrink-via-swap)

```
 SEED (once per pool):
   addPool(tokenA,tokenB,amtA,amtB)  ── POOL_CREATOR_ROLE (VARO) | ADMIN ──▶ pulls both seeds (balance-delta, FoT-safe)
        listing rule per leg: assetAllowed[t]  OR  mainDax.hasPool(t)==true     (else LegNotListed)
        canonical token0<token1 ; pairKey dedup (PoolAlreadyExists) ; reserves != 0 ; NO LP token minted

 GROW (one-way, add-only):
   donate(poolId, token, amount)  ── PERMISSIONLESS ──▶ reserve[token] += received   (balance-delta; can only ADD)
   swapExactIn input leg          ── reserveIn  += actualIn

 SHRINK (the ONLY exit for pool reserves):
   swapExactIn(poolId, tokenIn, amountIn, minOut, recipient)  ── onlySwapWhitelisted ──▶
        out = reserveOut · actualIn / (reserveIn + actualIn)        (no fee ⇒ k = reserveIn·reserveOut preserved EXACTLY)
        out < reserveOut structurally (no underflow) ; out==0 reverts ; out<minOut reverts (SlippageExceeded)
        reserveIn += actualIn ; reserveOut -= out ; safeTransfer(tokenOut, recipient, out)   [recipient bears any output-burn]

 ✗ NO deposit · NO withdraw · NO remove · NO collect/skim · NO LP redemption · NO admin extraction of pool tokens
```

## Exit-destination ledger (the closed-circuit proof)

| Exit | Token | Destination | Class |
|---|---|---|---|
| `swapExactIn` output | tokenOut | caller-supplied `recipient` | swap-whitelisted only; **value-conserving** (paid `actualIn` for `out`, k preserved) |
| `rescueTokens` | non-pool token | admin `to` | ADMIN; **reverts on any `isPoolToken`** ⇒ pool reserves untouchable |
| ~~deposit/withdraw/remove/skim~~ | — | — | **do not exist** |

**Pool reserves can leave only through a value-conserving swap by a whitelisted caller.** No free extraction (you pay input for output). `donate` is add-only. `rescueTokens` cannot touch pool tokens. ⇒ **CLOSED / liquidity permanently locked, relative to roles.**

## Trust surface (admin / upgrade — excluded from the atomic proof)

| Lever | Role | Blast radius |
|---|---|---|
| `_authorizeUpgrade` | ADMIN_ROLE | **DOMINANT.** The locked-liquidity guarantee rests *entirely* on the impl having no withdraw path — a malicious upgrade can add one and pull ALL pool reserves. No on-contract timelock. |
| `updateSwapWhitelist` | ADMIN_ROLE | adds swappers. Swaps are value-conserving (no free drain), but a whitelisted swapper can sandwich/arbitrage the pools. Curate to audited contracts (the MEV bot). |
| `updateAssetAllowed` | ADMIN_ROLE | allows a non-VDAO asset leg. A poison/odd asset (extreme-FoT, reverting, reentrant) could brick its own pool. addPool is still VARO/admin-only. Curate. |
| `updatePauseStatus` / `setPoolSwapPaused` | ADMIN_ROLE | DoS only — freeze swaps / pool-creation / a single pool. **Cannot touch reserves.** |
| `rescueTokens` | ADMIN_ROLE | non-pool tokens only (`isPoolToken` block). Accidental/foreign tokens recoverable; pool liquidity is not. |

**Init-only immutable (NO setter):** `mainDax` (the listing-rule anchor). **No deposit/withdraw/remove/LP anywhere.**

## Live state (today) — DORMANT (no liquidity)
- **getNumPools=0** — no pools, no liquidity. `poolCreationPaused`=false, `swapsPaused`=false.
- `mainDax`=`0xD256C672` (= live ValinityDAX ✅). admin (DEFAULT_ADMIN+ADMIN)=KMS `0x8310eA7E`.
- VARO `0x514F0ABf` = **POOL_CREATOR_ROLE TRUE** (granted; can create pools). `assetAllowed`={USDC,WBTC,WETH,PAXG}.
- **No swappers whitelisted** (VARO/MEVBot/VEO all false) ⇒ swaps currently impossible. Activates with the first V-DAO launch.

**Verdict (pending workflow `wvrnl84j3`):** ✅ **CLOSED / liquidity permanently locked relative to roles** — pool reserves can only leave via a value-conserving, whitelist-gated, k-preserving swap; `donate` is add-only; `rescueTokens` blocks all pool tokens; there is no deposit/withdraw/remove/LP path. AMM math is no-fee constant-product with Uniswap-V2-style balance-delta (FoT-safe) accounting. Entire material residual = **admin/upgrade trust** (dominant `_authorizeUpgrade` — for a permanently-locked-liquidity DEX, the upgrade lever IS the liquidity-safety boundary) + whitelist/asset curation + dependency trust (main-DAX listing oracle, V-DAO token assumed hook-free).
