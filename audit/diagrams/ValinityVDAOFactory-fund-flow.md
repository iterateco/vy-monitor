# ValinityVDAOFactory (+ ValinityVDAO token) — Launch / Supply Circuit

**Factory** UUPS proxy `0x5C92f6Cd…2B39` → impl `0x6a7a847a…1a28`. **Token** `ValinityVDAO` — immutable, CREATE2-deployed per launch (no standalone deployment; none launched yet). Source==live **PROVEN**: live factory-impl metadata-IPFS == deployment-json deployedBytecode == workspace `.sol` keccak256 for BOTH files. ⚠️ The workspace is git-`M` (deployed from uncommitted edits — *workspace* IS as-deployed; HEAD `a85f449` is behind). solc 0.8.27 / runs=100 / cancun.

> **Convention:** non-admin paths only; admin/upgrade in the trust box. "Value" here is V-DAO tokens (a creator's own asset) — neither contract holds VY/USDC/asset or any protocol funds.

The factory is the **sole deployer + source-of-truth** for V-DAO tokens. The tokens it mints are **fully immutable** (no admin/owner/upgrade). This audit's purpose: **confirm the token behaves as the already-completed DEX audits assumed.**

## Launch circuit (VARO_ROLE only)

```
 VARO ──factory.launch(baseName,baseSymbol,activeSupply,creator,logoCID,parent,layer)── [onlyRole VARO_ROLE]
   │  previewNames → derive final name/symbol (base verbatim | layer: "{name} {parent.symbol()} L{d}" / "{symbol}L{d}")
   │  FCFS uniqueness: require !nameTaken && !symbolTaken ; then reserve both        (single authority)
   │  salt = keccak256("VALINITY_VDAO", creator)
   ▼
   new ValinityVDAO{salt}(name,symbol,activeSupply,creator,logoCID, varo=msg.sender, veo, mainDax)   [CREATE2]
        │  constructor mints TOTAL = 2 × activeSupply (no other mint path, ever):
        │    activeSupply ──▶ factory (msg.sender)            ── the tradeable half
        │    activeSupply ──▶ address(this)  [LOCKED]         ── 1-yr linear creator vest
        │  feeExempt (frozen, no setter) = {factory, address(this), varo, veo, vdax=mainDax}
        ▼
   factory ──transfer(activeSupply)──▶ VARO   (factory exempt ⇒ no burn)  ── VARO runs the 45/45/10 launch split
```

## Token supply / fee / vesting circuit (ValinityVDAO — immutable)

```
 SUPPLY (fixed at construction; only ever shrinks):
   totalSupply₀ = 2 × activeSupply        (no mint function; burns reduce it)

 0.7% TRANSFER FEE → BURN  (_update):
   exempt(from) OR exempt(to) OR mint/burn  ──▶ full transfer, no fee
   else: fee = value·70/10000 ; burn `fee` from `from` (→address(0)) ; transfer `value−fee` from→to
   ⇒ RECIPIENT-SIDE: sender's balance drops by EXACTLY `value`; recipient gets `value−fee`
      (∴ a non-exempt DEX sending `amountOut` has balance drop by exactly amountOut → reserve stays in sync  ✅ discharges VDAO-DAX-M3)
   NO transfer hooks / external calls / ERC777 callbacks  ✅ (DEX no-reentrancy assumption holds)

 CREATOR VEST (locked half → creator only):
   vestedTotal() = min(vestTotal, vestTotal·elapsed/VEST_DURATION)        [linear, 1 year]
   claimVested()  [creator-only] : amount = vestedTotal − vestClaimed ; vestClaimed += amount (CEI) ; _transfer(this→creator)  [exempt ⇒ no burn]
       ⇒ cumulative claimed ≤ vestTotal (no over-claim) ; only the immutable `creator` can pull ; no reentrancy (no hooks)
```

## Exit-destination ledger (closed-circuit proof)

| Exit | Token | Destination | Class |
|---|---|---|---|
| `launch` post-mint forward | V-DAO | VARO (`msg.sender` = VARO_ROLE caller) | protocol-determined |
| `claimVested` | V-DAO | `creator` (immutable) | hardcoded, creator-only |
| 0.7% fee | V-DAO | `address(0)` (burn) | hardcoded |
| ~~admin sweep / rescue / arbitrary transfer~~ | — | — | **none exist** |

**Neither contract holds protocol funds (VY/USDC/asset).** The only value is V-DAO tokens; the active half goes to VARO, the locked half goes only to the immutable creator, the fee burns. **No arbitrary-recipient path. CLOSED.**

## Trust surface (admin / upgrade — excluded from the atomic proof)

| Lever | Role | Blast radius |
|---|---|---|
| **factory `_authorizeUpgrade`** | DEFAULT_ADMIN_ROLE | **DOMINANT.** A malicious upgrade changes how **FUTURE** V-DAOs are minted (bake an attacker as fee-exempt, mint extra to attacker, weaponize the post-mint forward). **Already-deployed tokens are immutable** (unaffected). No timelock. |
| `setVeo` / `setMainDax` | DEFAULT_ADMIN_ROLE | re-points the PERMANENT exempt wiring baked into **future** tokens — a wrong value exempts an attacker on all future V-DAOs or breaks the main-DAX-exempt invariant. |
| `setVaro` | DEFAULT_ADMIN_ROLE | rotates VARO_ROLE (who may launch). |
| **token: NONE** | — | the deployed `ValinityVDAO` has **no admin/owner/upgrade/setter** — fully immutable, exempt set frozen at construction. |

## Live state (today)
- Factory wired + ready: admin (DEFAULT_ADMIN_ROLE)=KMS `0x8310eA7E`, VARO_ROLE=`0x514F0ABf` (real VARO), `veo`=`0x48C88B80`, `mainDax`=`0xD256C672`.
- **No V-DAO launched yet** (VARO dormant, VDAO-DAX getNumPools=0). The first T4 launch / VGC bootstrap mints the first token.
- ⚠️ Workspace VARO `.sol` shows `M`, but the **live VARO impl `0xeC4B6401` is unchanged** = the audited bytecode → prior VARO audit holds; re-audit only on a VARO redeploy.

**Verdict (RECONCILED, workflow `wg9tl6qlr` — 12 agents, 5 dims; 49 raw → 3 surv / 3 ref / 43 Low-Info · 1 Crit / 1 High / 1 Med / 4 Low-Info, ALL admin-trust/handoff or operational, ZERO permissionless-exploitable):** ✅ **CLOSED / no fund leak** — the token is fully immutable with no arbitrary-recipient path; the factory holds V-DAO only transiently and forwards the active half to VARO; the vest releases only to the immutable creator. **The three load-bearing properties are CONFIRMED in code** (recipient-side fee — sender drops exactly `value`; hook-free `_update`; main-DAX-exempt / VDAO-DAX-not) ⇒ **VDAO-DAX-M3 and the DEX no-reentrancy assumption are DISCHARGED.** Supply (exactly 2× activeSupply, only-shrinks) + vesting (linear, capped, CEI, creator-only, no over-claim) sound. Residual = **factory admin/upgrade trust** (C1 dominant `_authorizeUpgrade`; H1 `setVeo`/`setMainDax` weaponize future-token exemptions — both FUTURE-tokens-only, deployed tokens frozen) + a tokenomics note (M1 creator vest = 50% of max supply over 1yr, transparent on-chain, touches only the creator's own token + the launcher's own seeded liquidity — not protocol VY/backing). See `findings/ValinityVDAOFactory.md`.
