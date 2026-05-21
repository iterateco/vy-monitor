# VY Perpetual Protocol — Smart Contract Specification

**Version:** 1.0
**Target:** Production deployment on HyperEVM
**Reference architecture:** Oracle-priced, vault-as-counterparty perp (GMX V2 conceptual model)
**Constraint:** Fully immutable contracts, no admin keys, no upgrades

---

## 0. Executive Summary

Build a perpetual futures protocol for the VY token, deployed on **HyperEVM** (Hyperliquid's smart contract layer). The protocol consists of **3 immutable contracts**:

1. **PerpCore** — positions, margin, fees, limit orders, insurance, funding, fee routing
2. **BackstopVault** — ERC-4626 USDC vault that absorbs bad debt and earns yield
3. **Oracle** — derives VY/USD from HyperCore precompile (HYPE/USD) and HyperSwap pool (VY/HYPE TWAP)

Traders deposit USDC, open leveraged long/short positions, pay fees and funding. The vault is the implicit counterparty (vault-as-counterparty model). Bad debt from liquidations is absorbed first by an internal insurance reserve, then by the BackstopVault.

A portion of fees and funding is bridged to a pre-existing **VPOhl contract** on HyperEVM (address provided at deploy time) which forwards USDC to Ethereum via LayerZero for VY buybacks.

---

## 1. Hard Constraints (Non-Negotiable)

- **Immutability:** Zero admin keys after deployment. Zero upgrade paths. Zero parameter changes ever.
- **One-time setter pattern:** The only constructor-time admin allowed is a one-time `setPerpCore()` call on BackstopVault, which `renounces` itself after first call. Use a `bool initialized` flag.
- **Permissionless everywhere:** Liquidations, limit order executions, oracle updates, vault deposits/withdrawals, buyback bridge triggers — all callable by anyone.
- **No external oracles** beyond HyperCore precompiles and on-chain HyperSwap reads. No Chainlink, no Pyth, no LayerZero in the oracle path.
- **VPOhl contract handles the buyback bridge.** PerpCore just calls `USDC.transfer(VPOhl_ADDRESS, amount)`.
- **HyperEVM only.** All 3 contracts deploy on HyperEVM mainnet (chain ID 999).
- **Solidity:** Use `pragma solidity 0.8.24` (Cancun-compatible). Use `unchecked` blocks judiciously for gas where overflow is impossible.
- **No proxy patterns.** No transparent proxy, no UUPS, no diamond. Direct deployment only.

---

## 2. Architecture

```
                        ┌─────────────────────────────────────┐
                        │         HyperEVM (chain 999)        │
                        ├─────────────────────────────────────┤
                        │                                     │
   TRADERS    ────►     │   ┌──────────────────────────┐      │
                        │   │       PerpCore           │      │
                        │   │                          │      │
                        │   │ • Positions (by ID)      │      │
                        │   │ • Limit Orders           │      │
                        │   │ • Margin                 │      │
                        │   │ • Fee splitting          │      │
                        │   │ • Insurance balance      │      │
                        │   │ • Funding accrual        │      │
                        │   └──────┬──────┬────────────┘      │
                        │          │      │                   │
                        │ bad debt │      │ buyback share     │
                        │          ▼      ▼                   │
                        │   ┌──────────┐ ┌──────────────┐     │
   DEPOSITORS  ─────►   │   │BackstopV │ │  VPOhl       │ ──► LayerZero ──► ETH
                        │   │  (4626)  │ │  (existing)  │     │
                        │   └──────────┘ └──────────────┘     │
                        │                                     │
                        │   ┌──────────────────────────┐      │
                        │   │       Oracle             │      │
                        │   │ • HyperCore precompile   │      │
                        │   │   (HYPE/USD price)       │      │
                        │   │ • HyperSwap pool TWAPs   │      │
                        │   │   (VY/HYPE 5min/1h/24h)  │      │
                        │   │ • Pause flag             │      │
                        │   └──────────────────────────┘      │
                        │                                     │
                        └─────────────────────────────────────┘
```

### Deployment order

1. Libraries (no dependencies)
2. Oracle (deps: HYPE perp asset index, HyperSwap pool address, HYPE szDecimals)
3. BackstopVault (deps: USDC address)
4. PerpCore (deps: Oracle addr, BackstopVault addr, VPOhl addr, USDC addr)
5. Call `BackstopVault.setPerpCore(perpCoreAddress)` — one-time initialization, then renounces

### Contract size note

PerpCore is large. Use **libraries aggressively** (PnLMath, FeeMath, OracleMath, MarginMath, FeeCurveMath). If still over 24KB, split limit orders into a separate `OrderBook` contract owned-and-coupled to PerpCore. **Only split if necessary.**

---

## 3. Contract: PerpCore

### 3.1 Imports & Inheritance

```solidity
import {ReentrancyGuard} from "openzeppelin/security/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IBackstopVault} from "./interfaces/IBackstopVault.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {PnLMath} from "./libs/PnLMath.sol";
import {FeeCurveMath} from "./libs/FeeCurveMath.sol";

contract PerpCore is ReentrancyGuard {
    using SafeERC20 for IERC20;
    ...
}
```

### 3.2 Structs and Enums

```solidity
struct Position {
    address owner;
    bool isLong;
    uint64 lastFundingIndex;     // signed funding index when last interacted
    uint128 size;                 // notional in VY units (18 decimals)
    uint128 entryPrice;           // VY/USD at entry (18 decimals)
    uint128 margin;               // USDC margin (6 decimals)
    uint32 openTimestamp;
    uint32 maintenanceBreachAt;   // 0 if not breached; timestamp of first breach (for liq fee ramp)
}

enum OrderType { LIMIT_OPEN, STOP_LOSS, TAKE_PROFIT }

struct Order {
    address owner;
    OrderType orderType;
    bool isLong;
    uint128 size;                 // VY notional
    uint16 leverage;              // basis points (1000 = 10x)
    uint128 triggerPrice;         // VY/USD price (18 decimals)
    uint128 maxSlippageBps;
    uint64 expiry;                // 0 = never
    uint128 marginLocked;         // USDC pre-locked for LIMIT_OPEN; 0 for SL/TP
    uint256 linkedPositionId;     // 0 for LIMIT_OPEN; positionId for SL/TP
}
```

### 3.3 State Variables

```solidity
// Immutable references (set in constructor)
IERC20 public immutable USDC;
IBackstopVault public immutable BACKSTOP_VAULT;
IOracle public immutable ORACLE;
address public immutable VPOhl;            // existing buyback bridge contract

// Position storage
mapping(uint256 => Position) public positions;
uint256 public nextPositionId = 1;          // start at 1; 0 means "doesn't exist"
mapping(address => uint256[]) public userPositionIds;
mapping(uint256 => uint256) public positionIdToUserIndex;  // for O(1) array removal

// Order storage
mapping(uint256 => Order) public orders;
uint256 public nextOrderId = 1;
mapping(address => uint256[]) public userOrderIds;
mapping(uint256 => uint256) public orderIdToUserIndex;

// Global accumulators
uint256 public totalLongSize;               // sum of all long position sizes (in VY units)
uint256 public totalShortSize;              // sum of all short position sizes
uint256 public totalMarginHeld;             // sum of all open position margins
uint256 public lockedOrderMargin;           // sum of all marginLocked in active orders
uint256 public insuranceBalance;            // 10% of fees, first-loss buffer
uint256 public unbridgedBuyback;            // accumulated USDC waiting to ship to VPOhl

// Funding state (signed cumulative index, scaled 1e18)
int256 public cumulativeFundingIndex;       // signed; positive = longs paid net
uint64 public lastFundingTime;
uint256 public pendingFundingExcess;        // USDC accumulated from imbalanced funding (over-side aggregate paid - under-side aggregate received). Flushed to FeeRouter periodically.
```

### 3.4 Immutable Constants

```solidity
// Fees (basis points, where 100 = 1.00%)
uint16 public constant TAKER_FEE_BPS = 10;       // 0.10%
uint16 public constant MAKER_FEE_BPS = 6;        // 0.06%
uint16 public constant KEEPER_REWARD_BPS = 2;    // 0.02% of notional from maker fee

// Liquidation
uint16 public constant LIQ_FEE_MIN_BPS = 200;    // 2% (basis points)
uint16 public constant LIQ_FEE_MAX_BPS = 500;    // 5%
uint32 public constant LIQ_FEE_RAMP_SECS = 30;   // 2% → 5% over 30s

// Fee split (LOCKED — constant, no dynamic curve)
// Vault gets 0% of trading fees because depositors are compensated via VY yield from VYO on ETH
// (cross-chain integration documented in §15)
uint16 public constant BUYBACK_SHARE_BPS = 9000;    // 90% to VPOhl (max VY price impact)
uint16 public constant INSURANCE_SHARE_BPS = 1000;  // 10% to insurance reserve (first-loss buffer)
// Vault share = 0 (computed: 10000 - 9000 - 1000 = 0)

// Position limits
uint16 public constant MAX_POSITION_PCT_BPS = 1000; // 10% of vault TVL
uint128 public constant MIN_ORDER_NOTIONAL = 100e6; // $100 USDC for limit orders (note: original was $200, see §3.6)

// Leverage tiers (positionPctOfVault → maxLeverage)
//   < 0.5%     → 50x  (5000 bps)
//   0.5-2%     → 20x  (2000 bps)
//   2-5%       → 10x  (1000 bps)
//   5-10%      → 3x   (300 bps)
//   > 10%      → blocked
uint16 public constant LEV_TIER1_MAX_BPS = 5000;
uint16 public constant LEV_TIER2_MAX_BPS = 2000;
uint16 public constant LEV_TIER3_MAX_BPS = 1000;
uint16 public constant LEV_TIER4_MAX_BPS = 300;

// Maintenance margin (50% of initial margin)
uint16 public constant MAINTENANCE_MARGIN_PCT_BPS = 5000;

// Funding
uint16 public constant FUNDING_CAP_BPS_PER_HOUR = 5;  // ±0.05%/hr
uint32 public constant FUNDING_PERIOD = 3600;          // 1 hour

// Min order notional for limit orders (set to $200 per locked decision)
uint128 public constant MIN_LIMIT_ORDER_NOTIONAL = 200e6;
```

> **Note to dev team:** `MIN_ORDER_NOTIONAL` and `MIN_LIMIT_ORDER_NOTIONAL` may overlap. Final decision: **min limit order notional is $200 USDC**. There is no minimum for market orders (any size up to position cap).

### 3.5 Constructor

```solidity
constructor(
    address _usdc,
    address _vault,
    address _oracle,
    address _vpoHl
) {
    require(_usdc != address(0), "ZERO_USDC");
    require(_vault != address(0), "ZERO_VAULT");
    require(_oracle != address(0), "ZERO_ORACLE");
    require(_vpoHl != address(0), "ZERO_VPOHL");

    USDC = IERC20(_usdc);
    BACKSTOP_VAULT = IBackstopVault(_vault);
    ORACLE = IOracle(_oracle);
    VPOhl = _vpoHl;

    lastFundingTime = uint64(block.timestamp);
}
```

### 3.6 Public Functions — Trading

#### 3.6.1 openPosition (market order)

```solidity
function openPosition(
    bool isLong,
    uint128 size,                // VY units (18 decimals)
    uint16 leverageBps,
    uint128 maxSlippageBps
) external nonReentrant returns (uint256 positionId);
```

**Behavior:**

1. Update oracle: `ORACLE.update()` (no-op if too soon)
2. Read price: `uint256 price = ORACLE.getPrice()` — reverts if oracle paused
3. Accrue funding for the system (`_accrueFunding()`)
4. Compute notional: `notional = size × price / 1e18` (USDC 6-decimal precision)
5. Check max position size: `notional <= MAX_POSITION_PCT_BPS × vault.totalAssets() / 10000` — revert if exceeded
6. Check leverage tier: lookup `maxLevForTier(notional, vaultTVL)`, revert if `leverageBps > maxLev`
7. Compute required margin: `margin = notional × 10000 / leverageBps` (in USDC)
8. Compute fee: `fee = notional × TAKER_FEE_BPS / 10000`
9. Pull `margin + fee` USDC from `msg.sender`
10. Distribute `fee` via `_distributeFees(fee)`
11. Increment `nextPositionId`, create Position struct
12. Update `totalLongSize` or `totalShortSize`
13. Update `totalMarginHeld += margin`
14. Add to `userPositionIds[msg.sender]` and `positionIdToUserIndex`
15. Slippage check: revert if oracle moved past `maxSlippageBps` between price read and now (compare to second oracle read)
16. Emit `PositionOpened`
17. Run post-conditions assertions (see §10)

**Returns:** the new positionId

#### 3.6.2 closePosition

```solidity
function closePosition(
    uint256 positionId,
    uint128 maxSlippageBps
) external nonReentrant returns (int256 pnl);
```

**Behavior:**

1. `Position storage p = positions[positionId]`
2. `require(p.owner == msg.sender, "NOT_OWNER")`
3. `ORACLE.update()`; `uint256 price = ORACLE.getPrice()` (allowed even when paused — see §6.3)
4. `_accrueFunding()` and `_settleFundingForPosition(p)`
5. Compute PnL via PnLMath: `pnl = (price - p.entryPrice) × p.size / 1e18` for long; negate for short
6. Compute fee: `fee = (p.size × price / 1e18) × TAKER_FEE_BPS / 10000`
7. Compute payout: `payout = int256(p.margin) + pnl - int256(fee)`
8. If `payout < 0`: this is bad debt
   - `_absorbBadDebt(uint256(-payout))` — handles insurance + vault
   - `payout = 0`
9. Update accumulators (`totalLongSize`/`totalShortSize` decreases, `totalMarginHeld` decreases)
10. `_distributeFees(fee)`
11. Remove from user position arrays
12. `delete positions[positionId]`
13. If `payout > 0`: `USDC.safeTransfer(msg.sender, uint256(payout))`
14. Emit `PositionClosed`
15. Post-condition assertions

#### 3.6.3 addMargin / removeMargin

```solidity
function addMargin(uint256 positionId, uint128 amount) external nonReentrant;
function removeMargin(uint256 positionId, uint128 amount) external nonReentrant;
```

**addMargin:** owner-only. Pulls USDC, increases `p.margin`, increases `totalMarginHeld`. Emits `MarginUpdated`.

**removeMargin:** owner-only. Reverts if removal would drop position below maintenance margin (computed at current oracle price). Decrements `p.margin`, transfers USDC out. Emits `MarginUpdated`.

#### 3.6.4 liquidate

```solidity
function liquidate(uint256 positionId) external nonReentrant returns (uint256 reward);
```

**Behavior:**

1. `Position storage p = positions[positionId]`
2. `require(p.owner != address(0), "NO_POSITION")`
3. `_accrueFunding()`; `_settleFundingForPosition(p)`
4. `uint256 price = ORACLE.getPrice()` — but if oracle paused, use **last known good price** stored in PerpCore (see §6.3 for last-good-price mechanism)
5. Compute current margin requirement: `req = (p.size × price / 1e18) × MAINTENANCE_MARGIN_PCT_BPS / 10000` divided by leverage
   - More precise: `maintenanceMargin = initialMargin × MAINTENANCE_MARGIN_PCT_BPS / 10000`
6. Check liquidatable: `require(p.margin < maintenanceMargin OR p.margin + pnl < maintenanceMargin)`
7. If position breach is new (`p.maintenanceBreachAt == 0`), set `p.maintenanceBreachAt = block.timestamp`
8. Compute liquidator reward (dynamic 2-5%):
   - `elapsed = block.timestamp - p.maintenanceBreachAt`
   - `feeBps = LIQ_FEE_MIN_BPS + (LIQ_FEE_MAX_BPS - LIQ_FEE_MIN_BPS) × min(elapsed, LIQ_FEE_RAMP_SECS) / LIQ_FEE_RAMP_SECS`
   - `reward = p.margin × feeBps / 10000`
   - But cap reward at remaining margin after pnl
9. Compute closure: similar to closePosition but at oracle price, with reward going to msg.sender
10. Bad debt absorbed by insurance → vault
11. Send reward to liquidator
12. Remove position
13. Emit `PositionLiquidated(positionId, owner, msg.sender, exitPrice, reward, badDebt)`

#### 3.6.5 _accrueFunding (internal, called by every state-changing function)

```solidity
function _accrueFunding() internal;
```

**Critical model:** Funding is **trader-to-trader**, NOT trader-to-protocol. The over-side pays funding, the under-side receives it (proportional to position size). This is what creates the arbitrage incentive that bots will exploit to rebalance OI. Without this, the system has no self-correcting mechanism.

The asymmetry from imbalanced OI (over-side aggregate > under-side aggregate) accumulates as `pendingFundingExcess` and flows to `FeeRouter` periodically. The vault is implicitly the counterparty for the imbalance.

**Behavior:**

1. `uint256 elapsed = block.timestamp - lastFundingTime`
2. If `elapsed < FUNDING_PERIOD`, return (no accrual yet)
3. `uint256 totalOI = totalLongSize + totalShortSize`
4. If `totalOI == 0`: just update `lastFundingTime` and return (nothing to accrue)
5. Compute funding rate based on OI imbalance (signed):
   - `int256 imbalance = (int256(totalLongSize) - int256(totalShortSize)) × 1e18 / int256(totalOI)`
   - `int256 ratePerPeriod = imbalance × int256(FUNDING_CAP_BPS_PER_HOUR) / 1e18` (clamped to [-cap, +cap])
   - Positive = longs paying; negative = shorts paying
6. `uint256 periods = elapsed / FUNDING_PERIOD`
7. Update `cumulativeFundingIndex += ratePerPeriod × int256(periods) × 1e14` (scaled to 1e18 precision)
8. **Compute aggregate excess for this accrual** (over-side aggregate minus under-side aggregate):
   - If `ratePerPeriod > 0`:
     - Longs aggregate paid: `longSize × ratePerPeriod × periods`
     - Shorts aggregate received: `shortSize × ratePerPeriod × periods`
     - `excess = (longSize - shortSize) × |ratePerPeriod| × periods` (in USDC, after scaling)
   - If `ratePerPeriod < 0`:
     - `excess = (shortSize - longSize) × |ratePerPeriod| × periods`
   - `excess >= 0` always (over-side is always defined as the larger one)
9. `pendingFundingExcess += excess` (accumulates as expected vault revenue)
10. Update `lastFundingTime += periods × FUNDING_PERIOD` (preserve fractional remainder)
11. Emit `FundingAccrued(ratePerPeriod, cumulativeFundingIndex)`

> **Funding distribution:** `pendingFundingExcess` accumulates over time. It can be flushed via:
> - **Auto-flush:** at the end of `_accrueFunding`, if `pendingFundingExcess > MIN_FLUSH_AMOUNT` (e.g., 10 USDC), call `_distributeFees(pendingFundingExcess)` and reset.
> - **Manual flush:** permissionless `flushFundingExcess()` function anyone can call.
>
> Recommended: auto-flush at every accrual. Keeps revenue moving.

> **Note:** Per-position funding settles **lazily** when each position next interacts (see §3.8.3). The aggregate `pendingFundingExcess` is computed at accrual time and represents what will eventually be left over after all positions settle.

> **Implementation alert:** The actual USDC movement for funding requires careful accounting. Recommended approach:
> - Per-position settlement: index delta × position size, signed application to margin
> - Aggregate excess tracked separately at accrual
> - Net funding flows: longs' margin decreases by their share, shorts' margin increases by their share, the excess sits in `pendingFundingExcess` ready to flow to fee router
> - When a position closes/liquidates, its margin reflects all accrued funding to that point
>
> **Have your dev team study GMX V2's funding + settlement implementation** for a battle-tested pattern. Funding math is the easiest place to introduce subtle bugs.

### 3.7 Public Functions — Limit Orders

#### 3.7.1 placeLimitOrder

```solidity
function placeLimitOrder(
    bool isLong,
    uint128 size,
    uint16 leverage,
    uint128 triggerPrice,
    uint128 maxSlippageBps,
    uint64 expiry            // 0 for never
) external nonReentrant returns (uint256 orderId);
```

**Behavior:**

1. `require(size × triggerPrice / 1e18 >= MIN_LIMIT_ORDER_NOTIONAL, "TOO_SMALL")`
2. `require(triggerPrice > 0, "INVALID_PRICE")`
3. `require(expiry == 0 || expiry > block.timestamp, "EXPIRED")`
4. Compute required margin: `margin = (size × triggerPrice / 1e18) × 10000 / leverage`
5. Pull `margin` USDC from msg.sender (locked until execution or cancel)
6. Validate against current `maxPositionSize` based on vault TVL
7. Validate leverage against tier for this size
8. Create Order, increment `nextOrderId`
9. Add to `userOrderIds[msg.sender]`
10. `lockedOrderMargin += margin`
11. Emit `OrderPlaced`

#### 3.7.2 placeStopLoss / placeTakeProfit

```solidity
function placeStopLoss(uint256 positionId, uint128 triggerPrice, uint128 maxSlippageBps) 
    external nonReentrant returns (uint256 orderId);
function placeTakeProfit(uint256 positionId, uint128 triggerPrice, uint128 maxSlippageBps)
    external nonReentrant returns (uint256 orderId);
```

**Behavior:**

1. `require(positions[positionId].owner == msg.sender, "NOT_POSITION_OWNER")`
2. `require(triggerPrice > 0)`
3. Validate trigger direction makes sense (e.g., SL on long must be below current price; TP on long must be above)
4. Create Order with `linkedPositionId = positionId`, `marginLocked = 0`
5. No margin lock needed (closes existing position)
6. Emit `OrderPlaced`

#### 3.7.3 cancelOrder

```solidity
function cancelOrder(uint256 orderId) external nonReentrant;
```

**Behavior:**

1. `require(orders[orderId].owner == msg.sender, "NOT_OWNER")`
2. If LIMIT_OPEN: refund `marginLocked` USDC to owner; `lockedOrderMargin -= marginLocked`
3. Remove from user order array
4. `delete orders[orderId]`
5. Emit `OrderCanceled`

#### 3.7.4 executeOrder (permissionless)

```solidity
function executeOrder(uint256 orderId) external nonReentrant returns (uint256 keeperReward);
```

**Behavior:**

1. `Order memory o = orders[orderId]`
2. `require(o.owner != address(0), "NO_ORDER")`
3. `require(!ORACLE.isPaused(), "ORACLE_PAUSED")` — execution blocked when oracle is paused
4. If `o.expiry > 0 && block.timestamp > o.expiry`:
   - For LIMIT_OPEN: refund margin, delete order, give caller a small cleanup reward (e.g., 0.5 USDC from insurance? OR no reward — TBD; recommend no reward to keep simple)
   - Emit `OrderExpired`; return 0
5. Read current oracle price
6. Validate trigger condition met (see Trigger Logic table below); revert if not
7. Validate slippage: oracle price within `o.maxSlippageBps` of `o.triggerPrice`; revert if not
8. **For LIMIT_OPEN:**
   - Open position using locked margin (similar to `openPosition` but skipping margin pull)
   - Charge maker fee: `fee = notional × MAKER_FEE_BPS / 10000`
   - Carve out keeper reward: `keeperReward = notional × KEEPER_REWARD_BPS / 10000`
   - Remaining fee: `feeAfterKeeper = fee - keeperReward`
   - `_distributeFees(feeAfterKeeper)`
   - `lockedOrderMargin -= o.marginLocked`
9. **For STOP_LOSS / TAKE_PROFIT:**
   - Validate `positions[o.linkedPositionId].owner == o.owner` (auto-cancel if position closed)
   - Close position similar to `closePosition` but at oracle price
   - Charge maker fee, carve out keeper reward
   - Send PnL to owner
10. Pay `keeperReward` to `msg.sender`
11. Delete order
12. Emit `OrderExecuted(orderId, keeper, positionId, executionPrice, keeperReward, totalFee)`

#### Trigger Condition Logic

| Order Type | Side / Position direction | Executable when |
|---|---|---|
| LIMIT_OPEN | Long | `oraclePrice <= triggerPrice` |
| LIMIT_OPEN | Short | `oraclePrice >= triggerPrice` |
| STOP_LOSS | Linked position is long | `oraclePrice <= triggerPrice` |
| STOP_LOSS | Linked position is short | `oraclePrice >= triggerPrice` |
| TAKE_PROFIT | Linked position is long | `oraclePrice >= triggerPrice` |
| TAKE_PROFIT | Linked position is short | `oraclePrice <= triggerPrice` |

### 3.8 Internal Functions

#### 3.8.1 _distributeFees

```solidity
function _distributeFees(uint256 amount) internal;
```

**Behavior:**

1. Compute constant split (no TVL read, no curve math):
   - `buybackAmount = amount × BUYBACK_SHARE_BPS / 10000`  // 90%
   - `insuranceAmount = amount - buybackAmount`              // 10% (remainder)
2. **Accumulate buyback:** `unbridgedBuyback += buybackAmount` (USDC stays in PerpCore)
3. **Increment insurance:** `insuranceBalance += insuranceAmount` (USDC stays in PerpCore)
4. Emit `FeesDistributed(0, buybackAmount, insuranceAmount)` — vault always 0

**No vault USDC flow from trading fees.** Vault USDC only changes from:
- Public `deposit()` / `mint()` calls (anyone, increases vault assets)
- Public `withdraw()` / `redeem()` calls (anyone with shares, decreases vault assets)
- Bad debt absorption via `coverBadDebt` (PerpCore only, decreases vault assets — permanent)

Vault depositors who want yield go through the ETH-side staking contract (out of scope here). Direct HL depositors get vault shares but no yield. See §15.

#### 3.8.2 _absorbBadDebt

```solidity
function _absorbBadDebt(uint256 amount) internal;
```

**Behavior:**

1. If `insuranceBalance >= amount`:
   - `insuranceBalance -= amount`
   - return (insurance fully covers, vault untouched)
2. Else:
   - `uint256 fromInsurance = insuranceBalance`
   - `uint256 fromVault = amount - fromInsurance`
   - `insuranceBalance = 0`
   - Call `BACKSTOP_VAULT.absorbBadDebt(fromVault)` — vault is informed; we transfer USDC there to cover
   - But wait: the bad debt means there's NOT enough USDC. So instead we tell the vault to mark down its assets:
     - **Correct mechanism:** The vault's `totalAssets()` is computed as `USDC.balanceOf(vault) - pendingBadDebt`. PerpCore calls `vault.absorbBadDebt(fromVault)` which increments a `pendingBadDebt` counter on the vault, reducing its reported assets.
     - Or simpler: vault holds the actual USDC needed. PerpCore pulls USDC from vault to cover.
     - **Recommended pattern:** PerpCore calls `vault.transferToCover(fromVault, recipient)` which transfers USDC from vault to wherever it needs to go (e.g., to a closing trader's payout). Vault depositors lose value pro-rata.
3. Emit `BadDebtAbsorbed(fromInsurance, fromVault)`

> **Critical for dev team:** Bad debt mechanics need careful design. The simplest model:
> - When liquidation can't cover, PerpCore needs USDC to pay out (or to fill the gap in its own accounting)
> - PerpCore calls `vault.coverBadDebt(amount, recipient)` 
> - Vault transfers `amount` USDC out (to cover the gap)
> - Vault's `totalAssets()` drops by `amount`, depositors' shares are now worth less
> - This is the cleanest pattern; implement via direct USDC transfer from vault.

#### 3.8.3 _settleFundingForPosition

```solidity
function _settleFundingForPosition(Position storage p) internal;
```

**Critical model:** Settlement is symmetric trader-to-trader. Over-side positions PAY funding (margin decreases). Under-side positions RECEIVE funding (margin increases). The aggregate asymmetry from imbalanced OI is captured separately in `pendingFundingExcess` at accrual time (§3.6.5), not at settlement time.

**Behavior:**

1. `int256 indexDelta = cumulativeFundingIndex - int256(uint256(p.lastFundingIndex))`
2. If `indexDelta == 0`: just update `p.lastFundingIndex` and return
3. `int256 fundingAmount = indexDelta × int256(uint256(p.size)) / 1e18`
   - Note: `fundingAmount` is signed. Positive `indexDelta` = longs net-paid this period.
4. **For LONG position (`p.isLong == true`):**
   - If `fundingAmount > 0`: longs are paying. `p.margin -= uint128(uint256(fundingAmount))` (margin decreases)
   - If `fundingAmount < 0`: longs are receiving (shorts were paying). `p.margin += uint128(uint256(-fundingAmount))` (margin increases)
5. **For SHORT position (`p.isLong == false`):**
   - If `fundingAmount > 0`: shorts are receiving. `p.margin += uint128(uint256(fundingAmount))` (margin increases)
   - If `fundingAmount < 0`: shorts are paying. `p.margin -= uint128(uint256(-fundingAmount))` (margin decreases)
6. **Underflow guard:** If margin would go below 0:
   - Set margin to 0
   - Mark position for immediate liquidation (set `maintenanceBreachAt = block.timestamp` if not already set)
   - This is now bad debt territory; liquidation will absorb via insurance/vault
7. Update `p.lastFundingIndex = uint64(uint256(cumulativeFundingIndex))` (cast safely, handle sign)
8. Emit nothing (settlement is internal; covered by `FundingAccrued` and position interaction events)

**Why this matters:**
- Bots opening positions on the under-side EARN funding directly into their margin
- This is what makes funding arb profitable — no protocol take on the trader-to-trader portion
- Bots will naturally come correct OI imbalances within minutes (see §13)

> **Reference implementation:** See GMX V2's `MarketUtils.sol` (`getNextFundingFactorPerSecond`, `getFundingAmountPerSizeDelta`) and `PositionPricingUtils.sol` (`getFundingFees`). **Concrete pattern locked below — implement to match this.**

#### GMX V2 Funding Pattern (LOCKED IMPLEMENTATION)

This is the exact pattern to implement. Adapted from GMX V2 with our specific simplifications (no separate borrowing rate, no claimable balances split — direct margin adjustment).

```solidity
// State (already in §3.3)
int256 public cumulativeFundingFeeAmountPerSize;  // signed; magnitude in USDC per VY-size unit, scaled by FLOAT_PRECISION
uint64 public lastFundingTime;
uint256 public pendingFundingExcess;

// Constants
uint256 internal constant FLOAT_PRECISION = 1e18;

// In Position struct, replace `lastFundingIndex` with:
int256 fundingFeeAmountPerSizeAtLastUpdate;  // value of cumulativeFundingFeeAmountPerSize when this position last interacted
```

**Accrual (`_accrueFunding`):**

```solidity
function _accrueFunding() internal {
    uint256 elapsed = block.timestamp - lastFundingTime;
    if (elapsed < FUNDING_PERIOD) return;
    
    uint256 totalOI = totalLongSize + totalShortSize;
    if (totalOI == 0) {
        lastFundingTime = uint64(block.timestamp);
        return;
    }
    
    uint256 periods = elapsed / FUNDING_PERIOD;
    
    // Compute funding rate (signed): positive = longs pay
    int256 imbalance = (int256(totalLongSize) - int256(totalShortSize)) * int256(FLOAT_PRECISION) / int256(totalOI);
    int256 ratePerPeriod = imbalance * int256(uint256(FUNDING_CAP_BPS_PER_HOUR)) / int256(FLOAT_PRECISION);
    // Note: ratePerPeriod is in basis points per period. To convert to USDC-per-VY-size-unit-per-period:
    // deltaPerSize = (ratePerPeriod_bps * indexPrice_USDperVY) / 10000
    
    uint256 indexPrice = ORACLE.getPrice();  // 1e18-scaled USD per VY
    
    // Per-size delta (USDC per unit of VY size)
    int256 deltaPerSize = ratePerPeriod * int256(indexPrice) * int256(periods) 
                         / int256(uint256(10000)) / int256(FLOAT_PRECISION);
    // deltaPerSize is positive when longs pay
    
    cumulativeFundingFeeAmountPerSize += deltaPerSize;
    
    // Compute aggregate excess (over-side aggregate paid - under-side aggregate received)
    uint256 absDelta = deltaPerSize >= 0 ? uint256(deltaPerSize) : uint256(-deltaPerSize);
    uint256 imbalanceSize = totalLongSize > totalShortSize 
        ? totalLongSize - totalShortSize 
        : totalShortSize - totalLongSize;
    uint256 excess = imbalanceSize * absDelta / FLOAT_PRECISION;
    pendingFundingExcess += excess;
    
    lastFundingTime += uint64(periods * FUNDING_PERIOD);
    
    // Auto-flush if accumulated enough
    if (pendingFundingExcess >= FUNDING_FLUSH_THRESHOLD) {
        uint256 toFlush = pendingFundingExcess;
        pendingFundingExcess = 0;
        _distributeFees(toFlush);
        emit FundingExcessFlushed(toFlush);
    }
    
    emit FundingAccrued(deltaPerSize, cumulativeFundingFeeAmountPerSize);
}
```

**Per-position settlement (`_settleFundingForPosition`):**

```solidity
function _settleFundingForPosition(Position storage p) internal {
    int256 indexDelta = cumulativeFundingFeeAmountPerSize - p.fundingFeeAmountPerSizeAtLastUpdate;
    if (indexDelta == 0) return;
    
    // fundingAmount: signed USDC; positive value = longs net paid this period
    int256 fundingAmount = indexDelta * int256(uint256(p.size)) / int256(FLOAT_PRECISION);
    
    // Apply to margin based on side
    if (p.isLong) {
        // Long: positive fundingAmount means LONG pays (margin decreases)
        if (fundingAmount > 0) {
            uint256 amt = uint256(fundingAmount);
            if (amt >= p.margin) {
                p.margin = 0;
                if (p.maintenanceBreachAt == 0) p.maintenanceBreachAt = uint32(block.timestamp);
            } else {
                p.margin = uint128(uint256(p.margin) - amt);
            }
        } else {
            // negative: long receives (shorts paid)
            p.margin = uint128(uint256(p.margin) + uint256(-fundingAmount));
        }
    } else {
        // Short: positive fundingAmount means SHORT receives (margin increases)
        if (fundingAmount > 0) {
            p.margin = uint128(uint256(p.margin) + uint256(fundingAmount));
        } else {
            uint256 amt = uint256(-fundingAmount);
            if (amt >= p.margin) {
                p.margin = 0;
                if (p.maintenanceBreachAt == 0) p.maintenanceBreachAt = uint32(block.timestamp);
            } else {
                p.margin = uint128(uint256(p.margin) - amt);
            }
        }
    }
    
    p.fundingFeeAmountPerSizeAtLastUpdate = cumulativeFundingFeeAmountPerSize;
}
```

**Constants to add:**
```solidity
uint256 public constant FUNDING_FLUSH_THRESHOLD = 10e6;  // 10 USDC; auto-flush at this threshold
```

**Sign convention summary:**
- `cumulativeFundingFeeAmountPerSize > 0` (increased over time): longs have been paying
- `cumulativeFundingFeeAmountPerSize < 0` (decreased over time): shorts have been paying
- `indexDelta = current - lastUpdate`
- For LONG position: `fundingAmount > 0` means we owe funding (deduct from margin)
- For SHORT position: `fundingAmount > 0` means we receive funding (add to margin)
- `pendingFundingExcess` always grows monotonically (over-side aggregate always > under-side aggregate when imbalanced)

### 3.9 View Functions

```solidity
function getPosition(uint256 positionId) external view returns (Position memory);
function getOrder(uint256 orderId) external view returns (Order memory);

function getMarkPrice() external view returns (uint256);  // ORACLE.getPrice()
function getFundingRate() external view returns (int256); // current rate based on OI imbalance

function getMaintenanceMargin(uint256 positionId) external view returns (uint256);
function isLiquidatable(uint256 positionId) external view returns (bool);

function getMaxPositionSize() external view returns (uint256); // 10% of vault TVL in USDC
function getMaxLeverageForSize(uint128 sizeNotional) external view returns (uint16); // tier lookup

function getOpenInterest() external view returns (uint256 longOI, uint256 shortOI);

function getCurrentFeeSplit() external view returns (
    uint16 vaultBps,
    uint16 buybackBps,
    uint16 insuranceBps
);

function getUserPositions(address user) external view returns (uint256[] memory);
function getUserPositionCount(address user) external view returns (uint256);
function getUserOrders(address user) external view returns (uint256[] memory);

function openInterest() external view returns (uint256); // longOI + shortOI in USDC
```

### 3.10 Flush Funding Excess (permissionless)

```solidity
function flushFundingExcess() external {
    uint256 amount = pendingFundingExcess;
    require(amount > 0, "NOTHING_TO_FLUSH");
    pendingFundingExcess = 0;
    _distributeFees(amount);
    emit FundingExcessFlushed(amount);
}
```

Anyone can call this to push accumulated funding excess into the fee distribution flow (which then routes to vault/buyback/insurance per the dynamic curve). Recommended: also auto-call this at the end of `_accrueFunding` if the accumulated amount exceeds a threshold (e.g., 10 USDC) to keep revenue moving.

### 3.11 Triggering Buyback Bridge

The buyback share accumulates in `unbridgedBuyback`. Anyone can ship it:

```solidity
function triggerBuybackBridge() external {
    uint256 amount = unbridgedBuyback;
    require(amount > 0, "NOTHING_TO_BRIDGE");
    unbridgedBuyback = 0;
    USDC.safeTransfer(VPOhl, amount);
    emit BuybackBridged(amount);
}
```

Optional: minimum threshold (e.g., only ship if `amount >= 100e6`) to avoid wasteful tiny transfers. **Recommendation: set MIN_BRIDGE_AMOUNT = 100 USDC.**

### 3.12 Events

```solidity
event PositionOpened(
    uint256 indexed positionId,
    address indexed owner,
    bool isLong,
    uint128 size,
    uint128 entryPrice,
    uint128 margin,
    uint128 fee
);

event PositionClosed(
    uint256 indexed positionId,
    address indexed owner,
    uint128 exitPrice,
    int256 pnl,
    uint128 fee
);

event PositionLiquidated(
    uint256 indexed positionId,
    address indexed owner,
    address indexed liquidator,
    uint128 exitPrice,
    uint128 reward,
    uint256 badDebt
);

event MarginUpdated(uint256 indexed positionId, uint128 newMargin);

event OrderPlaced(
    uint256 indexed orderId,
    address indexed owner,
    OrderType orderType,
    bool isLong,
    uint128 size,
    uint16 leverage,
    uint128 triggerPrice,
    uint64 expiry,
    uint256 linkedPositionId
);

event OrderCanceled(uint256 indexed orderId, address indexed owner);

event OrderExecuted(
    uint256 indexed orderId,
    address indexed keeper,
    uint256 indexed positionId,
    uint128 executionPrice,
    uint128 keeperReward,
    uint128 totalFee
);

event OrderExpired(uint256 indexed orderId);

event FeesDistributed(uint256 vaultAmount, uint256 buybackAmount, uint256 insuranceAmount);

event FundingAccrued(int256 rate, int256 cumulativeIndex);

event FundingExcessFlushed(uint256 amount);

event BadDebtAbsorbed(uint256 fromInsurance, uint256 fromVault);

event BuybackBridged(uint256 amount);
```

---

## 4. Contract: BackstopVault (Standard ERC-4626)

**Standard ERC-4626 USDC vault with one extra function (`coverBadDebt`).** Permissionless deposit/withdraw, no locks, no fees, no yield distribution. The contract just holds USDC that backs PerpCore trades and absorbs bad debt.

The ETH-side staking contract is the primary depositor (it bridges USDC from ETH and deposits on behalf of stakers); however, anyone can deposit directly on HL. Direct depositors get vault shares but earn no yield from this contract. Yield-earning users go through the ETH staking contract (handled in a separate spec).

### 4.1 Inheritance

```solidity
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract BackstopVault is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    ...
}
```

### 4.2 State Variables

```solidity
// Set once after deployment via setPerpCore()
address public perpCore;
bool public initialized;

// Analytics (not load-bearing)
uint256 public totalBadDebtAbsorbed;

// Anti-inflation parameters
uint256 public constant MIN_FIRST_DEPOSIT = 1000e6;  // $1000 USDC minimum first deposit
uint256 public constant DEAD_SHARES = 1000;          // dead shares minted on first deposit (sent to address(0))
```

The vault inherits all standard ERC-4626 state (totalSupply, balanceOf via ERC20, asset, etc.). No custom share tracking needed.

### 4.3 Constructor

```solidity
constructor(address _usdc, string memory _name, string memory _symbol)
    ERC4626(IERC20(_usdc))
    ERC20(_name, _symbol)
{
    if (_usdc == address(0)) revert ZeroAddress();
    // perpCore set later via setPerpCore()
}
```

Recommended naming: `name = "Valinity Backstop Vault"`, `symbol = "vBV"`.

### 4.4 setPerpCore (one-time initialization)

```solidity
function setPerpCore(address _perpCore) external {
    if (initialized) revert AlreadyInitialized();
    if (_perpCore == address(0)) revert ZeroAddress();
    perpCore = _perpCore;
    initialized = true;
}
```

After this single call, no admin function exists. Contract is fully immutable.

### 4.5 Deposit With Anti-Inflation Protection

Override `deposit` to enforce first-deposit minimum and mint dead shares to address(0):

```solidity
function deposit(uint256 assets, address receiver) 
    public 
    override 
    nonReentrant 
    returns (uint256 shares) 
{
    if (totalSupply() == 0) {
        // First depositor: enforce minimum, mint dead shares
        if (assets < MIN_FIRST_DEPOSIT) revert FirstDepositTooSmall();
        _mint(address(0), DEAD_SHARES);
    }
    return super.deposit(assets, receiver);
}

function mint(uint256 shares, address receiver) 
    public 
    override 
    nonReentrant 
    returns (uint256 assets) 
{
    if (totalSupply() == 0) {
        // First mint: enforce minimum and dead shares
        assets = previewMint(shares);
        if (assets < MIN_FIRST_DEPOSIT) revert FirstDepositTooSmall();
        _mint(address(0), DEAD_SHARES);
    }
    return super.mint(shares, receiver);
}
```

The dead shares + minimum first deposit prevent the classic ERC-4626 inflation attack where the first depositor manipulates share price.

### 4.6 Withdraw and Redeem (Standard, No Overrides Needed)

```solidity
// Inherited unchanged from OZ ERC-4626:
function withdraw(uint256 assets, address receiver, address owner) 
    public override returns (uint256 shares);

function redeem(uint256 shares, address receiver, address owner) 
    public override returns (uint256 assets);
```

Anyone with shares can withdraw at any time. No locks, no fees, no restrictions. If bad debt has occurred, the share value is reduced — withdrawer receives proportional USDC.

Apply `nonReentrant` modifier on overrides if any custom logic added; OZ implementation is already safe.

### 4.7 coverBadDebt (called by PerpCore only)

```solidity
function coverBadDebt(uint256 amount, address recipient) external nonReentrant {
    if (msg.sender != perpCore) revert NotPerpCore();
    if (amount > totalAssets()) revert InsufficientVault();
    
    totalBadDebtAbsorbed += amount;
    SafeERC20.safeTransfer(IERC20(asset()), recipient, amount);
    
    emit BadDebtAbsorbed(amount, totalAssets());
}
```

USDC physically leaves the vault. `totalSupply` (shares) unchanged. Each share is now worth less. **This loss is permanent.** No mechanism in this spec restores vault USDC after bad debt.

### 4.8 View Functions

All standard ERC-4626 views inherited:
- `totalAssets()` returns USDC balance
- `convertToShares(uint256 assets)` 
- `convertToAssets(uint256 shares)`
- `previewDeposit`, `previewMint`, `previewWithdraw`, `previewRedeem`
- `maxDeposit`, `maxMint`, `maxWithdraw`, `maxRedeem`
- `balanceOf(address)` (ERC-20)
- `totalSupply()` (ERC-20)
- `asset()` returns USDC address

Custom view added:
```solidity
function getStats() external view returns (
    uint256 currentTVL,
    uint256 currentShares,
    uint256 totalBadDebt
) {
    return (totalAssets(), totalSupply(), totalBadDebtAbsorbed);
}
```

### 4.9 Events

Standard ERC-4626 events inherited (Deposit, Withdraw). Plus:

```solidity
event BadDebtAbsorbed(uint256 amount, uint256 newTotalAssets);
```

### 4.10 Custom Errors

```solidity
error AlreadyInitialized();
error NotPerpCore();
error InsufficientVault();
error FirstDepositTooSmall();
error ZeroAddress();
```

---

## 5. Contract: Oracle

### 5.1 Imports

```solidity
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
```

### 5.2 State Variables

```solidity
// Immutable references
address public immutable HYPERSWAP_POOL;     // VY/HYPE pool address
address public immutable HYPE_TOKEN;          // wrapped HYPE on HyperEVM
address public immutable VY_TOKEN;            // VY token on HyperEVM
uint256 public immutable HYPE_PERP_ASSET_INDEX;  // index in HyperCore for HYPE perp
uint256 public immutable HYPE_SZ_DECIMALS;       // szDecimals for HYPE perp on HC

// Pause state
bool public paused;
uint64 public lastPauseTime;
uint64 public lastUnpauseTime;

// Last known good price (fallback for liquidations during pause)
uint256 public lastGoodPrice;
uint64 public lastGoodPriceTime;
```

### 5.3 Constants

```solidity
address public constant PERP_ORACLE_PRECOMPILE = 0x0000000000000000000000000000000000000807;
uint16 public constant DIVERGENCE_PAUSE_BPS = 2000;       // 20%
uint16 public constant DIVERGENCE_UNPAUSE_BPS = 1000;     // 10% (hysteresis)
uint32 public constant TWAP_5MIN = 300;
uint32 public constant TWAP_1HOUR = 3600;
uint32 public constant TWAP_24HOUR = 86400;
uint32 public constant MAX_LAST_GOOD_PRICE_AGE = 86400;   // 24h
```

### 5.4 Constructor

```solidity
constructor(
    address _hyperSwapPool,
    address _hypeToken,
    address _vyToken,
    uint256 _hypePerpAssetIndex,
    uint256 _hypeSzDecimals
) {
    require(_hyperSwapPool != address(0));
    require(_hypeToken != address(0));
    require(_vyToken != address(0));

    HYPERSWAP_POOL = _hyperSwapPool;
    HYPE_TOKEN = _hypeToken;
    VY_TOKEN = _vyToken;
    HYPE_PERP_ASSET_INDEX = _hypePerpAssetIndex;
    HYPE_SZ_DECIMALS = _hypeSzDecimals;
}
```

### 5.5 getHypeUsd (read HyperCore precompile)

```solidity
function getHypeUsd() public view returns (uint256 hypeUsdPrice) {
    bytes memory input = abi.encode(HYPE_PERP_ASSET_INDEX);
    (bool ok, bytes memory ret) = PERP_ORACLE_PRECOMPILE.staticcall(input);
    require(ok, "PRECOMPILE_FAIL");
    require(ret.length >= 32, "INVALID_RETURN");
    
    uint256 raw = abi.decode(ret, (uint256));
    require(raw > 0, "ZERO_PRICE");
    
    // Scale: raw / 10^(6 - szDecimals), then to 1e18 precision
    // E.g., if szDecimals = 4, divisor = 10^2 = 100
    uint256 divisor = 10 ** (6 - HYPE_SZ_DECIMALS);
    hypeUsdPrice = raw * 1e18 / divisor;
}
```

> **Verify at deploy:** The exact format returned by `0x807` for HYPE perp. Test on testnet first. The above assumes `raw` is in `10^(6 - szDecimals)` scale units of USD per unit of HYPE.

### 5.6 getVyHypeTwap (read HyperSwap pool)

Use Uniswap V3 oracle library:

```solidity
function getVyHypeTwap(uint32 secondsAgo) public view returns (uint256 priceX18) {
    // Get the time-weighted average tick over `secondsAgo` seconds
    (int24 timeWeightedAverageTick, ) = OracleLibrary.consult(HYPERSWAP_POOL, secondsAgo);
    
    // Convert tick to price (token1 per token0, scaled to 1e18)
    // Need to know which token is VY and which is HYPE in the pool
    uint256 amountOut = OracleLibrary.getQuoteAtTick(
        timeWeightedAverageTick,
        1e18,           // 1 VY (assume VY has 18 decimals)
        VY_TOKEN,       // baseToken
        HYPE_TOKEN      // quoteToken
    );
    
    return amountOut;  // price of 1 VY in HYPE units (scaled 1e18)
}
```

> **Verify at deploy:** VY and HYPE token decimals; whether HyperSwap is V2 or V3 (this code assumes V3); the pool's tick spacing and observation cardinality (must be increased to support 24h TWAP — call `pool.increaseObservationCardinalityNext(N)` after deploying the pool).

### 5.7 getPrice (main oracle function)

```solidity
function getPrice() external view returns (uint256 vyUsdPrice) {
    require(!paused, "ORACLE_PAUSED");
    
    uint256 hypeUsd = getHypeUsd();
    
    uint256 twap5m = getVyHypeTwap(TWAP_5MIN);
    uint256 twap1h = getVyHypeTwap(TWAP_1HOUR);
    uint256 twap24h = getVyHypeTwap(TWAP_24HOUR);
    
    // Circuit breaker: pause if 5min vs 24h diverge >20%
    require(_within(twap5m, twap24h, DIVERGENCE_PAUSE_BPS), "CIRCUIT_BREAKER");
    
    uint256 medianVyHype = _median3(twap5m, twap1h, twap24h);
    
    // VY/USD = (HYPE/USD) × (VY/HYPE)
    vyUsdPrice = hypeUsd * medianVyHype / 1e18;
    require(vyUsdPrice > 0, "ZERO_PRICE");
}
```

### 5.8 update / pause / unpause

```solidity
function update() external {
    // Check current TWAPs and pause if circuit breaker fires
    uint256 twap5m;
    uint256 twap24h;
    
    try this.getVyHypeTwap(TWAP_5MIN) returns (uint256 t5) { twap5m = t5; }
    catch { _pause(); return; }
    
    try this.getVyHypeTwap(TWAP_24HOUR) returns (uint256 t24) { twap24h = t24; }
    catch { _pause(); return; }
    
    if (!_within(twap5m, twap24h, DIVERGENCE_PAUSE_BPS)) {
        _pause();
        return;
    }
    
    // Update last good price for fallback
    try this.getPrice() returns (uint256 p) {
        lastGoodPrice = p;
        lastGoodPriceTime = uint64(block.timestamp);
    } catch {}
}

function _pause() internal {
    if (!paused) {
        paused = true;
        lastPauseTime = uint64(block.timestamp);
        emit Paused();
    }
}

function tryUnpause() external {
    require(paused, "NOT_PAUSED");
    
    // Verify divergence is now within unpause hysteresis
    uint256 twap5m = getVyHypeTwap(TWAP_5MIN);
    uint256 twap24h = getVyHypeTwap(TWAP_24HOUR);
    require(_within(twap5m, twap24h, DIVERGENCE_UNPAUSE_BPS), "STILL_DIVERGENT");
    
    paused = false;
    lastUnpauseTime = uint64(block.timestamp);
    emit Unpaused();
}
```

### 5.9 getLastGoodPrice (for liquidations during pause)

```solidity
function getLastGoodPrice() external view returns (uint256 price, bool isFresh) {
    price = lastGoodPrice;
    isFresh = (block.timestamp - lastGoodPriceTime) < MAX_LAST_GOOD_PRICE_AGE;
}
```

PerpCore's `liquidate()` and `closePosition()` should call `getLastGoodPrice()` if `isPaused()`. If `!isFresh`, those functions should also revert (no safe price available).

### 5.10 Helper Functions

```solidity
function _median3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
    if (a > b) (a, b) = (b, a);
    if (b > c) (b, c) = (c, b);
    if (a > b) (a, b) = (b, a);
    return b;
}

function _within(uint256 a, uint256 b, uint256 maxBps) internal pure returns (bool) {
    if (a == 0 || b == 0) return false;
    uint256 diff = a > b ? a - b : b - a;
    uint256 base = a > b ? a : b;
    return diff * 10000 <= base * maxBps;
}
```

### 5.11 Events

```solidity
event Paused();
event Unpaused();
```

---

## 6. Critical Invariants (Test These)

The following invariants must be enforced as `assert()` post-conditions in state-changing functions and as Foundry invariant tests during fuzz testing.

### 6.1 Solvency

**INV-1** — `USDC.balanceOf(PerpCore) == totalMarginHeld + insuranceBalance + unbridgedBuyback + lockedOrderMargin + pendingFundingExcess`

**INV-2** — `USDC.balanceOf(BackstopVault) >= BackstopVault.totalAssets()` (after accounting for any tracked pending bad debt)

**INV-3** — All open positions have `margin >= 0` (no underflow)

**INV-4** — Sum of all positions' theoretical PnL relative to vault is bounded: `|sum(longPnL) + sum(shortPnL)| ≤ vault.totalAssets() × MAX_POSITION_PCT_BPS / 10000 × N` for N positions

### 6.2 Position Validity

**INV-5** — For all positions P: `P.size × oracle.getPrice() / 1e18 ≤ vault.totalAssets() × MAX_POSITION_PCT_BPS / 10000`

**INV-6** — For all positions P: leverage = `(P.size × oracle.getPrice() / 1e18) / P.margin ≤ maxLevForTier(P.size, vault.totalAssets())`

**INV-7** — For all open positions: `P.margin >= maintenanceMargin(P)` OR position is being liquidated in this same transaction

### 6.3 Order Validity

**INV-8** — `lockedOrderMargin == sum(orders[i].marginLocked for all active LIMIT_OPEN orders)`

**INV-9** — All active orders have `triggerPrice > 0` and `owner != address(0)`

**INV-10** — All LIMIT_OPEN orders have `size × triggerPrice / 1e18 >= MIN_LIMIT_ORDER_NOTIONAL`

### 6.4 Oracle Integrity

**INV-11** — `getPrice()` returns `min(twaps) <= medianResult <= max(twaps)`

**INV-12** — When `paused == true`, no calls to `getPrice()` succeed (revert)

**INV-13** — `tryUnpause()` succeeds only if current divergence is within `DIVERGENCE_UNPAUSE_BPS`

### 6.5 Vault

**INV-14** — `convertToAssets(convertToShares(x)) ≈ x` within 1 wei rounding (standard ERC-4626 round-trip)

**INV-15** — `totalSupply == sum(balanceOf(all holders))` (standard ERC-20)

**INV-16** — `totalAssets() == USDC.balanceOf(address(this))` (no virtual assets)

**INV-16a** — First deposit must be ≥ `MIN_FIRST_DEPOSIT` (1000 USDC) AND `DEAD_SHARES` (1000) minted to address(0) on first deposit (anti-inflation guard)

### 6.6 Fee Routing

**INV-17** — On every fee distribution: `BUYBACK_SHARE_BPS + INSURANCE_SHARE_BPS == 10000` (constants sum to 100%)

**INV-18** — Vault never receives USDC from `_distributeFees` (vault USDC flow comes only from external `deposit()` calls and is reduced only by `withdraw()`/`redeem()` and `coverBadDebt()`)

**INV-19** — `unbridgedBuyback` increases by exactly `amount × 9000 / 10000` per fee distribution

**INV-19a** — `insuranceBalance` increases by exactly `amount - buybackAmount` per fee distribution (remainder = 10%)

### 6.7 Consistency

**INV-20** — `totalLongSize == sum(positions[i].size where isLong[i])`
**INV-21** — `totalShortSize == sum(positions[i].size where !isLong[i])`
**INV-22** — For every position P with owner U: `P.id ∈ userPositionIds[U]`
**INV-23** — For every order O with owner U: `O.id ∈ userOrderIds[U]`

### 6.8 Funding Conservation

**INV-26** — Per-position funding settlement is symmetric: across all positions over a settlement period, `sum(long_margin_changes_from_funding) + sum(short_margin_changes_from_funding) + pendingFundingExcess_change == 0`. (Conservation law: USDC neither created nor destroyed by funding; just reallocated between positions, with imbalance excess going to `pendingFundingExcess`.)

**INV-27** — `pendingFundingExcess >= 0` always (excess can only accumulate, never go negative)

**INV-28** — Over any sequence of accruals where OI is balanced (longSize == shortSize), `pendingFundingExcess` increment is zero.

### 6.9 Reentrancy

**INV-24** — All state-changing external functions use `nonReentrant`
**INV-25** — All external calls (USDC transfers, vault calls) happen AFTER state updates (CEI pattern)

---

## 7. Test Plan

### 7.1 Unit Tests

For each contract, exhaustive unit tests covering:
- All public functions
- All require/revert conditions
- All branches in conditional logic
- All edge cases in math (zero, max, overflow boundaries)
- Event emissions

Coverage target: **100% line, 95%+ branch.**

### 7.2 Integration Tests

End-to-end flows:
- Trader deposits USDC, opens long, accrues funding, closes profitably → expect correct USDC balance change
- Trader opens, gets liquidated by gap move → expect vault absorbs bad debt correctly
- Vault depositor deposits, earns yield from trades, withdraws with fee → expect correct accounting
- Oracle pause cycle: trade in normal conditions, oracle diverges, pause triggers, traders can close, oracle re-converges, anyone unpauses
- Limit order full lifecycle: place, oracle reaches trigger, keeper executes, position opens, keeper paid

### 7.3 Foundry Invariant Tests

Run `forge test --invariant` for ≥ 100,000 fuzzed transaction sequences against each invariant in §6. **All 25 invariants must hold for every fuzzed state.**

Setup:
- Random actors deposit/withdraw vault, open/close positions, place/cancel/execute orders, liquidate positions
- Random oracle price perturbations (within reasonable bounds)
- Random time jumps (between blocks)
- After every operation, invariants are checked

### 7.4 Oracle Attack Simulations

Test scenarios specifically designed to manipulate oracle:
- **Pump-and-short:** Attacker pumps HyperSwap pool, opens short, dumps pool, closes short. Expected: position cap + multi-window TWAP + circuit breakers limit damage to <10% of vault TVL.
- **Sandwich liquidation:** Attacker sees a position near maintenance, manipulates pool to trigger liquidation, captures liquidator reward + spread. Expected: dynamic liquidator fee minimizes their advantage.
- **Stale oracle attack:** Long quiet period, attacker tries to force a single observation to dominate TWAP. Expected: 24-hour TWAP dampens this.

### 7.5 Black Swan Scenarios

- **VY drops 50% in single block** (gap move): expect mass liquidation cascade, vault absorbs bad debt, vault reports correct reduced TVL, depositors can withdraw (with elevated fee) but proportionally reduced.
- **HyperSwap pool drained to zero liquidity:** expect oracle pause, no new positions, existing positions can close at last-good-price.
- **Vault bank-run during stress:** all depositors try to withdraw simultaneously when utilization is 100%. Expect: dynamic withdrawal fees discourage but don't block.

### 7.6 Bridge Failure

- VPOhl contract is unreachable / reverts on transfer: expect `triggerBuybackBridge()` to revert, `unbridgedBuyback` continues to accumulate, no other functions affected.

### 7.7 Gas Benchmarks

Profile gas for every function. Targets (HyperEVM):
- `openPosition`: < 250k gas
- `closePosition`: < 200k gas
- `liquidate`: < 200k gas
- `executeOrder`: < 250k gas
- `deposit` (vault): < 100k gas
- `withdraw` (vault): < 120k gas
- Oracle reads: < 30k gas

---

## 8. Audit Requirements

This contract handles user funds and is **immutable**. Mandatory audit before mainnet:

### Required audit deliverables

1. **External professional audit** by one of: Spearbit, Trail of Bits, Code4rena (contest), Cantina (contest), Sherlock (contest)
2. Audit must include:
   - Manual code review
   - Formal verification of all 25 invariants where feasible
   - Foundry invariant fuzz tests (auditor writes additional ones)
   - Specific testing of oracle attack vectors
   - Specific testing of ERC-4626 inflation attack prevention (MIN_FIRST_DEPOSIT + DEAD_SHARES)
   - Specific testing of reentrancy
3. **All findings (Critical, High, Medium) must be fixed**. Low/Informational at team's discretion.
4. **Public audit report** published before mainnet launch.

### Recommended additional steps

- Code4rena contest (community auditing) — uncovers different bugs than firms
- Bug bounty on Immunefi (10% of TVL or $100k+, whichever is greater) for first 6 months post-launch
- Limited mainnet phase: cap vault TVL at $50k for first 30 days as live test

---

## 9. Deployment Checklist

Values that must be obtained / verified before deployment:

### Contract addresses
- [ ] USDC contract address on HyperEVM
- [ ] HYPE wrapped token address on HyperEVM
- [ ] VY token address on HyperEVM (will be the OFT bridged version from ETH)
- [ ] HyperSwap factory address
- [ ] VPOhl contract address (existing buyback bridge)

### HyperCore parameters
- [ ] HYPE perp asset index on HyperCore (query via HL info endpoint `meta`)
- [ ] HYPE perp szDecimals (query via HL info endpoint `meta`)
- [ ] Verify `0x0000000000000000000000000000000000000807` precompile returns expected data on testnet first
- [ ] Test full read pipeline (HYPE precompile + HyperSwap V3 observe()) on testnet

### HyperSwap pool setup
- [ ] Deploy VY/HYPE pool on HyperSwap with appropriate fee tier (recommend 0.30% for thin token)
- [ ] Increase observation cardinality to support 24h TWAP: `pool.increaseObservationCardinalityNext(targetCardinality)` — calculate based on expected swap frequency
- [ ] Seed initial liquidity at correct ratio (compute `HYPE_per_VY = VY_USD / HYPE_USD` from live ETH-side price at moment of seed)
- [ ] Burn LP NFT after seeding

### Pre-deployment fetches
- [ ] Fetch and review official L1Read.sol from HL repo (verify exact precompile interface matches our usage)
- [ ] Verify HYPE perp price returned by precompile is USD-denominated (not USDC, not in HYPE-priced units)

### Deployment sequence

```
1. Deploy Oracle(_hyperSwapPool, _hypeToken, _vyToken, _hypeAssetIndex, _hypeSzDecimals)
2. Deploy BackstopVault(_usdc, "VY Backstop Vault", "vyBV")
3. Deploy PerpCore(_usdc, _backstopVault, _oracle, _vpoHl)
4. Call BackstopVault.setPerpCore(perpCoreAddress)
5. Verify all contracts on HyperEVM block explorer
6. Run smoke tests: small deposit, small open, close, withdraw
7. Publish addresses, ABIs, audit report
8. Begin TVL ramp (cap monitoring during first 30 days)
```

---

## 10. Items Resolved + Remaining Verification Tasks

Most items previously listed as open questions have been resolved in §3.6.5, §13a, and §13b. The remaining items require RUNTIME verification (cannot be locked in spec text alone):

### Runtime verification tasks

1. **Verify HyperEVM precompile ABI on testnet** — use `test/HyperEVMPrecompileSmokeTest.sol` (provided). Run on chain 998, confirm:
   - `0x0807` returns expected raw price for HYPE
   - Scaling formula `raw / 10^(6 - szDecimals)` produces correct USD price
   - Gas cost matches docs (`2000 + 65 * (input + output)`)

2. **Verify HyperSwap pool version (V2 vs V3)** — affects oracle reading code in §5.6:
   - Inspect deployed HyperSwap contracts' interface
   - V3: use `OracleLibrary.consult()` (already in spec)
   - V2: use cumulative price tracking (replace §5.6 implementation)
   - This is a one-line code path decision, not a design change

3. **Look up production constants** at deploy time:
   - HYPE perp asset index → from HL info endpoint `meta`
   - HYPE szDecimals → same source
   - HyperSwap pool address → after pool deployment
   - VPOhl contract address → from buyback contract owner

4. **Verify `OracleLibrary` from Uniswap V3 periphery is HyperEVM-compatible** — should be (HyperEVM is EVM-compatible) but smoke test the call once.

### Items previously uncertain — NOW LOCKED in spec

- ✅ Funding math: §3.6.5 contains GMX V2-pattern implementation with sign conventions
- ✅ PnL precision: §13a sets scaling (price 1e18, size 1e18, USDC 1e6)
- ✅ Bad debt accounting: §3.8.2 + §13b row "Bad debt fallback if vault drained"
- ✅ Limit order edge cases: §13b "Limit Order Validation at Execution"
- ✅ Reentrancy: §13a Solidity Patterns section
- ✅ Coding standards: §13a
- ✅ Auto-flush thresholds: §13b
- ✅ Solidity version: §13a (`0.8.24`, optimizer 200, viaIR enabled)

---

## 11. Reference Implementations to Study

| Pattern | Reference |
|---|---|
| Oracle-priced perp architecture | GMX V2 (Arbitrum) — github.com/gmx-io/gmx-synthetics |
| ERC-4626 standard implementation | OpenZeppelin's `ERC4626.sol` |
| Uniswap V3 oracle reads | OracleLibrary in @uniswap/v3-periphery |
| Reentrancy patterns | OpenZeppelin's ReentrancyGuard |
| Vault inflation attack mitigation | Compound V3, Morpho-Aave, OpenZeppelin docs (MIN_FIRST_DEPOSIT + DEAD_SHARES pattern) |
| Funding rate math | GMX V2 MarketUtils.sol |
| Liquidation engine | GMX V2 LiquidationUtils.sol, dYdX v3 |

---

## 12. Final Parameter Summary (Locked)

| Parameter | Value | Notes |
|---|---|---|
| Taker fee | 0.10% (10 bps) | Market orders open/close |
| Maker fee | 0.06% (6 bps) | Limit order fills |
| Keeper reward | 0.02% of notional | Carved from maker fee |
| Liquidator fee | 2% → 5% over 30s | Dynamic ramp from maintenance breach |
| Insurance share | 10% (constant) | Of all fees |
| Vault share of trading fees | **0% (constant)** | Depositors compensated via VY yield from VYO on ETH (see §15) |
| Buyback share | **90% (constant)** | Of all trading fees → VPOhl |
| Insurance share | **10% (constant)** | Of all trading fees |
| Max position size | 10% of vault TVL | Hard cap per position |
| Leverage tier 1 | 50x (size <0.5% of vault) | |
| Leverage tier 2 | 20x (size 0.5-2% of vault) | |
| Leverage tier 3 | 10x (size 2-5% of vault) | |
| Leverage tier 4 | 3x (size 5-10% of vault) | |
| Maintenance margin | 50% of initial | |
| Funding period | 1 hour | |
| Funding cap | ±0.05%/hour | Based on OI imbalance |
| Vault standard | **Standard ERC-4626** | Public deposit/withdraw, no locks, no fees |
| Vault deposit/withdraw access | **Permissionless** | Anyone can deposit; anyone with shares can withdraw |
| Lock tiers | **NOT on HL** | Enforced by ETH staking contract (out of scope) |
| Anti-inflation guard | MIN_FIRST_DEPOSIT 1000 USDC + 1000 dead shares | Standard ERC-4626 protection |
| Bad debt impact on vault | **Permanent** (no recovery mechanism) | Insurance reserve is first-loss buffer |
| Min limit order | $200 USDC notional | |
| TWAP windows | 5min / 1hr / 24h | All from HyperSwap pool |
| Oracle pause threshold | 20% (5min vs 24h divergence) | |
| Oracle unpause threshold | 10% (hysteresis) | |
| Min bridge amount | 100 USDC | Avoid wasteful tiny transfers |

---

## 12a. Companion Files

The spec ships with two companion files in this repo. Use them.

### `test/PerpInvariants.t.sol`
Foundry invariant test harness covering all 28 invariants in §6. The dev team:
- Implements the mock contracts (`MockUSDC`, `MockHyperSwapPool`, `MockHyperCoreOracle`)
- Implements the handler contracts (`PerpHandler`, `VaultHandler`, `LiquidatorHandler`, `OrderHandler`)
- Runs: `forge test --match-contract PerpInvariants --invariant-runs 100000`
- All assertions must pass

### `test/HyperEVMPrecompileSmokeTest.sol`
Standalone contract to verify HyperEVM precompile ABIs and price scaling on testnet BEFORE deploying the production Oracle. Includes:
- Direct precompile call to `0x0000000000000000000000000000000000000807`
- Price scaling helper
- Gas cost measurement
- Probe utility to scan precompile address space
- Step-by-step deploy + verify instructions in file comments

**Run this on testnet (chain 998) before deploying Oracle on mainnet (chain 999).** Use the verified `hypeAssetIndex` and `szDecimals` constants in Oracle's constructor.

---

## 13a. Solidity Patterns & Coding Standards (LOCKED)

These patterns are LOCKED. Do not deviate. They are the result of explicit design decisions, not preferences.

### Compiler & Versioning
```solidity
// SPDX-License-Identifier: BUSL-1.1  // (or MIT — pick one project-wide)
pragma solidity 0.8.24;
```

- **Solidity:** exactly `0.8.24` (Cancun). No floating pragma. Lock to known compiler.
- **EVM target:** `cancun`
- **Optimizer:** enabled, `runs = 200`
- **viaIR:** enabled (helps with stack-too-deep in complex functions)

### Errors: Custom Errors (NOT require strings)
```solidity
// ✅ CORRECT (gas-efficient, modern, explicit)
error Paused();
error PositionTooLarge(uint256 requested, uint256 max);
error LeverageExceedsTier(uint16 requested, uint16 max);

if (paused) revert Paused();
if (notional > maxPos) revert PositionTooLarge(notional, maxPos);

// ❌ WRONG (gas-expensive, error-prone)
require(!paused, "PAUSED");
```

All revert conditions use custom errors with descriptive parameters. No `require()` with string messages anywhere.

### Reentrancy
- Use OpenZeppelin's `ReentrancyGuard`
- Apply `nonReentrant` to ALL external state-changing functions
- Strict CEI (Checks-Effects-Interactions) pattern in every function
- All external calls (USDC transfers, vault calls) AFTER state updates

### Token Transfers
- Use OpenZeppelin's `SafeERC20`
- Always `safeTransfer` / `safeTransferFrom` (never raw `transfer`)
- Pre-validate balances before transfer chains

### Math Patterns
- `unchecked` blocks ONLY in proven-safe arithmetic (e.g., `++i` in for loops, decrements verified with prior require)
- Default to checked arithmetic everywhere else
- Use `Math.min`, `Math.max` from OZ for clarity
- Cast carefully: `uint256(uint64(x))` not `uint256(x)` when downcasting

### Storage Layout (LOCKED)
- Use immutable for all addresses set in constructor
- Pack structs as documented in §3.2
- Use `uint128` for size/price/margin (gas efficient, sufficient range)
- Use `uint256` only for accumulators that need full range (cumulative indexes, balances)
- Use `int256` for signed quantities (PnL, funding deltas)

### Visibility & Modifiers
- `external` for user-facing entry points (cheaper than public for external calls)
- `public` only when function must be callable internally too
- `internal` for shared logic
- `private` for true encapsulation
- All view functions explicitly marked `view` or `pure`

### Events (Required)
- Emit on every state change (no silent state mutations)
- Index relevant fields: `address indexed user`, `uint256 indexed positionId`
- All events as defined in §3.12

### Sentinel Values
- Position IDs and Order IDs start at 1 (not 0)
- ID 0 == "doesn't exist"
- `nextPositionId = 1; nextOrderId = 1;` initialized in constructor

### Naming Conventions
- `_internalFunction` for internal/private functions (underscore prefix)
- `CONSTANT_NAMES` for constants/immutables
- `camelCase` for variables and functions
- `PascalCase` for contracts, structs, enums, errors, events

### Safe Casting
Use OpenZeppelin's `SafeCast` for all narrowing conversions:
```solidity
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
using SafeCast for uint256;
using SafeCast for int256;

uint128 packed = bigUint.toUint128();  // reverts on overflow
```

### Test Coverage Requirements
- Foundry: `forge test`
- Coverage: 100% line, 95%+ branch (per `forge coverage`)
- Invariant tests: 100,000+ runs for each invariant
- Fuzz tests: at least 1,000 runs per fuzzed function

### Documentation
- NatSpec on EVERY external/public function (even view)
- `/// @notice`, `/// @param`, `/// @return`
- `/// @dev` for implementation notes
- Inline comments only for non-obvious logic

---

## 13b. Locked Micro-Decisions (Items Previously TBD)

Every implementation decision below is LOCKED. Do not deviate without architect approval.

| Decision | LOCKED Value | Rationale |
|---|---|---|
| Auto-flush threshold for `pendingFundingExcess` | 10 USDC | Small enough to keep revenue moving, large enough to avoid trivial flush gas waste |
| Auto-flush at end of `_accrueFunding` | YES (if threshold met) | Avoids requiring separate caller |
| Slippage check on market open/close | Read oracle ONCE at top of function, validate at end | Single price reference; if price moved, revert |
| Slippage check on limit order execution | Validate `oracle - triggerPrice <= maxSlippage` at execution time | Execution price must match expected |
| Order expiry of 0 | Means "never expires" | Standard convention |
| Limit order auto-cancel on linked position close (SL/TP) | YES, on next interaction | Lazy cleanup; prevents stale orders |
| Limit order rejection if vault shrunk past max position | Order remains, executeOrder reverts; user must cancel and refund | Don't silently auto-cancel (could surprise user) |
| Position ID 0 | Sentinel for "doesn't exist" | Standard pattern; IDs start at 1 |
| Order ID 0 | Same | Same |
| `MIN_BRIDGE_AMOUNT` for buyback bridge | 100 USDC | Avoids wasteful tiny LZ transfers |
| Vault deposit interface | Standard ERC-4626 public `deposit`/`mint` | Permissionless; anyone can deposit |
| Vault withdraw interface | Standard ERC-4626 public `withdraw`/`redeem` | Anyone with shares; no fees, no locks |
| Anti-inflation guard | MIN_FIRST_DEPOSIT 1000 USDC + 1000 DEAD_SHARES | Standard ERC-4626 protection on first deposit |
| `FUNDING_PERIOD` | 3600 seconds (1 hour) | Matches HL native |
| `FUNDING_CAP_BPS_PER_HOUR` | 5 (0.05%/hour) | Matches HL native cap |
| `FUNDING_FLUSH_THRESHOLD` | 10 USDC | Avoid trivial flushes |
| `LIQ_FEE_RAMP_SECS` | 30 seconds | Empirically responsive |
| `MAX_LAST_GOOD_PRICE_AGE` | 86400 seconds (24h) | Liquidations need fresh-ish price even during pause |
| `MIN_OBSERVATION_INTERVAL` (oracle TWAP) | 600 seconds (10 min) | Limits storage write frequency |
| Oracle observation cardinality (HyperSwap pool) | Verify pool supports 144+ observations; call `increaseObservationCardinalityNext(144)` | 24h coverage at 10min spacing |
| Liquidation reward distribution | 100% to liquidator (no split) | Per locked decision in main thread |
| Liquidator reward source | Position margin | Standard |
| Funding excess flushed via | Auto in `_accrueFunding` AND manual `flushFundingExcess()` | Both paths permissionless |
| Bad debt fallback if vault drained | Vault `coverBadDebt` reverts; liquidation reverts; position stays open as zombie until vault refills | Accepted residual risk per Path A in §14 |
| ERC-4626 inheritance | OpenZeppelin's `ERC4626.sol` (v5+) | Battle-tested standard |
| Vault share token | Standard ERC-20 (transferable) | Inherited from ERC-4626 |
| Cross-chain logic in HL contract | NONE | All bridging done by ETH staking contract |
| Reentrancy guard | OpenZeppelin's `ReentrancyGuard` | Battle-tested |
| Use of unchecked blocks | Only in for-loop counters and provably-safe decrements | Conservative |
| Storage upgrades | NONE EVER | Immutable contract |

### Limit Order Validation at Execution

When executing a limit order, validate in this order (revert on first failure):
1. Order exists
2. Oracle not paused
3. Order not expired
4. Trigger condition met (per table in §3.7.4)
5. Slippage: `|oraclePrice - triggerPrice| / triggerPrice <= maxSlippageBps / 10000`
6. (LIMIT_OPEN only) Position size still valid for current vault TVL — if exceeds, revert with `OrderExceedsCurrentPositionCap()` error so user can cancel
7. (LIMIT_OPEN only) Leverage tier still valid for size — same handling
8. (SL/TP only) Linked position still exists with same owner

If execution succeeds: open/close position, charge maker fee, pay keeper, distribute remaining fee.

---

## 14. Funding Rate Dynamics & Hedging (Why Funding Is Trader-To-Trader)

This section explains the economic mechanism behind the funding rate model in §3.6.5 and §3.8.3. **The dev team should understand this before implementing**, because subtle deviations will break the self-correcting property.

### 13.1 The Self-Correcting Mechanism

Funding rate exists to keep the perp's implied price aligned with spot price by incentivizing OI rebalancing. The mechanism only works if **the under-side traders are paid by the over-side traders**.

```
Cycle:
  1. OI imbalanced (e.g., longs >> shorts)
  2. Funding rate goes positive (longs pay)
  3. Bots see profitable opportunity to be on under-side (shorts receive)
  4. Bots open shorts (often hedged) to capture funding
  5. Short OI rises, imbalance reduces
  6. Funding rate normalizes
  7. System balanced (until next imbalance, then repeat)
```

**If funding flowed only to vault** (not to under-side traders), step 3 would not happen. Bots would have no direct profit to capture. The system would not self-correct, and persistent imbalances would generate bad trader UX (escalating funding with no relief).

### 13.2 Why Vault Still Earns Funding Revenue

The vault is the **implicit counterparty** for the imbalance. When `longSize > shortSize`:
- Longs aggregate pay = `longSize × rate × time`
- Shorts aggregate receive = `shortSize × rate × time`
- **Difference (excess)** = `(longSize - shortSize) × rate × time`

This difference is what the vault is owed for taking the directional risk of being implicitly short for the imbalance. It accumulates in `pendingFundingExcess` and flows through `_distributeFees`.

### 13.3 Bot Incentives (Concrete Numbers)

```
Scenario: $1M long OI, $200k short OI, max funding rate 0.05%/hour

Per-position bot economics if bot opens $50k SHORT:
  Hourly funding income: $50,000 × 0.05% = $25/hour
  Annualized (sustained imbalance): 438% APY
  
  Bot's price exposure: -$50k VY position
  Hedge: buy $50k VY on HyperSwap (or ETH USDC/VY pool)
  Net delta exposure: ~0 (delta-neutral)
  Pure capture: funding rate
```

This is HUGELY attractive. Same bots that arb funding on HL native, dYdX, GMX, etc. will arb yours. **You don't need to run them yourself.**

### 13.4 The Hedging Asymmetry (Important For Early Days)

Hedging a SHORT perp is easy: buy spot VY. Spot is liquid (HyperSwap + ETH Uniswap V3).

Hedging a LONG perp is HARD for a new token. To be delta-neutral when long perp, the bot needs negative spot exposure:

| Method | Available for VY? |
|---|---|
| **Sell spot VY** (requires already owning) | ⚠️ Only if bot holds VY inventory |
| **Borrow VY and short** (lending market) | ❌ No VY lending market yet |
| **CEX margin short** | ❌ VY not on centralized exchanges |
| **Options put** | ❌ No options market |

**Practical implication:** When shorts are over-side (paying funding), bots opening longs to capture cannot easily hedge. They'd be taking directional VY exposure. Most won't.

**This means:**
- **Long-overpopulated states** correct quickly (shorts can hedge → bots arb fast)
- **Short-overpopulated states** linger (longs can't easily hedge → bots stay away)
- Net effect: VY perp will tend to have slight long-side bias most of the time
- This is normal for new tokens with limited spot infrastructure

**Mitigations over time:**
1. As VY listed on HyperEVM lending markets (HyperLend, Felix, etc.), borrow-and-short becomes possible
2. As VY ecosystem grows, treasury/team allocations create natural inventory for hedging
3. As CEX listings happen (later), margin shorts emerge
4. Short imbalances will eventually correct via natural trader closes (longs taking profit, etc.) even without bot arb

**No code change needed** — just understand this when watching early-days OI behavior. Periods of unbalanced shorts paying funding to no-one (effectively all going to vault as `pendingFundingExcess`) are expected and not a bug.

### 13.5 Why This Matches HL Standard As Closely As Possible

HL native perps:
- Symmetric funding rate based on premium/discount of mark vs oracle
- Pure trader-to-trader (over-side pays under-side)
- 0% protocol take on funding
- Hourly accrual

Our perp matches HL on:
- ✅ Symmetric funding rate (compute differently — OI-imbalance based vs premium-based, but same effect)
- ✅ Trader-to-trader for the symmetric portion
- ✅ Hourly accrual
- ✅ Same cap (±0.05%/hour)

We DIFFER from HL on:
- ⚠️ Imbalance excess goes to vault (HL doesn't need this because their orderbook always matches OI 1:1)
- This is a structural necessity of vault-as-counterparty model. Cannot be avoided unless we rebuild as orderbook (which we can't on HyperEVM at this scale).

For traders, the experience is **identical to HL native** when OI is balanced. When imbalanced, both sides pay/receive funding the same way as HL — they just don't see that the vault is also collecting the excess. Functionally invisible to traders.

---

## 15. Cross-Chain Integration (Out Of Scope For This Spec)

The HL `BackstopVault` is a standalone permissionless ERC-4626. It does not contain any cross-chain logic. The ETH-side staking contract (separate spec) is responsible for:

- Pulling USDC from users on Ethereum
- Bridging USDC to HyperEVM (any mechanism — Stargate recommended)
- Calling `BackstopVault.deposit(amount, receiver)` on HL with the bridged USDC
- Holding/managing the resulting vault shares on behalf of stakers
- Enforcing lock tiers (30/60/90 days) on ETH side
- Routing yield via VYO to stakers (in VY)
- On unstake: redeeming shares from HL vault, bridging USDC back to user

From the HL `BackstopVault` perspective, the ETH staking contract is just one of many possible depositors — there is no special permission, hardcoded address, or cross-chain awareness in the vault itself. This keeps the HL contract simple, immutable, and trust-minimized.

### Required Depositor Risk Disclosure (ETH Webapp)

The ETH-side staking webapp MUST display this disclosure before users stake:

> **YOUR USDC PRINCIPAL IS AT RISK.**
>
> When you stake USDC, your funds back leveraged perpetual trades on the VY token via the BackstopVault on HyperEVM. In normal operation, you earn VY yield from the Valinity Yield Treasury and receive your full USDC back when your lock expires.
>
> However: in extreme market conditions (large gap moves in VY price, oracle exploits, or other tail events), the vault may absorb "bad debt" — losses that exceed the insurance reserve buffer. **These losses are permanent and pro-rata to your stake.** There is no automatic recovery mechanism for bad debt absorbed by the vault.
>
> Your VY yield (paid separately via Valinity's existing yield system) compensates for this risk over time. Historically, well-designed perpetual protocols experience bad debt events affecting 0-15% of vault TVL during black swan events.
>
> **Recommended:** Stake amounts you can afford to lose.

This is the only requirement this spec imposes on the ETH-side implementation. Everything else about the ETH staking flow is documented separately when that contract is built.

---

## END OF SPECIFICATION

This document is the single source of truth for building the VY Perpetual Protocol. If any ambiguity arises during implementation, the dev team should:

1. First study the reference implementations listed in §11
2. Default to the simpler, safer interpretation
3. Surface the question to the architect for explicit decision
4. Document any clarifications in a CHANGELOG appended to this spec

**Do not deviate from locked parameters in §12 without explicit approval.**

---

## Appendix: GMX V2 Funding Patterns Studied

The funding implementation in §3.6.5 and §3.8.3 was derived by studying:

- `gmx-synthetics/contracts/market/MarketUtils.sol` — `getNextFundingFactorPerSecond`, `getFundingAmountPerSizeDelta`
- `gmx-synthetics/contracts/pricing/PositionPricingUtils.sol` — `getFundingFees`, sign conventions

Key patterns adopted:
- Cumulative funding fee per unit of size (signed)
- Per-position lazy settlement via index difference
- Magnitude rounding rules (round up for amounts owed, down for amounts claimable — adapted to direct margin adjustment in our model)
- Sign convention: positive cumulative index = longs have been paying

Key simplifications from GMX V2:
- No separate borrowing rate (we have only funding rate)
- No claimable balances split (direct margin adjustment instead)
- No adaptive funding factor (we use simple OI imbalance)
- No long/short collateral token split (USDC only)
- No exponent factor on imbalance

These simplifications reduce complexity while preserving the self-correcting funding dynamic.
