# ValinityFloorOfficer (VFO) — Floor-Defense Flash Circuit · **RE-AUDIT (now PERMISSIONLESS UUPS)**

> ⚠️ **This OVERWRITES the prior VFO audit** (old addr `0x3d9d78CD…`, NON-PROXY/operator-gated). VFO was **migrated to a BRAND-NEW UUPS proxy `0x79A902864d0Bb88DD5497B9Bec593d2ffb937867`** → impl `0x33c3DD5c…` (10,853 B). All roles moved to the new proxy and **revoked from the old** (VRT.BUYBACK, VCO.OFFICER, VGO.OFFICER, VY-whitelist — verified on-chain). The redesign makes the officer **PERMISSIONLESS** (works like VBBO/VAO) with **HARDCODED routing** (no operator, no router whitelist, no caller-supplied calldata).

Proxy `0x79A9028…` → UUPS impl `0x33c3DD5c…`. The **floor officer**: when VY trades below its on-chain LTV-F backing, anyone flash-borrows USDC, the contract buys the cheap VY, retires it to VYT, releases the *exact pro-rata* collateral from VRT, sells it, repays the flash, forwards any profit to the buyback officer (VBBO), then pokes the reserve-yield rebalance. Source==live **PROVEN** (live impl metadata-IPFS `12203281df…` == hardhat artifact == build-info `c3d525c0` compile of workspace `ValinityFloorOfficer.sol`, keccak `0xc65077ba…` match; HEAD `1aa24be`). solc 0.8.27 / runs=100 / cancun.

> **PERMISSIONLESS now.** Anyone calls `executeFloor(uint256 flashAmount)`, caller pays gas. No operator, no caller swap params, no router whitelist — routing is hardcoded {UniV2 USDC/VY buy, UniV3 asset/USDC sell auto-tier}. The caller's only gain is a **bounded VGC keeper reward** from VGO; **all arbitrage profit goes to VBBO, not the caller.**

## Atomic flow (one Balancer V2 0-fee flash loan, inside `receiveFlashLoan`) — admin functions EXCLUDED

```
 anyone ──executeFloor(flashAmount)──▶ VFO     [nonReentrant, !execPaused, flashAmount!=0]
            │   (best-effort: try vgo.beginReward() — snapshot gas; failure must NOT brick the defense)
            │   tstore(_IN_FLASH_LOAN_SLOT, 1)
            ▼
   Balancer V2 Vault ── flashAmount USDC ──▶ VFO.receiveFlashLoan
            │     [GATE: msg.sender==balancerVault && tload(_IN_FLASH_LOAN_SLOT)==1, else revert]
            │     caller_ = abi.decode(userData) ── used ONLY in the event, NEVER as a recipient
            ▼
   1. USDC ──[UniV2 swapExactTokensForTokens, minOut=0]──▶ VY            vyAmount = ΔVY.balanceOf(this); revert if 0
   2. _findBestAsset(VCO): asset = largest getAssetCap (== largest headroom above effectiveFloor); revert NoHeadroom if all at floor
   3. REQUIRE vyAmount <= headroom (= cap − effectiveFloor)              else revert VyExceedsHeadroom
   4. reserve = asset.balanceOf(VRT); cap = vco.getAssetCap(asset)
      withdrawAmount = vyAmount · reserve / cap                          (contract-computed, LTV-exact; revert if 0)
   5. VY ──safeTransfer──▶ VYT          (ALL bought VY retired from circulation)              ◀── hardcoded sink (burn)
   6. VRT ── withdrawAmount of asset ──▶ VFO   [vrt.withdrawForBuyback([asset],[amt], address(this))] ◀── recipient HARDCODED = this
   7. VCO.decreaseAssetCap(asset, vyAmount)    ◀── GOLDEN RULE: cap ↓ by EXACTLY the VY-to-VYT amount (floor-guarded in VCO)
   8. asset ──[UniV3 exactInputSingle, deepest of 4 fee tiers via QuoterV2, minOut=0]──▶ USDC
   9. CLOSED-CIRCUIT INVARIANT: asset.balanceOf(this) must NOT exceed preAssetBal   else revert TokenBalanceNotZero
  10. USDC ── repayAmount (= flashAmount + 0 fee) ──▶ Balancer Vault                ◀── hardcoded repay (revert if short = self-protection)
  11. leftover USDC > 0 ? ──[UniV2 buy VY]──▶ profitVY ──safeTransfer──▶ buybackOfficer (VBBO)  ◀── hardcoded PROFIT sink (NOT caller)
  12. emit FloorExecuted(caller_, …)
  13. vryo.execute()    ◀── ⚠ NOT try/catch'd: a VRYO revert rolls back the ENTIRE defense (availability coupling — see findings M1)
            ▼
   tstore(_IN_FLASH_LOAN_SLOT, 0)
   if rewardArmed: try vgo.payReward(msg.sender) {} catch { emit KeeperRewardFailed }   ◀── caller's ONLY gain (bounded VGC)
```

