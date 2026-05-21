# Valinity Perp — UX Infrastructure Setup Guide

**Purpose:** Step-by-step plan for building the gasless, signature-free UX layer on top of the deployed perp contracts (PerpCore, BackstopVault, Oracle).

**Pattern used:** ERC-4337 Account Abstraction with a custom Paymaster.

**Important:** This document is for the UX/infrastructure layer. The perp contracts themselves (per `PERP_SPEC.md`) remain unchanged. The ERC-4337 stack is purely additive.

---

## 1. What We're Building (One-Line Summary)

A frontend + infrastructure layer that lets users trade on the VY perp **without holding HYPE for gas and without signing every transaction**. Gas costs auto-deducted from the user's USDC balance. Experience similar to a CEX.

---

## 2. Architecture Overview

```
USER'S BROWSER (mobile webview or desktop)
─────────────────────────────────────────
  Valinity Webdapp (the brain)
    ├── Permissionless.js SDK
    ├── Safe Smart Wallet SDK
    ├── Session key (in localStorage)
    └── User's wallet for initial auth (mobile wallet / MetaMask / WalletConnect)

           │ UserOperations
           ▼
OFF-CHAIN INFRASTRUCTURE (your servers)
───────────────────────────────────────
  Skandha Bundler (self-hosted, ~$30/mo VPS)
    └── Bundles UserOps, submits as Ethereum tx

           │ bundled tx
           ▼
ON-CHAIN (HyperEVM, chain 999)
───────────────────────────────
  EntryPoint v0.7 (official ERC-4337 singleton)
       │
       ├── User's Smart Wallet (Safe + 4337 module)
       │     └── calls existing perp contracts
       │           ├── PerpCore.openPosition / closePosition / etc.
       │           └── BackstopVault.deposit / withdraw
       │
       └── Paymaster (the only NEW contract you write)
             └── Pays HYPE gas, pulls USDC from user's Smart Wallet
```

---

## 3. Component Inventory

| Component | Where | Build or Use? | Effort |
|---|---|---|---|
| **EntryPoint v0.7** | On-chain HyperEVM (singleton) | Use existing OR deploy once | 1 hour if needed |
| **Smart Wallet** | On-chain (per user) | Use Safe + 4337 module (audited) | None — just integrate |
| **Bundler (Skandha)** | Off-chain (your server) | Self-host | 1-2 days devops |
| **SDK (Permissionless.js)** | In browser | Use library, integrate in webdapp | 2-3 weeks frontend |
| **Paymaster** | On-chain HyperEVM | **BUILD CUSTOM** (~150 LOC Solidity) | 1-2 weeks + audit |
| **Webdapp UI** | Browser/webview | Build | 6-10 weeks frontend |

---

## 4. Pre-Implementation Verification (DO THIS WEEK)

These need to be confirmed before designing the Paymaster or starting any build work.

### 4.1 EntryPoint deployment on HyperEVM

**Check:** Is EntryPoint v0.7 deployed at the standard address?

```bash
# Standard address (same on all EVM chains):
ENTRY_POINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"

# Check if code exists at this address on HyperEVM mainnet:
cast code $ENTRY_POINT --rpc-url https://rpc.hyperliquid.xyz/evm

# If output is "0x" → not deployed → you deploy it
# If output is bytecode → deployed → use it as-is
```

