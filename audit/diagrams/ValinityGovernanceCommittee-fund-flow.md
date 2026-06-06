# ValinityGovernanceCommittee (VGC) — Emission / Supply Circuit · governance + keeper-funding token

Address `0xe595309a…2c67` — **NON-PROXY, NON-UPGRADEABLE** (plain ERC20 + ERC20Permit, constructor-based; EIP-1967 impl slot empty; logic permanently frozen). VGC is both the **governance token** and the **keeper-funding token**: the **ValinityGasOfficer (VGO) is its sole minter** and rewards keepers in freshly-minted VGC ([[ValinityGasOfficer-fund-flow]]). Source==live **PROVEN** by metadata-hash (build-info `32bd69ca` → `12200f327310…` == live; byte-identical to the dirty workspace, keccak `0x80d4213d…`; solc 0.8.27/runs=100/cancun).

> **Convention:** VGC is a token, not a fund vault — this diagram shows the **supply/emission circuit** (who can create VGC and under what cap) and the **trust surface**, since the audit question is *emission integrity*, not where deposited funds go (there are none).

> **Credibly-fixed monetary policy:** all schedule numbers are constants; changing them needs a redeploy (and the contract is immutable). **Emission can only ever be slowed or halted by governance, never accelerated.**

## Supply / emission circuit

```
 CONSTRUCTION (one-time):
   _mint(treasury, INITIAL_SUPPLY = 1,000,000)   ──▶ treasury (live: KMS 0x8310eA7E)   [seeds VARO launch]
   admin = admin_ ; epochMintBps = MAX_EPOCH_MINT_BPS (25)

 ONGOING EMISSION (the ONLY other supply source):
   VGO (sole minter) ── mint(keeper, amount) ──▶ keeper                          ◀ minter-only (NotMinter)
        │  per-epoch ceiling (geometric on UNMINTED supply, frozen at epoch start):
        │    new epoch ⇒ unminted := MAX_SUPPLY − totalSupply() ; bps := epochMintBps ; minted := 0
        │    cap = unminted · bps / 10000      (bps ≤ 25 ⇒ ≤ 0.25%/week of unminted)
        │    available = max(cap − minted, 0) ; require amount ≤ available  (EpochLimitReached)
        │    minted += amount
        └─ totalSupply asymptotically approaches but NEVER reaches MAX_SUPPLY (7,000,000)

 NO burn · NO transfer fee · NO transfer hook · NO admin mint · NO admin balance-move · NO upgrade
```

## Trust surface (minimal)
| Power | Who | Effect | Bound |
|---|---|---|---|
| `mint(to, amount)` | **minter** (the VGO) | create VGC for keepers | ≤ epochMintBps (≤0.25%) of epoch-start unminted; 0=halt |
| `setMinter(newMinter)` | admin | set the sole minter | **ONE-TIME, irreversible** (`minterLocked`); cannot change after |
| `setEpochMintBps(bps)` | admin | tune/halt the ceiling | **≤ MAX_EPOCH_MINT_BPS (25)** — can only slow/halt, never accelerate; effective NEXT epoch |
| `transferAdmin`/`acceptAdmin` | admin / pendingAdmin | two-step admin handoff | → governance Executor |
| ~~mint / move balances / accelerate / upgrade~~ | admin | **NONE** | admin literally cannot |

**The admin's entire power is: set the minter once, and slow/halt emission.** It cannot mint, move balances, accelerate emission, or upgrade. This is the floor of the trust model — a compromised admin can only (a) halt emission (a safety feature) or (b) — *while the minter is still unset* — set the minter to a malicious address (bounded to ≤0.25%/week of unminted ≈ 17.5k VGC/week until halted).

## Live state (today)
- **NON-PROXY / immutable.** totalSupply = **1,000,000 VGC** (only the seed). MAX_SUPPLY 7M, epochMintBps 25 (max), MINT_EPOCH 7d.
- **minter = `0x0` (UNSET), minterLocked = false** ⇒ no epoch emission is possible yet (and VGO.vgc=0) — the keeper-reward path is **doubly-dormant**.
- admin = `0x8310eA7E` (KMS), pendingAdmin = 0. epoch struct all-zero.
- The 1M seed is held by `0x8310eA7E` (the constructor `treasury` = the KMS).

**Verdict (RECONCILED, workflow `w5mu2e3r7` — 73 agents, 4 surv / 61 ref · NO Critical/High/Medium):** ✅ **Emission provably bounded — a sound cap/kill-switch.** Per-epoch ceiling ≤0.25%/week of *unminted* supply (frozen at epoch start), totalSupply strictly below the 7M hard cap forever (proven by induction; `MAX_SUPPLY − totalSupply` never underflows), skipping epochs does NOT compound, uint96 packing safe, `getMintAllowance()` exactly mirrors `mint()`, `epochMintBps=0` halts. Stock OZ ERC20+Permit (no fee/burn/hook ⇒ mint `to` can't reenter). **Sole minter one-time-locked; admin can only slow/halt, never mint/move/accelerate; non-upgradeable.** This **validates the VGO dependency (VGO-M2).** Residual (all Low/operational): **L1** one-time `setMinter` activation-window admin risk (must point at the audited VGO; bounded ~17.5k VGC/wk until then), **L2** kill-switch has ~7-day latency (freeze-at-epoch-start), **L3** `transferAdmin` no zero-check (operational nit), **L4** 1M seed at the KMS (gov centralization). Reward path **dormant** today (minter unset).

---

## ⚙️ Activation / handoff requirements (the contract is immutable — these are the only levers)
| Item | Action | Note |
|---|---|---|
| **Activate emission** | `setMinter(VGO 0x0a6C2117)` — **one-time, irreversible** | must point at the **audited VGO**; pair with `VGO.wireVgc(VGC)`; verify, then it's permanent |
| Emission rate | keep `epochMintBps` sane (≤25; 0=halt available) | governance can only slow/halt |
| Admin → governance | `transferAdmin(Executor)` → `acceptAdmin()` | two-step; admin can't mint/move, so low blast radius |
| INITIAL_SUPPLY (1M) | decide disposition of the KMS-held seed | governance-centralization at handoff (= 100% of current supply) |

→ See `findings/ValinityGovernanceCommittee.md`. The token is **immutable**, so there is no upgrade lever — the only permanent decision is the one-time `setMinter`.