## Edge ledger — every token sink is HARDCODED (no caller-supplied recipient anywhere)
| Edge | Token | Destination | Gate / note |
|---|---|---|---|
| buy VY | VY (in) | VFO (self) | UniV2, minOut=0 (atomic repay = effective slippage gate) |
| retire | VY | **VYT** | hardcoded burn sink |
| collateral release | asset | **VFO (self)** | `withdrawForBuyback(recipient=address(this))` — recipient hardcoded |
| sell collateral | USDC (in) | VFO (self) | UniV3 deepest tier, minOut=0 |
| flash repay | USDC | **Balancer Vault** | hardcoded; revert if insufficient |
| profit | VY | **buybackOfficer (VBBO)** | hardcoded; admin-set address, NOT caller |
| keeper reward | VGC | **msg.sender** | from VGO, best-effort, bounded by per-call cap + VGC ceiling |

**Closed-circuit proof (permissionless-safe):** the permissionless `caller_` is used ONLY to label the `FloorExecuted` event — it is **never a fund recipient**. Every value sink is a hardcoded protocol address {VYT, VFO-self, Balancer, VBBO}. A bad `flashAmount` (too large, or VY ≥ floor) simply **reverts** via the atomic flash-repay (caller eats gas; protocol state untouched). Sandwiching the minOut=0 swaps harms only the caller (revert) or reduces VBBO profit — it can **never** under-back the protocol because collateral release (step 6) scales 1:1 with the VY burned (step 5/7).

## Golden rule — TEXTBOOK cap-DECREASE (the cleanest backing-preserving sink)
```
 burn vyAmount VY → VYT     ==     vco.decreaseAssetCap(asset, vyAmount)      [exact same amount]
 withdrawAmount = vyAmount · reserve / cap
   ⇒ new_reserve / new_cap = (reserve − vyAmount·reserve/cap) / (cap − vyAmount) = reserve / cap   EXACTLY
   ⇒ backing ratio PRESERVED; integer floor on withdrawAmount over-backs by dust, never under-backs.
 DOUBLE-GUARDED: VFO pre-checks vyAmount ≤ headroom AND VCO.decreaseAssetCap reverts if newCap < effectiveFloor.
```

**Verdict (RECONCILED with workflow `wu2ofpcrf`):** ✅ **CLOSED relative to roles — no arbitrary-dest exfil even though executeFloor is now permissionless; golden-rule textbook-correct; 0 permissionless-exploitable leaks, 0 conservation violations.** The permissionless redesign is safe because profit→VBBO (not caller), bad sizing reverts atomically, and collateral release is rigidly proportional to VY burned. Residual: **C1** `_authorizeUpgrade` amplified by 3 roles (VRT.BUYBACK drain + VCO.OFFICER cap-mutation + VGO.OFFICER) — dominant lever, admin-trust/handoff; **M1** `vryo.execute()` un-try/catch'd → a VRYO revert/pause bricks the whole floor defense (availability coupling, inconsistent with the best-effort VGO leg); **M2** PAXG-FoT sells `withdrawAmount` not received balance → clean revert if PAXG fee active (availability only); Lows (minOut=0 self-sandwich principal-safe, rescueToken arbitrary token+dest but blocks VY, VGC keeper-budget farming bounded). See `findings/ValinityFloorOfficer.md`.

---

## ⚙️ Admin / role powers — permanent at handoff (EXCLUDED from the atomic proof above)
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| **Upgrade** | `_authorizeUpgrade` (UUPS, ADMIN_ROLE) | **#1 LEVER** — replace logic; a malicious impl can drain VRT reserves (BUYBACK_ROLE) + mutate VCO caps (OFFICER_ROLE) | codehash/timelock; migrate DEFAULT_ADMIN+ADMIN atomically with VRYO/DAX (shared KMS) |
| Profit redirect | `setBuybackOfficer` | divert floor-arb profit (profit-only, not principal) | timelock |
| Rebalance target | `setVryo` | point the end-of-tx poke (or 0 to disable) | timelock; prefer try/catch in a future impl (M1) |
| Reward engine | `setVgo` | point/disable the keeper reward (best-effort already) | timelock |
| Venue setters | `setBalancerVault`/`setV2Router`/`setV3Factory`/`setV3Router`/`setV3Quoter`/`setUsdc` | re-point external venues | timelock; freeze to canonical |
| Pause | `setPaused` | halt floor defense | fast guardian |
| Rescue | `rescueToken` | arbitrary token+dest (VY blocked) | timelock; bal~0 |

→ See `findings/ValinityFloorOfficer.md`. **Roles held by the new VFO:** VRT.BUYBACK_ROLE + VCO.OFFICER_ROLE + VGO.OFFICER_ROLE + VY-whitelist (old `0x3d9d78CD` revoked on all). **The upgrade lever is admin-equivalent to reserve-drain + cap-mutation — the dominant handoff concern.**