**If not deployed:**
- Deploy the official open-source EntryPoint v0.7 (Eth-Infinitism's audited contract)
- Source: https://github.com/eth-infinitism/account-abstraction
- Cost: ~$50-200 in HYPE for deployment
- One-time deployment — anyone can do it

### 4.2 Safe contracts on HyperEVM

**Check:** Are Safe singleton contracts deployed?

- SafeProxyFactory
- SafeL2 singleton
- Safe4337Module
- Compatibility fallback handler

**Source for verification:** https://github.com/safe-global/safe-deployments

**If not deployed:** Deploy them yourself using Safe's deployment scripts. Standard procedure, ~30 minutes.

### 4.3 HyperSwap pool for USDC/HYPE

For the Paymaster to swap accumulated USDC back to HYPE, there must be a HyperSwap pool with USDC/HYPE liquidity.

**Check:** Confirm USDC/HYPE pool exists on HyperSwap with reasonable depth (>$50k).

If pool doesn't exist or is too thin, alternative is to manually refill Paymaster's HYPE balance from a multisig.

### 4.4 Bundler infrastructure feasibility

**Check:** Can Skandha or another open-source bundler run against HyperEVM?

- Skandha repo: https://github.com/etherspot/skandha
- Bundler needs to: connect to HyperEVM RPC, support EIP-1559 fee model, validate UserOps per EIP-4337
- HyperEVM should support all of this (it's EVM-compatible Cancun)

**If issues:** Voltaire (https://github.com/candidelabs/voltaire) is an alternative Python-based bundler.

---

## 5. Build Sequence

### Phase 1: Foundation (Weeks 1-2)

**Owner:** DevOps + Smart Contract team

- [ ] Verify all items in §4 above
- [ ] Provision a VPS for Bundler ($30-50/mo, e.g., DigitalOcean droplet)
- [ ] Deploy EntryPoint v0.7 if needed
- [ ] Deploy Safe contracts if needed
- [ ] Confirm HyperSwap USDC/HYPE pool exists with adequate depth
- [ ] Document all deployed addresses

**Deliverable:** A `DEPLOYED_ADDRESSES.md` with verified addresses for EntryPoint, Safe contracts, and the HyperSwap pool.

### Phase 2: Paymaster Contract (Weeks 3-5)

**Owner:** Smart Contract team

- [ ] Write `PAYMASTER_SPEC.md` (or have me write it)
- [ ] Implement Paymaster contract (~150 lines Solidity)
- [ ] Write unit tests + Foundry invariant tests
- [ ] Internal review
- [ ] Schedule audit (Spearbit, ChainSecurity, or Code4rena — Paymasters audit cheaply, ~$10-20k)

**Paymaster requirements (high-level):**

```
Paymaster contract responsibilities:
  1. validatePaymasterUserOp() — called by EntryPoint before each UserOp
     - Verify target is whitelisted (PerpCore or BackstopVault)
     - For OPEN operations: verify user has USDC balance
     - For CLOSE operations: skip balance check (funds released by tx)
     - Return validation context

  2. postOp() — called by EntryPoint after each UserOp
     - Convert actual gas cost to USDC equivalent
     - Apply small markup (10%) for HYPE refill economics
     - transferFrom user's Smart Wallet → Paymaster

  3. refillHype() — permissionless, anyone can call
     - Check accumulated USDC balance > MIN_REFILL
     - Swap USDC → HYPE via HyperSwap
     - Deposit HYPE to EntryPoint for paymaster
     - Anyone can trigger; designed for bot automation

Key parameters:
  WHITELIST_CONTRACTS:        PerpCore address, BackstopVault address (immutable)
  USDC_MARKUP_BPS:            1000 (10% markup over actual gas cost)
  MIN_REFILL_USDC:            100e6 ($100 minimum to swap)
  HYPE_USDC_PRICE_FEED:       Oracle source for HYPE/USDC rate

Custom errors:
  WhitelistFailed, InsufficientUserUSDC, RefillTooSmall, etc.
```

I can write the full `PAYMASTER_SPEC.md` in the same format as `PERP_SPEC.md` when ready.

### Phase 3: Bundler Setup (Week 4-5, parallel with Paymaster)

**Owner:** DevOps

- [ ] Install Skandha on VPS
- [ ] Configure HyperEVM RPC endpoint
- [ ] Configure EntryPoint address
- [ ] Generate Bundler EOA, fund with HYPE (~10 HYPE for operations)
- [ ] Set up monitoring (uptime, error rates, HYPE balance alerts)
- [ ] Document Bundler RPC URL for frontend team
- [ ] Set up automatic restart on failure

**Resource estimate:**
- VPS: 2 vCPU, 4GB RAM, 50GB SSD (~$30/mo on Hetzner/Linode)
- Bundler RAM usage: ~500MB
- Disk: minimal (just logs)

### Phase 4: Frontend Integration (Weeks 4-10, parallel)

**Owner:** Frontend team

- [ ] Set up Next.js + viem + Permissionless.js
- [ ] Implement wallet connection flow (your mobile wallet + MetaMask + WalletConnect)
- [ ] Implement Smart Wallet deployment flow (one-time per user)
- [ ] Implement initial setup: 2 approvals (USDC → PerpCore, USDC → Paymaster)
- [ ] Implement session key generation + localStorage persistence
- [ ] Implement core trading UI (open/close/SL/TP)
- [ ] Implement vault deposit/withdraw UI
- [ ] Implement positions/history dashboard
- [ ] Implement balance display (combined Smart Wallet USDC + active position margins)
- [ ] Implement error handling (insufficient balance, oracle paused, etc.)
- [ ] Mobile webview compatibility testing

### Phase 5: Integration Testing (Weeks 8-12)

**Owner:** All

- [ ] Testnet deployment (perp + Paymaster + Bundler + Frontend)
- [ ] End-to-end flow testing with internal team
- [ ] Performance testing (latency under load)
- [ ] Gas cost calibration (tune Paymaster markup based on real data)
- [ ] Edge case testing (close with empty wallet, low Paymaster HYPE, etc.)
- [ ] Beta with limited external users

### Phase 6: Audits and Launch (Weeks 13-20)

**Owner:** Project lead

- [ ] Perp contracts audit (Spearbit/Trail of Bits — 4 weeks, ~$50-100k)
- [ ] Paymaster audit (smaller firm — 2 weeks, ~$10-20k)
- [ ] Fix audit findings, re-test
- [ ] Mainnet deployment of perp contracts (per PERP_SPEC.md §9 checklist)
- [ ] Mainnet deployment of Paymaster
- [ ] Fund Paymaster with initial HYPE (e.g., 1000 HYPE)
- [ ] Launch frontend (mobile + desktop)
- [ ] Monitor and iterate

---

## 6. Operational Checklist (Post-Launch)

### Monitoring

| Metric | What to watch | Action if abnormal |
|---|---|---|
| Bundler uptime | Should be >99% | Failover to backup bundler / investigate |
| Bundler HYPE balance | Reimbursed by Paymaster, but watch for drift | Manually top up if balance drops |
| Paymaster HYPE balance | Should be replenished by `refillHype()` calls | Trigger refill manually if low |
| Paymaster USDC accumulated | Should grow steadily | If growing too fast, markup is too high |
| Transaction success rate | Should be >99% | Investigate failures |
| Average UserOp latency | Should be <2 seconds | Investigate bundler performance |

### Refill bot (recommended)

Write a small backend service that:
- Monitors Paymaster's HYPE balance
- When HYPE balance < threshold, calls `Paymaster.refillHype()`
- Logs results, alerts on failures

This is permissionless — anyone could run it — but you should run one to ensure reliability.

### Backup bundler

Run two Skandha instances on different VPS providers for redundancy. Frontend can be configured with fallback RPC.

---

## 7. Open Items For Team To Research/Decide

| Item | Question | Recommended approach |
|---|---|---|
| HYPE oracle for Paymaster | How does Paymaster know HYPE/USDC price? | Read HyperSwap pool TWAP (same as our Oracle contract); or use HyperCore precompile for HYPE/USD if accessible |
| Session key expiry | Should session keys expire? After how long? | Recommend 30 days, then re-auth (single signature). Configure in Smart Wallet module. |
| Session key permissions | Should they only allow VY perp ops, or anything? | Limit to PerpCore + BackstopVault function calls. Use Safe's 4337 module's permission system. |
| Recovery if session key lost | What if user clears browser? | Re-authorize with main wallet (one signature). Same flow as first setup. |
| Bundler failover | Single bundler = single point of failure | Run 2 bundlers on different providers, frontend retries on failure |
| Gas markup percentage | 10% buffer enough? | Start at 10%, observe real costs, adjust |
| Public bundler vs private mempool | UserOps in public bundler mempool — MEV risk? | Private bundler (you run it) avoids this entirely |
| Initial gas subsidization | Should you sponsor gas free for first 30 days as marketing? | Optional — sets `USDC_MARKUP_BPS = 0` initially, then enable cost recovery |

---

## 8. Final Architecture (Production)

```
USER'S MOBILE APP (your existing app)
  └── Mobile wallet (signs initial auth only)
  └── Webview loads valinity.app

USER'S DESKTOP BROWSER
  └── MetaMask / WalletConnect for initial auth
  └── Webdapp at valinity.app

VALINITY WEBDAPP (deployed to CDN)
  ├── Permissionless.js + Safe SDK
  ├── Session keys in localStorage
  ├── UserOp construction
  └── Submits to Bundler RPC

YOUR BUNDLER INFRASTRUCTURE
  ├── Skandha instance 1 (primary VPS)
  ├── Skandha instance 2 (backup VPS, different provider)
  └── Refill bot (monitors and triggers Paymaster.refillHype)

HYPEREVM MAINNET (chain 999)
  ├── EntryPoint v0.7 (singleton, official)
  ├── Safe contracts (singletons)
  ├── User's Smart Wallets (one per user, auto-deployed)
  ├── Paymaster (your custom contract)
  ├── PerpCore (from PERP_SPEC.md, unchanged)
  ├── BackstopVault (from PERP_SPEC.md, unchanged)
  ├── Oracle (from PERP_SPEC.md, unchanged)
  └── HyperSwap USDC/HYPE pool (for Paymaster refills)

ETHEREUM (separate scope)
  └── Staking contract that bridges USDC to BackstopVault (out of this spec)
```

---

## 9. Cost Estimate

### One-time costs
- EntryPoint deployment: ~$200 in HYPE (if needed)
- Safe contracts deployment: ~$500 in HYPE (if needed)
- Paymaster deployment: ~$50 in HYPE
- Perp contracts audit: $50-100k
- Paymaster audit: $10-20k
- Total one-time: ~$60-120k

### Ongoing monthly costs
- Bundler VPS (×2 for redundancy): ~$60-100/mo
- Paymaster HYPE float: depends on volume (~1000 HYPE = ~$40k locked but recovered)
- Monitoring/alerting (e.g., Datadog free tier or PagerDuty starter): ~$20-50/mo
- CDN hosting for webdapp: ~$20-50/mo
- Total monthly: ~$100-200/mo + capital locked in Paymaster

### Per-trade economics
- HyperEVM gas per trade: ~250k gas × low gas price = ~$0.005
- Paymaster markup 10% = $0.0055 charged to user
- User experience: imperceptible cost, no HYPE needed, no signing

---

## 10. Summary: What This Document Says

**You build:**
1. One smart contract (Paymaster, ~150 lines)
2. One frontend (webdapp using existing libraries)
3. One devops setup (Skandha bundler on VPS)

**You use (don't build):**
- EntryPoint (official EIP-4337 contract)
- Safe + 4337 module (audited Smart Wallet)
- Permissionless.js (SDK)
- Skandha (bundler software)

**No changes to:**
- PerpCore
- BackstopVault
- Oracle
- Your existing mobile wallet

**Total timeline parallel to perp contract build:**
- 4-6 weeks for Paymaster + Bundler + Frontend MVP
- Aligns with perp contracts' audit window
- Ready to launch when perp contracts are ready

---

## 11. Next Concrete Action

**This week:** Run the verification checklist in §4. Confirm what's deployed, what needs to be deployed, and the HyperEVM ERC-4337 ecosystem status. Once confirmed:

1. Spec out the Paymaster contract in detail (`PAYMASTER_SPEC.md`)
2. Begin Bundler infrastructure setup
3. Begin frontend foundation work

---

---

## 12. Paymaster Contract Specification (Full Spec — Ready To Implement)

This section is the deployment-ready specification for the Paymaster contract. Same level of detail as PERP_SPEC.md. The dev team can implement directly from this.

### 12.1 Overview

The Paymaster contract is the only NEW smart contract you build (beyond the perp contracts). It sponsors HYPE gas for users trading on the VY perp, and recovers the cost as USDC from the user's Smart Wallet balance.

**Key properties:**
- Only sponsors transactions to whitelisted contracts (PerpCore, BackstopVault)
- Distinguishes between OPEN operations (require pre-balance check) and CLOSE operations (skip check; funds released by tx)
- Pulls USDC from user's Smart Wallet via approve + transferFrom pattern
- Self-replenishing via permissionless `refillHype()` function (swaps accumulated USDC → HYPE on HyperSwap)
- Immutable contract (no admin keys, no upgrades)
- Targets ERC-4337 v0.7 EntryPoint

### 12.2 Imports & Interface

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPaymaster} from "@account-abstraction/contracts/interfaces/IPaymaster.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

interface IWHYPE {
    function withdraw(uint256) external;
    function deposit() external payable;
}

interface IPerpCoreSelectors {
    function openPosition(bool isLong, uint128 size, uint16 leverageBps, uint128 maxSlippageBps) external returns (uint256);
    function closePosition(uint256 positionId, uint128 maxSlippageBps) external returns (int256);
    function addMargin(uint256 positionId, uint128 amount) external;
    function removeMargin(uint256 positionId, uint128 amount) external;
    function placeLimitOrder(bool, uint128, uint16, uint128, uint128, uint64) external returns (uint256);
    function placeStopLoss(uint256, uint128, uint128) external returns (uint256);
    function placeTakeProfit(uint256, uint128, uint128) external returns (uint256);
    function cancelOrder(uint256) external;
}

interface IERC4626Selectors {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

contract VyPaymaster is IPaymaster, ReentrancyGuard {
    using SafeERC20 for IERC20;
    ...
}
```

### 12.3 State Variables

```solidity
// Immutable references (set in constructor)
IEntryPoint public immutable ENTRY_POINT;
IERC20 public immutable USDC;
address public immutable WHYPE;                       // Wrapped HYPE on HyperEVM
address public immutable PERP_CORE;                   // whitelist target #1
address public immutable BACKSTOP_VAULT;              // whitelist target #2
address public immutable HYPERSWAP_ROUTER;            // for USDC → HYPE refill
address public immutable HYPERSWAP_USDC_HYPE_POOL;    // for spot price reading

// Function selectors (immutable for gas efficiency)
// Open-like (require user USDC balance):
bytes4 public immutable OPEN_POSITION_SEL;
bytes4 public immutable ADD_MARGIN_SEL;
bytes4 public immutable PLACE_LIMIT_ORDER_SEL;
bytes4 public immutable PLACE_STOP_LOSS_SEL;
bytes4 public immutable PLACE_TAKE_PROFIT_SEL;
bytes4 public immutable VAULT_DEPOSIT_SEL;
bytes4 public immutable VAULT_MINT_SEL;

// Close-like (funds released by tx, skip balance check):
bytes4 public immutable CLOSE_POSITION_SEL;
bytes4 public immutable REMOVE_MARGIN_SEL;
bytes4 public immutable CANCEL_ORDER_SEL;
bytes4 public immutable VAULT_WITHDRAW_SEL;
bytes4 public immutable VAULT_REDEEM_SEL;

// Analytics (not load-bearing)
mapping(address => uint256) public totalGasSpentByUser;
uint256 public totalUserOpsSponsored;
uint256 public totalUSDCCollected;
uint256 public totalHYPESpent;

// Constants
uint256 public constant USDC_MARKUP_BPS = 1000;          // 10% markup on actual gas
uint256 public constant MIN_REFILL_USDC = 100e6;         // $100 minimum to trigger refill
uint256 public constant REFILL_SLIPPAGE_BPS_MAX = 500;   // 5% max acceptable slippage
uint256 public constant REFILL_CALLER_REWARD_BPS = 10;   // 0.1% of swapped USDC to caller
```

### 12.4 Constructor

```solidity
constructor(
    address _entryPoint,
    address _usdc,
    address _whype,
    address _perpCore,
    address _backstopVault,
    address _hyperSwapRouter,
    address _hyperSwapUsdcHypePool
) {
    if (_entryPoint == address(0)) revert ZeroAddress();
    if (_usdc == address(0)) revert ZeroAddress();
    if (_whype == address(0)) revert ZeroAddress();
    if (_perpCore == address(0)) revert ZeroAddress();
    if (_backstopVault == address(0)) revert ZeroAddress();
    if (_hyperSwapRouter == address(0)) revert ZeroAddress();
    if (_hyperSwapUsdcHypePool == address(0)) revert ZeroAddress();
    
    ENTRY_POINT = IEntryPoint(_entryPoint);
    USDC = IERC20(_usdc);
    WHYPE = _whype;
    PERP_CORE = _perpCore;
    BACKSTOP_VAULT = _backstopVault;
    HYPERSWAP_ROUTER = _hyperSwapRouter;
    HYPERSWAP_USDC_HYPE_POOL = _hyperSwapUsdcHypePool;
    
    // Pre-compute selectors (cached as immutables for runtime efficiency)
    OPEN_POSITION_SEL = IPerpCoreSelectors.openPosition.selector;
    ADD_MARGIN_SEL = IPerpCoreSelectors.addMargin.selector;
    PLACE_LIMIT_ORDER_SEL = IPerpCoreSelectors.placeLimitOrder.selector;
    PLACE_STOP_LOSS_SEL = IPerpCoreSelectors.placeStopLoss.selector;
    PLACE_TAKE_PROFIT_SEL = IPerpCoreSelectors.placeTakeProfit.selector;
    VAULT_DEPOSIT_SEL = IERC4626Selectors.deposit.selector;
    VAULT_MINT_SEL = IERC4626Selectors.mint.selector;
    
    CLOSE_POSITION_SEL = IPerpCoreSelectors.closePosition.selector;
    REMOVE_MARGIN_SEL = IPerpCoreSelectors.removeMargin.selector;
    CANCEL_ORDER_SEL = IPerpCoreSelectors.cancelOrder.selector;
    VAULT_WITHDRAW_SEL = IERC4626Selectors.withdraw.selector;
    VAULT_REDEEM_SEL = IERC4626Selectors.redeem.selector;
}

// Allow receiving HYPE (native) for refills
receive() external payable {}
```

### 12.5 validatePaymasterUserOp (called by EntryPoint before execution)

```solidity
function validatePaymasterUserOp(
    PackedUserOperation calldata userOp,
    bytes32 /* userOpHash */,
    uint256 maxCost
) external view override returns (bytes memory context, uint256 validationData) {
    if (msg.sender != address(ENTRY_POINT)) revert NotEntryPoint();
    
    // Decode the call target and inner function from userOp.callData
    // The exact format depends on the Smart Wallet implementation.
    // For Safe + 4337 module, callData starts with executeUserOp(target, value, data, operation)
    // Dev team MUST verify this decoder matches the chosen Smart Wallet's callData format.
    (address target, bytes4 innerSelector) = _decodeExecuteCall(userOp.callData);
    
    // Whitelist check
    if (target != PERP_CORE && target != BACKSTOP_VAULT) {
        revert NotWhitelisted();
    }
    
    bool isOpen = _isOpenOperation(target, innerSelector);
    bool isClose = _isCloseOperation(target, innerSelector);
    
    if (!isOpen && !isClose) {
        revert UnsupportedFunction();
    }
    
    // For OPEN operations, verify user has enough USDC AND allowance
    if (isOpen) {
        uint256 maxUsdcCost = _maxCostInUsdc(maxCost);
        
        if (USDC.balanceOf(userOp.sender) < maxUsdcCost) {
            revert InsufficientUserUSDC();
        }
        if (USDC.allowance(userOp.sender, address(this)) < maxUsdcCost) {
            revert InsufficientUserAllowance();
        }
    }
    // For CLOSE operations: skip checks. User may have zero USDC right now,
    // but the close will release margin/PnL to their Smart Wallet, which postOp will draw from.
    
    context = abi.encode(userOp.sender);
    validationData = 0;  // 0 = always valid (no time/signature constraints)
}
```

### 12.6 _decodeExecuteCall (internal helper)

This decoder assumes Safe + 4337 module pattern. **Verify against chosen Smart Wallet implementation before deployment.**

```solidity
function _decodeExecuteCall(bytes calldata callData) 
    internal 
    pure 
    returns (address target, bytes4 innerSelector) 
{
    // Safe 4337 module's executeUserOp signature:
    //   executeUserOp(address to, uint256 value, bytes calldata data, uint8 operation)
    //
    // Layout in calldata (after Safe wraps the user's intended call):
    //   [0:4]      executeUserOp selector
    //   [4:36]     target address (padded to 32 bytes)
    //   [36:68]    value (uint256)
    //   [68:100]   offset to bytes (typically 0x80 = 128)
    //   [100:132]  operation (uint8 padded)
    //   [132:164]  length of data
    //   [164:168]  innerSelector (first 4 bytes of the wrapped call data)
    //
    // Dev team: confirm exact layout from Safe documentation OR
    // adapt to ZeroDev Kernel / other Smart Wallet if chosen differently.
    
    if (callData.length < 168) revert InvalidCallData();
    
    target = address(uint160(uint256(bytes32(callData[4:36]))));
    
    // Read length of inner data
    uint256 innerDataLen = uint256(bytes32(callData[132:164]));
    if (innerDataLen < 4) revert InvalidCallData();
    if (callData.length < 168) revert InvalidCallData();
    
    innerSelector = bytes4(callData[164:168]);
}
```

> **Critical implementation note:** The exact layout depends on the Smart Wallet. The above is the canonical Safe 4337 pattern. If using ZeroDev Kernel, Biconomy, or another implementation, **the dev team must adjust this decoder accordingly**. Test against the actual Smart Wallet on testnet before deployment.

### 12.7 postOp (called by EntryPoint after execution)

```solidity
function postOp(
    PostOpMode /* mode */,
    bytes calldata context,
    uint256 actualGasCost,
    uint256 /* actualUserOpFeePerGas */
) external override {
    if (msg.sender != address(ENTRY_POINT)) revert NotEntryPoint();
    
    address user = abi.decode(context, (address));
    
    uint256 hypeUsdcPrice = _getHypeUsdcPrice();
    uint256 usdcToCharge = (actualGasCost * hypeUsdcPrice * (10000 + USDC_MARKUP_BPS)) 
                          / (1e18 * 10000);
    
    // For close ops, user now has released USDC; transferFrom succeeds
    // For open ops, we pre-validated balance + allowance; transferFrom succeeds
    // try/catch handles unexpected failures gracefully (protocol absorbs cost in rare cases)
    try this._pullUSDC(user, usdcToCharge) {
        totalGasSpentByUser[user] += usdcToCharge;
        totalUSDCCollected += usdcToCharge;
        totalHYPESpent += actualGasCost;
        totalUserOpsSponsored += 1;
        emit GasPaid(user, actualGasCost, usdcToCharge);
    } catch {
        emit UncollectedGas(user, actualGasCost, usdcToCharge);
    }
}

function _pullUSDC(address user, uint256 amount) external {
    require(msg.sender == address(this), "ONLY_SELF");  // for try/catch only
    USDC.safeTransferFrom(user, address(this), amount);
}
```

### 12.8 refillHype (permissionless)

```solidity
function refillHype(uint256 minHypeOut, uint256 deadline) 
    external 
    nonReentrant 
{
    uint256 usdcBalance = USDC.balanceOf(address(this));
    if (usdcBalance < MIN_REFILL_USDC) revert RefillTooSmall();
    if (deadline < block.timestamp) revert DeadlinePassed();
    
    // Carve out caller reward (incentive for triggering refills)
    uint256 callerReward = (usdcBalance * REFILL_CALLER_REWARD_BPS) / 10000;
    uint256 usdcToSwap = usdcBalance - callerReward;
    
    // Approve router and swap
    USDC.safeApprove(HYPERSWAP_ROUTER, usdcToSwap);
    
    address[] memory path = new address[](2);
    path[0] = address(USDC);
    path[1] = WHYPE;
    
    uint[] memory amounts = IUniswapV2Router02(HYPERSWAP_ROUTER).swapExactTokensForTokens(
        usdcToSwap,
        minHypeOut,
        path,
        address(this),
        deadline
    );
    
    USDC.safeApprove(HYPERSWAP_ROUTER, 0);
    
    uint256 hypeReceived = amounts[1];
    
    // Unwrap WHYPE → native HYPE
    IWHYPE(WHYPE).withdraw(hypeReceived);
    
    // Deposit HYPE to EntryPoint as paymaster's gas budget
    ENTRY_POINT.depositTo{value: hypeReceived}(address(this));
    
    // Pay caller reward in USDC
    if (callerReward > 0) {
        USDC.safeTransfer(msg.sender, callerReward);
    }
    
    emit Refilled(usdcToSwap, hypeReceived, msg.sender, callerReward);
}
```

### 12.9 EntryPoint Stake Management

ERC-4337 v0.7 requires paymasters to stake with EntryPoint:

```solidity
function addStake(uint32 unstakeDelaySec) external payable {
    ENTRY_POINT.addStake{value: msg.value}(unstakeDelaySec);
}

function unlockStake() external {
    ENTRY_POINT.unlockStake();
}

function withdrawStake(address payable withdrawAddress) external {
    if (withdrawAddress != address(this)) revert OnlySelf();
    ENTRY_POINT.withdrawStake(withdrawAddress);
}

function deposit() external payable {
    ENTRY_POINT.depositTo{value: msg.value}(address(this));
}

function getDeposit() external view returns (uint256) {
    return ENTRY_POINT.balanceOf(address(this));
}
```

These are intentionally permissionless. Anyone can fund the stake or deposit. Only the contract itself can receive withdrawals.

### 12.10 Price Oracle Helper

```solidity
function _getHypeUsdcPrice() internal view returns (uint256 priceUsdcPer1HYPE) {
    // Reads HyperSwap USDC/HYPE pool spot price.
    // Returns: USDC (6 decimals) per 1 HYPE (1e18)
    
    (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(HYPERSWAP_USDC_HYPE_POOL).getReserves();
    address token0 = IUniswapV2Pair(HYPERSWAP_USDC_HYPE_POOL).token0();
    
    if (token0 == address(USDC)) {
        // reserves: USDC=reserve0 (6 dec), HYPE=reserve1 (18 dec)
        priceUsdcPer1HYPE = (uint256(reserve0) * 1e18) / uint256(reserve1);
    } else {
        // reserves: HYPE=reserve0 (18 dec), USDC=reserve1 (6 dec)
        priceUsdcPer1HYPE = (uint256(reserve1) * 1e18) / uint256(reserve0);
    }
}

function _maxCostInUsdc(uint256 maxCost) internal view returns (uint256) {
    uint256 hypeUsdcPrice = _getHypeUsdcPrice();
    return (maxCost * hypeUsdcPrice * (10000 + USDC_MARKUP_BPS)) / (1e18 * 10000);
}
```

> **Production recommendation:** Spot price is manipulable. For production, replace with a TWAP over a 5-30 minute window (Uniswap V2 pools support cumulative price reads). Or use the VY Oracle's HYPE/USD price (which already reads HyperCore precompile). This is a security-relevant choice — verify before mainnet.

### 12.11 Operation Type Helpers

```solidity
function _isOpenOperation(address target, bytes4 selector) internal view returns (bool) {
    if (target == PERP_CORE) {
        return selector == OPEN_POSITION_SEL
            || selector == ADD_MARGIN_SEL
            || selector == PLACE_LIMIT_ORDER_SEL
            || selector == PLACE_STOP_LOSS_SEL
            || selector == PLACE_TAKE_PROFIT_SEL;
    }
    if (target == BACKSTOP_VAULT) {
        return selector == VAULT_DEPOSIT_SEL
            || selector == VAULT_MINT_SEL;
    }
    return false;
}

function _isCloseOperation(address target, bytes4 selector) internal view returns (bool) {
    if (target == PERP_CORE) {
        return selector == CLOSE_POSITION_SEL
            || selector == REMOVE_MARGIN_SEL
            || selector == CANCEL_ORDER_SEL;
    }
    if (target == BACKSTOP_VAULT) {
        return selector == VAULT_WITHDRAW_SEL
            || selector == VAULT_REDEEM_SEL;
    }
    return false;
}
```

### 12.12 Events

```solidity
event GasPaid(address indexed user, uint256 hypeGasCost, uint256 usdcCharged);
event UncollectedGas(address indexed user, uint256 hypeGasCost, uint256 usdcOwed);
event Refilled(uint256 usdcSwapped, uint256 hypeReceived, address indexed caller, uint256 callerReward);
```

### 12.13 Custom Errors

```solidity
error NotEntryPoint();
error NotWhitelisted();
error UnsupportedFunction();
error InsufficientUserUSDC();
error InsufficientUserAllowance();
error RefillTooSmall();
error InvalidCallData();
error DeadlinePassed();
error OnlySelf();
error ZeroAddress();
```

### 12.14 Critical Invariants (For Foundry Testing)

| ID | Invariant |
|---|---|
| **INV-P1** | Only EntryPoint can call `validatePaymasterUserOp` and `postOp` |
| **INV-P2** | Only `PERP_CORE` or `BACKSTOP_VAULT` are valid call targets in validation |
| **INV-P3** | `validatePaymasterUserOp` reverts for unsupported function selectors |
| **INV-P4** | For OPEN ops, `USDC.balanceOf(user) >= maxCost_in_USDC` at validation time |
| **INV-P5** | For OPEN ops, `USDC.allowance(user, paymaster) >= maxCost_in_USDC` at validation time |
| **INV-P6** | `postOp` either pulls actual USDC cost OR emits `UncollectedGas` event (never silently swallows) |
| **INV-P7** | `refillHype` only succeeds if `USDC.balanceOf(this) >= MIN_REFILL_USDC` |
| **INV-P8** | `refillHype` caller reward never exceeds `0.1%` of USDC swapped |
| **INV-P9** | HYPE received from swap respects `minHypeOut` slippage guarantee |
| **INV-P10** | All immutable addresses (ENTRY_POINT, USDC, WHYPE, PERP_CORE, BACKSTOP_VAULT, etc.) never change |
| **INV-P11** | Paymaster's USDC balance only decreases via `refillHype` or `callerReward` payments |
| **INV-P12** | Paymaster's HYPE balance flows: in via `swap` or `deposit`, out only via `EntryPoint.depositTo` (gas) |

### 12.15 Test Plan

**Unit tests:**
- [ ] `validatePaymasterUserOp` accepts whitelisted PerpCore call
- [ ] `validatePaymasterUserOp` accepts whitelisted BackstopVault call
- [ ] `validatePaymasterUserOp` rejects non-whitelisted target (revert NotWhitelisted)
- [ ] `validatePaymasterUserOp` rejects unsupported function selector
- [ ] `validatePaymasterUserOp` requires USDC balance for OPEN ops
- [ ] `validatePaymasterUserOp` requires allowance for OPEN ops
- [ ] `validatePaymasterUserOp` SKIPS balance check for CLOSE ops (user can have 0 USDC)
- [ ] `postOp` correctly converts HYPE → USDC with 10% markup
- [ ] `postOp` handles transferFrom success path correctly
- [ ] `postOp` handles transferFrom failure → emits UncollectedGas event
- [ ] `refillHype` reverts if accumulated USDC < MIN_REFILL_USDC
- [ ] `refillHype` reverts if slippage exceeds minHypeOut
- [ ] `refillHype` correctly computes caller reward
- [ ] `refillHype` deposits resulting HYPE to EntryPoint
- [ ] Stake management functions work correctly
- [ ] Only EntryPoint can call validate / postOp (others revert)

**Integration tests:**
- [ ] Full UserOp flow: open position → paymaster sponsors → user USDC drops by margin + gas
- [ ] Close position with empty Smart Wallet USDC: succeeds, postOp pulls from released margin
- [ ] Open with insufficient USDC: reverts at validation, no on-chain side effects
- [ ] Multi-UserOp bundle: paymaster handles correctly
- [ ] refillHype after 100 UserOps actually swaps and refills

**Foundry invariant tests:**
- [ ] All 12 invariants hold across 100,000 fuzzed operation sequences
- [ ] Paymaster never enters insolvent state (HYPE balance + USDC value > unpaid sponsored ops)

### 12.16 Deployment Sequence

```
Prerequisites verified:
  ☐ PerpCore deployed at known address
  ☐ BackstopVault deployed at known address  
  ☐ EntryPoint v0.7 deployed at 0x0000000071727De22E5E9d8BAf0edAc6f37da032 (or alt address verified)
  ☐ WHYPE address known
  ☐ HyperSwap USDC/HYPE pool exists with >$50k liquidity
  ☐ HyperSwap router address known

Deployment steps:
  1. Deploy VyPaymaster:
     constructor args:
       _entryPoint: <ENTRY_POINT_ADDR>
       _usdc: <USDC_ADDR>
       _whype: <WHYPE_ADDR>
       _perpCore: <PERP_CORE_ADDR>
       _backstopVault: <BACKSTOP_VAULT_ADDR>
       _hyperSwapRouter: <HYPERSWAP_ROUTER_ADDR>
       _hyperSwapUsdcHypePool: <USDC_HYPE_POOL_ADDR>
  
  2. Verify Paymaster on HyperEVM block explorer
  
  3. Fund Paymaster with initial HYPE:
     - Send native HYPE to paymaster.deposit{value: amount}()
     - Recommended initial: 100 HYPE (~$4000)
  
  4. Stake with EntryPoint:
     - Call paymaster.addStake{value: STAKE_AMOUNT}(unstakeDelaySec)
     - STAKE_AMOUNT: 10 HYPE (~$400)
     - unstakeDelaySec: 86400 (1 day)
  
  5. Verify stake/deposit:
     - Call ENTRY_POINT.getDepositInfo(paymasterAddress)
     - Expect: deposit > 0, stake > 0, unstakeDelaySec set
  
  6. Configure Bundler to use this Paymaster:
     - Update bundler config with paymaster address
     - Test single UserOp end-to-end on testnet first
  
  7. Verify single UserOp flow:
     - Deploy a test user's Smart Wallet
     - User approves USDC to PerpCore and Paymaster
     - User signs and submits openPosition UserOp
     - Verify position opens AND user's USDC decreased by margin + gas markup
  
  8. Start refill bot (optional but recommended):
     - Monitor paymaster USDC balance
     - When USDC >= MIN_REFILL_USDC and HYPE balance < threshold, call refillHype
```

### 12.17 Operational Parameters (Initial Launch)

| Parameter | Initial Value | Rationale |
|---|---|---|
| `USDC_MARKUP_BPS` | 1000 (10%) | Covers refill slippage + small operating margin |
| `MIN_REFILL_USDC` | 100e6 ($100) | Avoids wasteful tiny swaps |
| `REFILL_CALLER_REWARD_BPS` | 10 (0.1%) | Incentivizes bots to trigger refills |
| `REFILL_SLIPPAGE_BPS_MAX` | 500 (5%) | Bound on refill swap slippage acceptance |
| Initial HYPE float | 100 HYPE (~$4000) | Sufficient for ~800,000 trades at 250k gas each |
| EntryPoint stake | 10 HYPE (~$400) | Required minimum, deters griefing |
| Unstake delay | 86400 sec (1 day) | Allows recovery in emergency |

### 12.18 Open Items For Implementation (Decisions Before Deployment)

| Item | Question | Recommended Default |
|---|---|---|
| Smart Wallet implementation | Which wallet? Affects `_decodeExecuteCall` | Safe + 4337 module |
| Price oracle for HYPE/USDC | Spot, TWAP, or HyperCore precompile? | TWAP (5-30 min window) — production safety |
| WHYPE address | Find canonical wrapped HYPE on HyperEVM | Look up at deploy time |
| HyperSwap version | V2 or V3? Code assumes V2 router interface | Verify HyperSwap deployment |
| Refill bot operator | Who runs the bot? | You initially; permissionless so community can too |
| Initial gas subsidization | Sponsor free for first 30 days? | Optional — set MARKUP_BPS to 0 initially |
| ChainSecurity vs Spearbit for audit | Which firm? | Either works for ~150 LOC Paymaster (~$10-20k) |

### 12.19 Estimated Bytecode Size

~6-8 KB (well under 24KB limit). Single contract, no library dependencies beyond OpenZeppelin imports.

### 12.20 Build Effort Summary

| Phase | Effort |
|---|---|
| Implementation | 1-2 weeks (experienced Solidity dev) |
| Unit tests | 1 week |
| Integration tests | 1 week (requires Smart Wallet + EntryPoint test setup) |
| Foundry invariant tests | 3-5 days |
| Internal review | 2-3 days |
| External audit | 1-2 weeks (Paymasters audit fast) |
| **Total** | **5-7 weeks from start to audit-clean** |

---

## END OF DOCUMENT

Send this alongside `PERP_SPEC.md` to your dev team. The perp team owns the perp contracts (PERP_SPEC.md). The infrastructure team owns this document, which now contains the full Paymaster spec (§12) plus all the operational guidance for deploying the ERC-4337 stack.
