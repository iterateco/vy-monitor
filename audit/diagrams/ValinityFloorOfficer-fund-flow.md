# ValinityFloorOfficer (VFO) — Floor-Defense Flash Circuit · the VY-below-floor arbitrage sink

Address `0x3d9d78CD…59D51` — **NON-PROXY, NON-UPGRADEABLE** (plain `AccessControl + ReentrancyGuardTransient`, constructor-set immutables; EIP-1967 impl slot empty; logic FROZEN — no UUPS, no `_authorizeUpgrade`). The **floor officer**: when VY trades below its on-chain LTV-F backing, it flash-borrows USDC, buys the cheap VY, retires it to VYT, releases the *exact pro-rata* collateral from VRT, sells it, repays the flash, and forwards any profit to the buyback officer. Source==live **PROVEN** (as-deployed source keccak `0xcf265d27…` == `deployment.metadata.sources[VFO].keccak`; 30/31 closure files byte-identical to git `8a8b795`/`.v1.bak`; `deployedBytecode` metadata IPFS `1220d0b9bbdd…` == live; all 6 immutables confirmed == correct system addresses).

> **OPERATOR-GATED, not permissionless.** Only `operator()` (`0x6B700Bd4`, backend EOA) may call `initiateFloor`. The operator supplies the flash size **and arbitrary swap calldata** (`SwapStep{router,tokenIn,tokenOut,callData}` run via `router.call`), constrained to an **admin-whitelisted router set** (live: only UniV2 Router02 + UniV3 SwapRouter).
>
> **This is NOT the workspace version.** `contracts/officer/ValinityFloorOfficer.sol` (627ln, git `5d96a85`) is an undeployed UUPS *rewrite* with permissionless `executeFloor(uint256)` + hardcoded routing. Audit target = the live `8a8b795` operator-gated `initiateFloor` version.

## Atomic flow (one Balancer V2 flash loan, inside `receiveFlashLoan`)

```
 operator ──initiateFloor(flashAmt, withdrawals[], buySwaps[], sellSwaps[], profitSwaps[], deadline)──▶ VFO
                                       │ (onlyOperator, nonReentrant, !paused, block.timestamp<=deadline)
                                       ▼
        Balancer V2 Vault ── flashAmt USDC ──▶ VFO.receiveFlashLoan  [guard: msg.sender==Vault && tload(flashSlot)]
                                       │
   1. buySwaps:   USDC ──[router.call]──▶ VY            (each step: tokenOut bal of VFO MUST strictly ↑, else revert)
   2. vyAmount = VY.balanceOf(this)
   3. VY ──safeTransfer──▶ VYT            (ALL bought VY, retired from circulation)   ◀── hardcoded sink
   4. per withdrawal i:  reserve=asset.balanceOf(VRT); cap=vco.getAssetCap(asset)
                         withdrawAmount[i] = capReduction[i] · reserve / cap          (contract-computed, LTV-exact)
                         totalCapReduction += capReduction[i]
   4.1 REQUIRE  totalCapReduction == vyAmount      ◀── THREE-WAY LOCK (CapReductionMismatch)
   5. VRT ── assets[] (withdrawAmounts) ──▶ VFO     [vrt.withdrawForBuyback(assets, amts, address(this))]  ◀── recipient HARDCODED = this
      VCO.decreaseAssetCap(asset, capReduction)     per i  (reverts if cap<floor)     ◀── golden rule: cap ↓ by exactly VY-to-VYT
   6. sellSwaps:  assets ──[router.call]──▶ USDC                                       (output-↑ check per step)
   7. USDC ── repayAmount (=flashAmt + 0 fee) ──▶ Balancer Vault                       ◀── hardcoded repay (revert if short)
   8. profitSwaps: leftover USDC ──[router.call]──▶ VY   (last step tokenOut MUST==VY, else FinalSwapMustOutputVY)
   9. profitVY = VY.balanceOf(this); VY ──safeTransfer──▶ profitRecipient (0xD2F0826a, in-circuit buyback)  ◀── hardcoded profit sink
  10. CLEAN-STATE: balanceOf(this) == 0 for every withdrawn asset, USDC, VY, and all swap intermediates (else TokenBalanceNotZero)
```

