# ValinityGasOfficer (VGO) — Keeper-Reward Engine · mints VGC · **BRAND-NEW redesign**

Proxy `0x0a6C2117…E827` → UUPS impl **`0x7c35d9d7…`** (V4 keeper-reward redesign, upgraded in place over the V3 layout; `reinitializer(4)`). A **keeper-reward engine**: a roled officer brackets its own permissionless poke with `beginReward()` … `payReward(keeper)`, and VGO mints the keeper **1.25× the base-fee gas cost** of that call in **VGC** (a separate gas-credit token VGO is the *sole locked minter* of). Source==live **PROVEN** by metadata-hash (build-info `d7b281e8` compiled the as-deployed source — byte-identical to the dirty workspace `.sol`, keccak `0xa08a0dcf…` — to deployedBytecode metadata IPFS `1220552ad640…` == live impl; solc 0.8.27/runs=100/cancun).

> **🔁 Complete redesign + major de-risking.** The prior VGO pulled VY / touched VCO caps. The new VGO does **none of that** — `vyt`/`vco`/`vy`/`weth` are now **inert legacy storage slots, never read**. It only mints VGC to keepers. **BUT:** the old `VCO.OFFICER_ROLE` grant **was NOT revoked on-chain** (still `true`) even though the comment says "revoked at upgrade (dead)" — see the watchlist box.
>
> **Reward engine is DORMANT live:** `vgc = address(0)` → `payReward` reverts `VgcNotWired`; `isPayoutReady = false`. No VGC is mintable until an admin calls `wireVgc`.

## Flow — `beginReward()` / `payReward(keeper)` (both OFFICER_ROLE)

```
 officer (OFFICER_ROLE) ── beginReward() ──▶ VGO   [tstore gasleft() snapshot @ keccak(seed, msg.sender)]
        │  …officer runs its permissionless poke (the metered span)…
 officer ── payReward(keeper) ──▶ VGO   [OFFICER_ROLE, nonReentrant]
        │   load+clear transient gasStart (revert NoBeginReward if 0)
        │   baseFee = min(block.basefee, maxBaseFeeWei|∞)            (tip ignored; cap=0 ⇒ no cap)
        │   gasUsed = gasStart − gasleft() + 21000 + finalOverheadGas
        │   ethValue = gasUsed · baseFee · 1.25                      (rewardMultipleBps/BPS; return if 0)
        │   vgcAmount = _quoteVgcForWeth(ethValue)                   (2-hop DAX SPOT mid-price; return if 0)
        │        WETH→VY  via wethPoolId   (rVYw / rWeth)
        │        VY→VGC   via vgcVyPoolId  (rVGC / rVYv)
        └── vgc.mint(keeper, vgcAmount)   ──▶ keeper                 ◀ the ONLY value creation
                                          (bounded by VGC's per-epoch mint ceiling — enforced inside VGC)
```

## Value flow — VGO custodies no user funds
| Movement | Destination | Controllable? | Bound |
|---|---|---|---|
| **VGC minted** | `keeper` (supplied by the calling OFFICER) | officer-supplied (officers are trusted) | 1.25× metered gas·baseFee, priced via DAX spot; **globally capped by VGC's per-epoch mint ceiling** (the kill-switch) |
| ETH dust | `rescueEth(to)` | ADMIN, arbitrary `to` | VGO holds ~0.0000127 ETH |
| stray ERC20 | `rescueToken(to)` | ADMIN, arbitrary `to` | VGO holds ~none |

**VGO holds no user funds and pulls no VY.** The only value it creates is minted VGC; there is no principal to drain. The real exposure is **VGC *emission*** (not custody), gated by OFFICER_ROLE callers + the VGC epoch ceiling.

