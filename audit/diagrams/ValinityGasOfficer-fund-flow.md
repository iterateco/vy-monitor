# ValinityGasOfficer (VGO) — Keeper-Reward Engine · mints VGC · **RE-AUDIT (curve+tip v5, now LIVE)**

> ⚠️ **This OVERWRITES the prior VGO audit** (impl `0x7c35d9d7`, fixed-1.25× model, DORMANT). Same proxy, **UPGRADED IN-PLACE** (`reinitializer(5)` / `initializeRewardsV2`) to the **premium-on-base-fee + capped-tip + decay-curve** model → impl **`0x70F44166…`** (8,090 B). **TWO MAJOR STATE CHANGES:** (1) the prior **blocking VGO-H1 is RESOLVED** — `VCO.OFFICER_ROLE(VGO) = FALSE` on-chain (revoked); (2) VGO is now **LIVE/ACTIVE** — VGC wired (`minter()==VGO`), `isPayoutReady=true`, **59 RewardPaid events**.

Proxy `0x0a6C2117…E827` → UUPS impl **`0x70F44166…`**. A **keeper-reward engine**: a roled officer brackets its own permissionless poke with `beginReward()` … `payReward(keeper)`, and VGO mints the keeper a **base-fee premium (7×→1.25× decay) + a capped 1:1 tip**, in **VGC** (a separate gas-credit/governance token VGO is the *sole locked minter* of). Source==live **PROVEN** (live impl metadata-IPFS `1220db78d6…` == hardhat artifact == build-info `c3d525c0` compile of workspace `ValinityGasOfficer.sol`, keccak `0xd21acfdd…` match). solc 0.8.27 / runs=100 / cancun.

> **De-risking holds + extended.** VGO touches **no VY custody and no VCO caps** (`vyt`/`vco`/`vy`/`weth` are inert legacy slots; VCO.OFFICER now revoked). It only mints VGC, **hard-bounded by VGC's own per-epoch ceiling** (enforced inside the VGC token — proven sound in the VGC audit). The reward formula changed from a flat 1.25× to: `min( gasUsed · (baseFee·mult + min(tip, tipCap)), maxRewardPerCallWei )`.

## Flow — `beginReward()` / `payReward(keeper)` (both OFFICER_ROLE) — admin functions EXCLUDED

```
 officer (OFFICER_ROLE) ── beginReward() ──▶ VGO   [tstore gasleft() snapshot @ keccak(seed, msg.sender)]
        │  …officer runs its permissionless poke (the metered span)…
 officer ── payReward(keeper) ──▶ VGO   [OFFICER_ROLE, nonReentrant]
        │   load+clear transient gasStart (revert NoBeginReward if 0); revert VgcNotWired if vgc==0
        │   gasUsed   = gasStart − gasleft() + 21000 + finalOverheadGas
        │   premBase  = min(block.basefee, maxBaseFeeWei|∞)               (premium leg; live cap=0 ⇒ uncapped)
        │   tip       = min(tx.gasprice − block.basefee, tipCapWei)       (capped 1:1; keeper's only input)
        │   mult      = floor + (max−floor)·unminted/REWARD_POOL          (7×→1.25× by VGC supply; monotonic↓, clamped)
        │   perGasWei = mulDiv(premBase, mult, BPS) + tip
        │   ethValue  = min( gasUsed · perGasWei , maxRewardPerCallWei )  ◀ ABSOLUTE per-call cap (0.005 ETH); return if 0
        │   vgcAmount = _quoteVgcForWeth(ethValue)                        (2-hop DAX SPOT mid-price; return if 0)
        │        WETH→VY  via wethPoolId   (rVYw / rWeth)
        │        VY→VGC   via vgcVyPoolId  (rVGC / rVYv)
        └── vgc.mint(keeper, vgcAmount)   ──▶ keeper                 ◀ the ONLY value creation
                                          (DOUBLE-bounded: per-call cap AND VGC's per-epoch ceiling)
```

## Value flow — VGO custodies no user funds, pulls no VY
| Movement | Destination | Controllable? | Bound |
|---|---|---|---|
| **VGC minted** | `keeper` (supplied by the calling OFFICER) | officer-supplied (officers are audited) | per-call cap `maxRewardPerCallWei` (0.005 ETH) **AND** VGC per-epoch ceiling (kill-switch) |
| ETH dust | `rescueEth(to)` | ADMIN, arbitrary `to` | VGO holds ~dust |
| stray ERC20 | `rescueToken(to)` | ADMIN, arbitrary `to` | VGO holds ~none |

