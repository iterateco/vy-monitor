# ValinityGovernanceCommittee (VGC) — Findings · governance + keeper-funding token

**Address:** `0xe595309a6c0119b0690063A91c5572851A662c67` (NON-PROXY, NON-UPGRADEABLE — plain ERC20 + ERC20Permit).
**Source==live:** PROVEN (gold standard) — build-info `32bd69ca…` compiled VGC to deployedBytecode metadata IPFS `12200f327310…` == live; embedded source byte-identical to the dirty workspace `contracts/governance/ValinityGovernanceCommittee.sol` (keccak `0x80d4213d…`, 257ln). Deployed from the uncommitted workspace. solc 0.8.27/runs=100/cancun. As-deployed saved.
**Audit workflow:** `w5mu2e3r7` (7 dimensions, adversarial refutation) — *verdict reconciled below.*

> **Context:** VGC is the token the **VGO** mints as keeper rewards; its per-epoch ceiling is the emission cap/kill-switch that the [VGO audit](ValinityGasOfficer.md) depends on (VGO-M2). This audit confirms that dependency.

---

## Verdict (RECONCILED, workflow `w5mu2e3r7` — 73 agents, 4 surv / 61 ref · **NO Critical/High/Medium code findings**)

✅ **Emission provably bounded — a sound cap + kill-switch; minimal, clean trust model; immutable.** Per-epoch ceiling is ≤ `epochMintBps` (≤0.25%/week) of the *unminted* supply snapshotted at the epoch start; `totalSupply` stays strictly below the 7M hard cap forever (geometric/asymptotic — proven by induction: `bps ≤ 25 < 10000` ⇒ each epoch adds `< (MAX_SUPPLY − totalSupply)`, so `MAX_SUPPLY − totalSupply()` never underflows). `epochMintBps=0` halts. uint96 packing safe (`cap ≤ 1.75e22`, supply ≤ 7e24 ≪ uint96 max ~7.9e28). Skipping epochs **does not compound** (one fresh allowance, never N). `getMintAllowance()` **exactly mirrors** `mint()` so the VGO never mis-sizes/reverts mid-mint. Stock OZ ERC20+Permit — no fee, no burn, no hook (mint `to` can't reenter), no admin mint, no admin balance-move, no upgrade. The sole minter is one-time-locked; the admin can only slow/halt emission, never accelerate/mint/move. **This validates the VGO dependency (VGO-M2).** The reward path is **doubly-dormant** today (`minter` unset + `VGO.vgc=0`).

---

## Findings

### VGC-L1 — Activation risk: `setMinter` is one-time/irreversible and the minter is currently UNSET · **Low (admin-trust, activation-window)**
While `minter == address(0)` (live), a compromised `admin` (`0x8310eA7E`) could `setMinter(malicious)`; that minter could then mint up to the per-epoch ceiling (~0.25%/week of unminted ≈ 17.5k VGC/week initially) until halted. **Bounded** (ceiling-capped, recoverable by `setEpochMintBps(0)`), and `setMinter` is one-time so the *correct* call (point at the audited VGO) permanently closes it. *Action: execute `setMinter(VGO 0x0a6C2117)` from a trusted admin, verify, then it's locked forever. A mis-set minter is permanent (redeploy only) — handle with care.*

### VGC-L2 — `admin` can halt emission (`epochMintBps=0`); kill-switch has up to ~7-day latency · **Low (by design / griefing)**
A compromised/captured admin can set `epochMintBps=0` and halt all keeper rewards (DoS of the keeper-incentive layer, not a fund loss) — this is also the intended **kill-switch**. **Caveat:** because the active ceiling reads the *frozen* `e.bps` snapshot, `epochMintBps=0` only takes effect at the **next epoch boundary** — the current epoch's already-frozen allowance (remaining `cap − minted`) can still be minted for up to ~7 days. So an "emergency halt" is not instantaneous; it's bounded by the current epoch's remaining cap (≤0.25% of unminted). *Mitigation: admin → governance Executor; accept the bounded latency (it's inherent to the freeze-at-epoch-start design that also blocks mid-epoch acceleration).*

### VGC-L3 — `transferAdmin` lacks a zero-address check · **Low (operational nit)**
`transferAdmin(address(0))` sets `pendingAdmin = 0`, which makes `acceptAdmin()` always revert (it rejects zero) — stalling/cancelling the two-step handoff. Fully reversible (admin re-calls with a valid address); no token loss, no new power. The contract is immutable so it can't be patched — mitigation is operational care during the admin→governance handoff. *(One-line fix in any future redeploy: `if (newAdmin == address(0)) revert ZeroAddress();`.)*

### VGC-L4 — INITIAL_SUPPLY (1,000,000 VGC) held by the KMS EOA · **Low (governance centralization at handoff)**
The constructor minted the full 1M seed (= 100% of current supply, ~14% of MAX_SUPPLY) to `treasury = 0x8310eA7E` (the KMS). Because VGC is also the governance token (voting weight / bps-of-supply thresholds), this is a centralization concern at handoff. *Decide the seed's disposition (e.g., move to a treasury/timelock/distribution) as part of the governance handoff.*

### Informational
- **VGC-I1 (positive): emission math is sound.** Geometric per-epoch ceiling on unminted supply, frozen (unminted + bps) at epoch start; mid-epoch `setEpochMintBps` only takes effect next epoch; `epochMintBps` can never exceed the immutable `MAX_EPOCH_MINT_BPS=25` (admin can only slow/halt). `totalSupply < MAX_SUPPLY` always ⇒ `MAX_SUPPLY − totalSupply()` never underflows and `uint96` casts never truncate (`≤ 7e24 ≪ uint96 max ~7.9e28`). Skipping epochs resets once (no compounding catch-up).
- **VGC-I2 (positive): sole-minter lock** — `setMinter` one-time + `minterLocked`; no other mint path; no admin mint.
- **VGC-I3 (positive): non-upgradeable / immutable** — non-proxy, constructor-based; no upgrade lever; logic permanently frozen.
- **VGC-I4 (positive): stock OZ ERC20 + ERC20Permit** — no override of transfer/transferFrom/approve, no fee, no burn, no transfer hook (mint `to` can't reenter), no pause/blacklist/rebase; EIP-2612 permit is OZ default. 18 decimals.
- **VGC-I5 (positive): `getMintAllowance()` mirrors `mint()`** — same newEpoch/unminted/bps/minted logic, so the VGO sizes mints without mid-mint reverts (verify exact parity in the workflow).
- **VGC-I6: no-burn is intentional** — burning would shrink `totalSupply()` to cheapen governance bps-of-supply thresholds; deliberately omitted.
- **VGC-I7: two-step admin transfer** — `transferAdmin`/`acceptAdmin`; `acceptAdmin` clears `pendingAdmin`.

---

## Activation / handoff requirements (contract is immutable — these are the only levers)
1. **One-time `setMinter(VGO 0x0a6C21174d039f5D85dA93FCB3FE7ad5F5f5E827)`** — irreversible; must point at the **audited VGO**; pair with `VGO.wireVgc(VGC)`; verify on-chain. (VGC-L1.)
2. Keep `epochMintBps` sane (≤25; `0` available as kill-switch). (VGC-I1/L2.)
3. **Migrate `admin` → governance Executor** via the two-step transfer. Low blast radius (admin can't mint/move). (VGC-I7.)
4. Decide the **1M INITIAL_SUPPLY** disposition (KMS-held seed; governance-weight concern). (VGC-L3.)
5. No upgrade action — logic is permanently frozen. **This audit validates the VGO emission-cap dependency (VGO-M2).**