## Access model
```
 PERMISSIONLESS: none (beginReward/payReward are OFFICER_ROLE; the officer's own poke is what's permissionless)
 OFFICER_ROLE (live: VLM 0x920AbB09, VBBO 0x4B97D45d, 0x7a0E5824): beginReward / payReward(keeper)
 ADMIN_ROLE (0x8310eA7E → governance):
   ├─ _authorizeUpgrade   ⚠ DOMINANT — and amplified by the STILL-HELD VCO.OFFICER_ROLE (an upgrade could call vco.increaseAssetCap)
   ├─ wireVgc             activation switch: sets vgc + discovers both quote-pool ids (controls mint target + price)
   ├─ setMaxBaseFeeWei    base-fee cap (live 0 = uncapped)
   ├─ rescueEth / rescueToken   arbitrary `to` (dust only)
   └─ (rewardMultiple/finalOverhead: NO runtime setter — re-tune = re-upgrade)
 SOLE MINTER of VGC (the per-epoch ceiling lives in VGC, the emission cap + kill-switch).
```

## Live state (today)
- impl `0x7c35d9d7`; **DORMANT** (`vgc=0`, `isPayoutReady=false`). dax(private) `0xD256C672616f…`, wethPoolId 3, rewardMultipleBps 12500 (1.25×), maxBaseFeeWei 0, finalOverheadGas 120000.
- OFFICER_ROLE: VLM, VBBO, `0x7a0E5824`. admin `0x8310eA7E`. ETH dust ~0.0000127.
- **VCO.OFFICER_ROLE(VGO) = TRUE (not revoked); VYT.OFFICER_ROLE(VGO) = FALSE (revoked).**

**Verdict (RECONCILED, workflow `wdvoxe1c0` — 71 agents, 51 surv [many positive validations] / 10 ref):** ✅ **No custody drain — VGO holds no user funds and pulls no VY; the only value creation is VGC minted to officer-supplied keepers, globally capped by VGC's per-epoch ceiling.** Auth/reentrancy/storage sound (per-officer transient slot, nonReentrant, V3 layout preserved byte-for-byte, `__gap` 41→37). Major de-risking vs the prior VY/cap-touching VGO. **Single real residual blocking handoff: (H1) VCO-CC4 NOT resolved on-chain** — VGO still holds `VCO.OFFICER_ROLE` (comment says revoked; it wasn't), so an admin upgrade could weaponize it for phantom cap inflation (**the *role* is the exposure, not any signature**); **revoke `OFFICER_ROLE` from VGO on the VCO**. **(H2)** `_authorizeUpgrade` dominant lever (amplified by H1 + sole-VGC-minter). Economic (officer/DAX-trust, gated by VGC ceiling): **M1** 1.25× gas-burn farming (~+25%), **M2** VGC token unaudited (the ceiling lives there), **M3** DAX whitelisted-swapper quote-skew (VBBO on both). Engine **dormant today** (`vgc=0`) → no live emission.

---

## ⚙️ Admin / governance powers + standing actions — permanent at handoff
| Item | Where | Effect | Requirement |
|---|---|---|---|
| **Revoke `VCO.OFFICER_ROLE` from VGO** | VCO (not VGO) | removes the upgrade-weaponizable cap-mutation power VGO doesn't use | **standing action — do before handoff (VCO-CC4)** |
| **Upgrade** | `_authorizeUpgrade` | replace logic; amplified by the still-held VCO role | timelock + upgrade delay; migrate **both** DEFAULT_ADMIN+ADMIN then renounce |
| Activation | `wireVgc` | sets vgc + quote pools (mint target + price) | **audit VGC + confirm DAX permissioning BEFORE calling**; timelock |
| Base-fee cap | `setMaxBaseFeeWei` | live 0 = uncapped reward scaling | consider a cap; timelock |
| Rescue | `rescueEth`/`rescueToken` | arbitrary `to` (dust) | timelock |

→ See `findings/ValinityGasOfficer.md`. The emission safety ultimately rests on the **VGC token** (sole-minter lock + per-epoch ceiling) — audit it before enabling rewards.