## Exit set — every token destination (NON-admin)
| Token | Destination | Operator-controllable? | Guard |
|---|---|---|---|
| VY (bought) | **VYT** (hardcoded `address(vyt)`) | NO | three-way lock ties amount to cap reductions |
| reserve asset | **address(this)** (VRT withdrawal recipient) | NO | `withdrawForBuyback(…, address(this))` hardcoded; amount contract-computed |
| USDC | **Balancer Vault** (flash repay) | NO | exact `flashAmt + fee`; revert if short |
| profit VY | **profitRecipient** (storage, admin-set; in-circuit contract) | NO (operator can't set it) | hardcoded `_profitRecipient` |
| any swap output | **address(this)** | NO | per-step `tokenOut.balanceOf(this)` must strictly ↑ (`SwapOutputZero`) |

**There is NO `msg.sender`-, operator-, or calldata-derived recipient on any transfer or withdrawal.** The operator chooses *how* to swap (router + calldata) but every swap's **output must land back in VFO** (output-increase invariant), and every *settlement* exit is hardcoded. Net: the operator can pick routes/sizes but cannot redirect a single token to an arbitrary address.

## Backing conservation (golden rule) — TEXTBOOK CORRECT
- **VY into treasury → cap down, by exactly the amount:** `totalCapReduction == vyAmount` (every retired VY booked as a cap decrease). ✓ The cleanest golden-rule sink in the system. (This reconciles the VCO OFFICER_ROLE holder `0x3d9d78CD` — it is **VFO**, a cap-DECREASE actor; my earlier "buyback-2" label was wrong.)
- **Backing ratio preserved (no under-backing):** `withdrawAmount = capReduction · reserve / cap` ⇒ `new_reserve/new_cap = reserve(1 − Δ/cap)/(cap − Δ) = reserve/cap` (Δ=capReduction). The pro-rata collateral released exactly matches the retired VY's share — per-VY backing is invariant. ✓
- **Floor-protected:** `vco.decreaseAssetCap` reverts if a cap would fall below its effective floor.

## Access model
```
 PERMISSIONLESS: (none — initiateFloor is onlyOperator; receiveFlashLoan is onlyBalancerVault)
 OPERATOR (0x6B700Bd4 EOA): initiateFloor — triggers a floor op, supplies routes/sizes (CANNOT redirect funds; see exit set)
 ADMIN_ROLE (0x8310eA7E EOA → governance):
   ├─ setOperator                 repoint the trigger wallet
   ├─ setProfitRecipient          repoint the profit sink   ⚠ (could divert profit if set to attacker)
   ├─ setRouterWhitelist          add/remove swap routers   ⚠ (trust anchor — see note)
   ├─ setPaused                   emergency stop
   └─ rescueToken(token,to,amt)   arbitrary token+dest; does NOT block VY ⚠ (but standing balance ~0)
 NO UPGRADE PATH — contract logic is permanently frozen (non-proxy, no UUPS).
```

**Router-whitelist trust note:** the per-step **output-increase invariant** (`tokenOut.balanceOf(this)` must strictly increase after each `router.call`) is the real containment — it neutralizes recipient-redirection / `sweepToken` / `multicall` exfil even on the legit routers (output sent elsewhere ⇒ no balance increase ⇒ revert), and bounds a *malicious* whitelisted router to "can't make output appear in VFO without actually delivering it." Live whitelist = UniV2 Router02 + UniV3 SwapRouter only.

## Live state (today)
- 41 `FloorExecuted` ops all-time; **standing balances VY=0, USDC=0** (clean-state holds live).
- Roles held: VRT.BUYBACK_ROLE + VCO.OFFICER_ROLE (exactly the two needed — least privilege).
- operator EOA `0x6B700Bd4`; profitRecipient contract `0xD2F0826a` (in-circuit); admin EOA `0x8310eA7E`; `execPaused=false`.

**Verdict (RECONCILED, workflow `wkqttweuq` — 64 agents, 19 surv / 37 ref):** ✅ **CLOSED relative to roles — no arbitrary-destination exfiltration, even by a fully-compromised operator.** Every settlement exit is hardcoded {VYT, VRT→self, Balancer repay, profitRecipient}; the operator's only freedom (swap routing) is contained by the **per-step output-increase invariant** (L498, sampled *after* `router.call` → defeats recipient-redirect / `sweepToken` / `multicall`) + clean-state checks. **No surviving Critical/High *technical* finding** (the contested [High] `sweepToken` bypass was refuted — output check is post-call). Golden rule textbook-correct (cap↓ == VY-to-VYT via the three-way lock) and backing ratio exactly preserved (LTV-exact withdrawal; rounding dust over-backs). Operator-gated (no permissionless surface). Non-upgradeable (frozen). Residual: **VFO-H1** `setProfitRecipient` admin profit-diversion (profit-only, not principal); **M1** operator self-sandwich MEV (no minOut; principal-safe); **M2** `rescueToken` arbitrary token+dest (bal~0); **M3** unverified `withdrawForBuyback` return (needs VRT-bug + operator collusion); Lows (duplicate-asset hygiene, FoT-revert, router-whitelist trust, transfer-hook reentrancy) — all admin/operator-trust on a frozen contract, neutralized by moving ADMIN→timelock/gov + the revoke step.

---

## ⚙️ Admin / governance powers — permanent at handoff
| Power | Function | Effect | Handoff requirement |
|---|---|---|---|
| Trigger wallet | `setOperator` | repoint who can run floor ops | gov/keeper-controlled; rotate on compromise |
| **Profit sink** | `setProfitRecipient` | divert floor-arb profit | timelock + gov; keep = in-circuit buyback |
| **Router whitelist** | `setRouterWhitelist` | the swap-routing trust anchor | timelock + gov; only legit DEX routers |
| Emergency stop | `setPaused` | halt ops | gov/guardian |
| Token rescue | `rescueToken` | arbitrary token→arbitrary dest (no VY block) | timelock + gov; standing balance ~0 limits blast radius |
| ~~Upgrade~~ | — | **none — frozen logic** | ✅ no action (cannot be changed) |

→ See `findings/ValinityFloorOfficer.md`. Both `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` (today `0x8310eA7E…4a09`) → timelocked governance; the operator EOA → a controlled keeper.