**No principal to drain.** The only value VGO creates is minted VGC. Even a fully malicious VGO upgrade is contained to VGC emission within the VGC epoch ceiling — it **cannot** touch VY, reserves, or caps (no VY custody, VCO.OFFICER revoked). The reward premium rides on `block.basefee` only (keeper-unmanipulable); the tip is reimbursed ≤1:1 and capped ⇒ **no overpay incentive**.

## Access model
```
 PERMISSIONLESS: none (beginReward/payReward are OFFICER_ROLE; the officer's OWN poke is what's permissionless)
 OFFICER_ROLE (live 5 holders, ALL audited officers): VBBO 0x4B97D45d, VAO 0x7a0E5824, VMB 0x6f2F4580,
                                                       VARO 0x514F0ABf, VFO 0x79A9028…  → beginReward / payReward(keeper)
 ADMIN_ROLE (0x8310eA7E → governance):
   ├─ _authorizeUpgrade   ⚠ DOMINANT — sole VGC minter; BUT blast radius capped by VGC epoch ceiling (no VY exposure)
   ├─ wireVgc             (re)discover both quote-pool ids + set vgc (mint target + price source)
   ├─ setMultiplierBand   hard-bounded to [1.25×, 7×]; floor ≤ max
   ├─ setTipCapWei / setMaxRewardPerCallWei / setMaxBaseFeeWei   reward knobs (can only LOWER payout, never overpay)
   └─ rescueEth / rescueToken   arbitrary `to` (dust)
 SOLE LOCKED MINTER of VGC (the per-epoch ceiling lives in VGC — the emission cap + kill-switch).
```

## Live state (today)
- impl `0x70F44166…`; **LIVE** (`isPayoutReady=true`, 59 RewardPaid events). vgc `0xe595309a` (minter==VGO ✅), dax(private) `0xD256C672…`, wethPoolId 0, vgcVyPoolId 3.
- maxMultBps 70000 (7×), floorMultBps 12500 (1.25×), tipCapWei 25 gwei, maxRewardPerCallWei 0.005 ETH, finalOverheadGas 120000, maxBaseFeeWei 0, currentMult ≈ 6.999× (VGC supply 1.001M of 7M).
- VGC.epochMintBps 25 (0.25%/wk of unminted = ceiling + kill-switch). admin `0x8310eA7E`.
- **VCO.OFFICER_ROLE(VGO) = FALSE (revoked — prior VGO-H1 resolved); VYT.OFFICER_ROLE(VGO) = FALSE.**

**Verdict (RECONCILED, workflow `wu2ofpcrf`):** ✅ **No custody drain — VGO holds no user funds, pulls no VY, mutates no VCO cap; the only value creation is VGC minted to officer-supplied keepers, DOUBLE-bounded by the per-call cap AND VGC's per-epoch ceiling.** Reward math sound: decay curve monotonic + clamped, per-call cap bounds every call regardless of premium/basefee, tip capped 1:1 (no overpay), per-officer transient slot (no collision), nonReentrant. **The prior blocking VGO-H1 is RESOLVED** (VCO.OFFICER revoked). Residual is admin-trust + bounded-economic, all contained by the VGC ceiling: **_authorizeUpgrade** dominant (sole minter, but no VY blast radius); **gas-burn farming** by a compromised officer (≤ per-call cap × ceiling, not a VY drain); **spot-quote mid-price skew** by a whitelisted DAX swapper (VBBO on both, bounded). Lows: maxBaseFeeWei=0 (per-call cap is the backstop), wireVgc pool rediscovery trust, rescue dust. See `findings/ValinityGasOfficer.md`.

---

## ⚙️ Admin / governance powers — permanent at handoff (EXCLUDED from the flow above)
| Item | Where | Effect | Requirement |
|---|---|---|---|
| **Upgrade** | `_authorizeUpgrade` | replace logic; sole VGC minter | timelock + upgrade delay; migrate **both** DEFAULT_ADMIN+ADMIN then renounce. Blast radius = VGC emission only (no VY/reserve/cap exposure). |
| Activation/rewire | `wireVgc` | set vgc + quote pools (mint target + price) | timelock; re-runnable on DAX reindex |
| Premium band | `setMultiplierBand` | tune 7×→1.25× (hard-bounded [1.25×,7×]) | timelock |
| Reward knobs | `setTipCapWei`/`setMaxRewardPerCallWei`/`setMaxBaseFeeWei` | can only LOWER payout (no overpay path) | timelock; consider a non-zero `maxBaseFeeWei` |
| Rescue | `rescueEth`/`rescueToken` | arbitrary `to` (dust) | timelock |

→ See `findings/ValinityGasOfficer.md`. **VGO-H1 (revoke VCO.OFFICER_ROLE) is DONE on-chain.** Emission safety ultimately rests on the **VGC token** (sole-minter lock + per-epoch ceiling — audited ✅ `project_vgc_token`).
