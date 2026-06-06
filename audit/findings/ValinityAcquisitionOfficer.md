# Audit: ValinityAcquisitionOfficer (VAO **V2**) — contract 3 of 18

> ⚠️ Supersedes an earlier INVALID report that analyzed a non-deployed V1 (`acquire()`-based). See `findings/VAO-source-error-correction.md`. The live contract is the **permissionless V2** below. This doc is my own analysis; a full multi-agent adversarial workflow is validating it in parallel (results appended on completion).

- **Proxy:** `0x7a0E582479579e1423bc4f1DFD0750feA9282B01` → **UUPS impl** `0xc364f74e0c644dc7ed16b8214d2b613f7725304a`
- **Source:** `contracts/officer/ValinityAcquisitionOfficer.sol` (857 lines, V2) · solc 0.8.27 · UUPS + AccessControl + ReentrancyGuardTransient
- **Source==live:** artifact `deployedBytecode` == live (only 2 UUPS immutables @6319/6522 differ) **AND** 64/64 artifact-ABI selectors present in live bytecode **AND** workspace `.sol` sha256 == as-deployed source. solcInputHash `cb6d5b6c`. Triple-confirmed.

## What it is
A **permissionless, closed-circuit** rebalancer + the protocol's **TWAP oracle** (VCO reads `getAssetTwapPrice` for LTV-F). Anyone can call either entrypoint; all amounts are computed **on-chain** (no caller-supplied routes/amounts). Optional VGO keeper-reward refunds the caller's gas.

| Function | Access | Effect |
|---|---|---|
| `executeAcquireByLTV()` | **permissionless**, nonReentrant | if `ltvFH·10000 ≥ ltvFL·10500` for VCO assets H/L: pull `totalVy=capH·(ltvFH−ltvFL)/(ltvFH+ltvFL)` VY from VYT → 1% fee to BBO → swap rest VY→assetL on DAX → deposit assetL to VRT → raise cap on **assetH** by full totalVy |
| `executeAcquireByMTP()` | **permissionless**, nonReentrant | if DAX price ≥ 2.1×ltvF(M): solve netVy to push price→1.9×, gross up for 2% fee → same cycle, swap+deposit+cap all on **assetM** |
| `getAssetTwapPrice(asset)` | view | 30-min Uniswap-V3 TWAP USD price (direct or 2-hop via WETH); consumed by VCO |
| `initialize` / `initializeV2(dax,bbo,vryo,vgo)` | initializer / reinitializer(2), ADMIN | wiring; `initializeV2` MAX-approves DAX to spend VY |
| `setDax`/`setBuybackOfficer`/`setVryo`/`setVgo`/`setPaused`/`setSwapSlippageBps`/fee+cooldown setters/`setAssetTwapConfig`/`setWeth*`/`rescueToken`/`_authorizeUpgrade` | **ADMIN_ROLE** | config + rescue (VY blocked) + UUPS (admin paths) |

**Live state:** dax=`0xd256c672…`, vryo=`0xa95749f5…`, vgo=`0x0a6c2117…`, feeRecipient(BBO)=`0x4b97d45d…`, VRT=`0x06087789…`, VCO=`0x2f024159…`. admin (DEFAULT_ADMIN+ADMIN)=`0x8310ea7e…4a09` (**same key as VYT**). `execPaused=false`, `swapSlippageBps=100 (1%)`, fees 200/100 bps, cooldowns 300s (MTP) / 43200s (LTV). VAO holds **PRIORITY_OFFICER_ROLE+OFFICER_ROLE on VYT**, **OFFICER_ROLE on VCO**.

## Gate 0 — Atomic fund flow / CLOSED-CIRCUIT (non-admin) ✅ closed by physics
`_executeCycle` is the shared spine; both entrypoints route through it. Every value edge lands on a **hardcoded** destination and the cycle ends with two balance invariants:

```
postVyBal  == preVyBal      (line 488)  → VAO keeps ZERO net VY
postAssetBal <= preAssetBal (line 489)  → VAO keeps ZERO net asset
```

| Edge (line) | Token | Destination | Class |
|---|---|---|---|
| `vyt.pullTokens(address(this), totalVy)` (465) | VY | VAO self (**hardcoded**) | fixed-internal |
| fee `safeTransfer(bbo, fee)` (468) | VY | feeRecipient=BBO | admin-set sink (not caller-chosen) |
| `dax.swapExactIn(poolId, VY, netVy, minOut, address(this))` (476) | VY→asset | VAO self (**hardcoded recipient**) | fixed-internal |
| `safeTransfer(address(vrt), assetReceived)` (480) | asset | VRT (**hardcoded, no setter**) | fixed-internal |
| `increaseAssetCap(capRaiseAsset, totalVy)` (483) | — | VCO accounting | no value |
| `rescueToken(token,to,amount)` (842) | any **non-VY** ERC20 | arbitrary | **ADMIN-only; VY reverts (849)** |

→ **CLOSED (non-admin), by physics.** No caller parameter selects any destination; no arbitrary `.call`; swap recipient + VRT deposit are hardcoded; the invariants force zero retention. VY can reach only {BBO fee, DAX}; the bought asset can reach only VRT. `rescueToken` is the sole arbitrary-destination edge and it's ADMIN-only **and** cannot move VY. **Materially stronger than the (non-deployed) V1.**

## Key dependency & attacker-first analysis (permissionless paths)
Since **anyone** can call these, the real question is whether an attacker can manipulate the **on-chain inputs** to make the protocol over-pull VY or sell it too cheaply, then profit:
- **Swap pricing / sandwich:** `minOut` is computed in `_previewSwap` from the **DAX pool's own live reserves** (constant-product) minus `swapSlippageBps` (1%). This only protects against price moves **between** the preview and the swap **if the public cannot move those reserves**. ✅ The DAX interface exposes `updateSwapWhitelist` / `NotWhitelisted` → **DAX swaps are permissioned (not a public AMM)**, so outsiders can't trade against the pool to sandwich VAO. **This is the linchpin of the permissionless safety and MUST be confirmed when the DAX impl is audited (separate 🔴 contract; only the interface is in this closure).** → cross-contract dependency CC-1.
- **MTP via flash-loaned DAX reserves:** if an attacker could move DAX reserves in-block they could distort `daxPrice`→`netVy`; same whitelist gate defends this. Depends on CC-1.
- **TWAP manipulation:** `getAssetTwapPrice` uses a 30-min Uniswap-V3 TWAP on admin-configured pools → expensive to move; feeds VCO ltvF. Verify configured pools are deep/high-cardinality (DD-2).
- **VGO keeper-reward farming:** caller gets gas refund + bonus, but only when a **real disparity exists** and the per-path **cooldown** has elapsed (300s/43200s), and each call does real protocol-beneficial work → griefing/farming is rate-limited and not free value. (Confirm VGO's own bonus economics when auditing VGO.)
- **Cooldowns/pause:** both bounded/admin; pause is a liveness lever only.

## Findings (my analysis — pending workflow confirmation)
| ID | Sev | Finding |
|---|---|---|
| VAO-CC1 | **Dependency (High if violated)** | Permissionless safety **requires DAX swaps to be permissioned**. Verified only via interface (`NotWhitelisted`/`updateSwapWhitelist`); confirm in the DAX audit that the public cannot swap against VAO's pools. If DAX swaps are ever opened, both entrypoints become sandwichable. |
| VAO-L1 | Low | `minOut` self-referential to the DAX pool's own reserves; safe **only** under CC-1. No independent oracle cross-check on the executed swap price (the TWAP is used for ltvF, not to bound this swap). Defense-in-depth: bound swap output against `getAssetTwapPrice` too. |
| VAO-L2 | Low | Cap raised by **gross** totalVy (incl. fee) while reserves added = net asset value; intentional per spec, but recorded backing runs slightly ahead of delivered value each cycle. |
| VAO-I1 | Info | `setDax` MAX-approves the new DAX to spend VAO's VY. VAO holds ~0 between cycles so standing exposure is ~0, but a malicious DAX set post-handoff is the highest-value admin abuse → pin/allowlist DAX behind timelock. |
| VAO-I2 | Info | `vryo.execute()` and VGO calls run AFTER the invariant checks via try/catch → cannot corrupt the circuit or brick acquisitions; benign by design. |
| VAO-I3 | Info | All tunables bounded in code (fee ≤10%, cooldown ≤1 day, slippage 1–1000 bps); `rescueToken` blocks VY. Good hardening. |

## Governance-handoff conditions
- **`setDax` (highest value)** — controls the swap venue that VY is MAX-approved to and that prices the swap; timelock+multisig + DAX allowlist/codehash before lock.
- **`_authorizeUpgrade`** — an upgrade can remove the balance invariants; UPGRADER_ROLE + timelock.
- Confirm `feeRecipient`=BBO, `vryo`/`vgo` correct, `execPaused` holder.
- **CC-1:** confirm DAX swap permissioning during the DAX audit — VAO's permissionless safety inherits it.

## Check-off
- [x] Source == live (bytecode + 64/64 selectors + workspace sha256; V2 confirmed, V1 quarantined)
- [x] Fund-flow mapped — CLOSED (non-admin) by two balance invariants + hardcoded destinations
- [x] Live-state read (V2 wiring, roles, fees, slippage, admin)
- [x] Multi-agent adversarial workflow launched (`wogu5lgyr`) — reconcile on completion (non-blocking)
- [x] **User checked VAO off — 2026-06-01**
