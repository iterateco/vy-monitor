// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ValinityCapOfficer} from "../officer/ValinityCapOfficer.sol";
import {IWETH} from "../token/IWETH.sol";
import {ValinityToken} from "../token/ValinityToken.sol";
import {ValinityReserveTreasury} from "../treasury/ValinityReserveTreasury.sol";

interface IValinityReserveYieldOfficer {
    function execute() external;
}

contract ValinityLoanOfficer is
    UUPSUpgradeable,
    AccessControl,
    ReentrancyGuardTransient,
    Initializable
{
    using SafeERC20 for IERC20;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint8 internal constant DEFAULT_DECIMALS = 18;
    uint16 internal constant BPS_MULTIPLIER = 10_000; // for BPS
    uint256 internal constant WAD = 1e18;
    /// @notice Hard cap on interestRatePerSecond ~= 100% APR.
    ///         Bounds admin power (a compromised admin cannot instantly
    ///         force every loan underwater).
    uint256 internal constant MAX_INTEREST_RATE_PER_SECOND = 32e9; // ~101% APR

    // ═══════════════════════════════════════════════════════════════════════════
    // CONTRACT REFERENCES (replaces Registrar)
    // ═══════════════════════════════════════════════════════════════════════════
    
    ValinityCapOfficer public vco;
    ValinityReserveTreasury public vrt;
    ValinityToken public vyToken;

    struct Loan {
        uint256 collateral; // VY locked in VRT for this loan (gross, before carry)
        uint256 principal; // Asset loaned to borrower
        uint64 openedAt; // Timestamp when loan was opened
        uint64 interestAppliedAt; // Timestamp of the last time interest was crystallized into carry
        uint256 interestCarry; // V3: accrued interest owed by user, not yet settled.
                               //     Effective user claim = collateral - interestCarry.
                               //     VRT physically holds `collateral`; carry is a virtual debit.
    }

    struct AssetView {
        uint256 ltv; // The asset’s current LTV (getLTV(asset))
        uint256 reserveBalance; // The VRT’s token balance
        uint256 totalLoaned; // Total amount loaned
    }

    struct LoanView {
        uint256 collateral;
        uint256 principal;
        uint64 openedAt;
        uint64 interestAppliedAt;
        uint256 ltv; // LTV based on principal / netCollateral
        uint256 accruedInterest; // V3: TOTAL interest owed (interestCarry + newAccrual, capped at collateral)
        uint256 netCollateral; // collateral - accruedInterest = effective user claim
        uint256 interestCarry; // V3: persisted portion of accruedInterest (already crystallized)
    }

    // Used for input validation on loan forms
    struct LoanConstraintsView {
        uint256 maxCollateral;
        uint256 maxPrincipal;
    }

    // Used to display the result of opening/increasing/refinancing a loan
    struct NewLoanView {
        uint256 principal;
        uint256 ltv;
        uint256 fee;
        uint256 netAmount;
    }

    // Used to display the result of repaying a loan
    struct RepayView {
        uint256 collateralRatio;
        uint256 collateralReturned;
        uint256 principal;
    }

    struct MigrateLoanVars {
        address borrower;
        address asset;
        uint256 collateral;
        uint256 principal;
    }

    enum LoanEventType {
        Opened,
        Increased,
        Repaid,
        Migrated,
        Liquidated
    }

    uint256 public interestRatePerSecond;
    uint16 public processingFeePercentage; // basis points
    address public processingFeeRecipient;
    address public interestRecipient; // VYT - receives interest from loans

    IWETH internal _weth;
    mapping(address => mapping(address => Loan)) internal _loans;
    mapping(address => uint256) internal _totalLoanedPerAsset;

    // ── V2 storage (appended; must never be reordered above this line) ──────
    IValinityReserveYieldOfficer public vryo;
    uint16 public loanCapBps; // max VY collateral per loan as % of circulating supply

    // ── V3 storage (appended) ─────────────────────────────────────────────
    /// @notice Recipient for VY collateral consumed by underwater loans.
    /// @dev Distinct from interestRecipient: underwater VY has no incoming
    ///      asset backing, so it must NOT be routed to the buyback officer
    ///      (which would force a second reserve withdrawal). It is sent to
    ///      the VYT instead, where it is freed from VRT accounting and
    ///      available for downstream business logic.
    address public underwaterRecipient;

    // ── V4 storage (appended) ─────────────────────────────────────────
    /// @notice Cumulative VY-denominated loan interest paid by each borrower
    ///         that was actually routed to the buyback recipient (VBBO).
    ///         Excludes underwater write-offs and liquidations (those go to
    ///         VYT, not VBBO). Read by ValinityReferralOfficer (VRO) for
    ///         referral accounting. Monotonically increasing; never reset.
    mapping(address => uint256) public cumulativeInterestPaidVY;

    error ActiveLoanExists();
    error CollateralExceedsLoanCap();
    error CollateralTooLow();
    error ETHNotAccepted();
    error ETHTransferFailed();
    error InvalidAddress();
    error InvalidValue();
    error LoanNotFound();
    error MismatchedETHValue();
    error PaymentTooHigh();
    error PaymentTooLow();
    error PrincipalTooLow();
    error UnsupportedAsset();

    event InterestRatePerSecondUpdated(uint256 value);
    event LoanCapBpsUpdated(uint16 bps);
    event ProcessingFeePercentageUpdated(uint16 value);
    event ProcessingFeeRecipientUpdated(address recipient);
    event InterestRecipientUpdated(address recipient);
    event UnderwaterRecipientUpdated(address recipient);
    /// @notice Emitted when interest paid to the buyback recipient is
    ///         accrued to the borrower's lifetime VRO-eligible total.
    event InterestAccruedToVRO(address indexed borrower, uint256 amount, uint256 total);
    event VryoUpdated(address vryo);
    event VryoHeartbeatFailed(bytes reason);

    event LoanEvent(
        LoanEventType indexed eventType,
        address indexed borrower,
        address indexed asset,
        int256 deltaCollateral,
        int256 deltaPrincipal,
        uint256 processingFeeAmount,
        uint256 interestFeeAmount,
        uint256 totalCollateral,
        uint256 totalPrincipal
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vcoAddress,
        address vrtAddress,
        address vyTokenAddress,
        address adminAddress,
        address wethAddress,
        address processingFeeRecipientAddress,
        address interestRecipientAddress
    ) public initializer {
        if (
            vcoAddress == address(0) ||
            vrtAddress == address(0) ||
            vyTokenAddress == address(0) ||
            adminAddress == address(0) ||
            wethAddress == address(0) ||
            processingFeeRecipientAddress == address(0) ||
            interestRecipientAddress == address(0)
        ) revert InvalidAddress();

        vco = ValinityCapOfficer(vcoAddress);
        vrt = ValinityReserveTreasury(vrtAddress);
        vyToken = ValinityToken(vyTokenAddress);

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);

        _weth = IWETH(wethAddress);
        processingFeeRecipient = processingFeeRecipientAddress;
        interestRecipient = interestRecipientAddress;

        interestRatePerSecond = 3_802_570_538; // ~12% APR
        processingFeePercentage = 100; // 1% in basis points
        loanCapBps = 500; // 5% of circulating VY supply per loan
    }

    /// @notice Called once via upgradeToAndCall when upgrading to V2.
    /// @dev Sets loanCapBps which was uninitialized in V1. Uses reinitializer(2)
    ///      so it can only ever be executed once and cannot replace initialize().
    function reinitializeV2() external reinitializer(2) {
        loanCapBps = 500; // 5% of circulating VY supply per loan
    }

    /// @notice Called once via upgradeToAndCall when upgrading to V3.
    /// @dev Sets underwaterRecipient (must be VYT). Uses reinitializer(3) so it
    ///      can only ever run once. Interest routing for non-underwater paths is
    ///      controlled by interestRecipient (set separately via setInterestRecipient).
    function reinitializeV3(
        address underwaterRecipientAddress
    ) external reinitializer(3) {
        if (underwaterRecipientAddress == address(0)) revert InvalidAddress();
        underwaterRecipient = underwaterRecipientAddress;
        emit UnderwaterRecipientUpdated(underwaterRecipientAddress);
    }

    modifier onlyActiveLoan(address borrower, address asset) {
        _checkActiveLoan(borrower, asset);
        _;
    }

    modifier onlySupportedAsset(address asset) {
        if (!vco.isSupported(asset)) {
            revert UnsupportedAsset();
        }
        _;
    }

    receive() external payable {
        // Only allow ETH sent by the WETH contract
        if (_msgSender() != address(_weth)) {
            revert ETHNotAccepted();
        }
    }

    function isActive(
        address borrower,
        address asset
    ) public view returns (bool) {
        return _loanExists(borrower, asset);
    }

    function getLoan(
        address borrower,
        address asset
    ) external view returns (Loan memory) {
        return _loans[borrower][asset];
    }

    function getTotalLoaned(address asset) public view returns (uint256) {
        return _totalLoanedPerAsset[asset];
    }

    function getLTV(
        address asset
    ) external view onlySupportedAsset(asset) returns (uint256) {
        return _getLTV(asset, _getAssetDecimals(asset));
    }

    function getBorrowQuote(
        address asset,
        uint256 collateral
    ) public view onlySupportedAsset(asset) returns (uint256) {
        uint8 assetDecimals = _getAssetDecimals(asset);
        uint256 ltv = _getLTV(asset, assetDecimals);
        return _toPrincipal(assetDecimals, ltv, collateral);
    }

    function getAccruedInterest(
        address borrower,
        address asset
    ) public view returns (uint256) {
        Loan storage loan = _loans[borrower][asset];
        uint256 collateral = loan.collateral;
        uint256 carry = loan.interestCarry;
        uint256 elapsed = block.timestamp - loan.interestAppliedAt;
        uint256 newAccrual = (collateral * interestRatePerSecond * elapsed) / WAD;
        uint256 total = carry + newAccrual;
        // Cap total interest at collateral — loan is fully consumed ("rent-to-own complete")
        return total > collateral ? collateral : total;
    }

    function getAssetView(
        address asset
    ) external view onlySupportedAsset(asset) returns (AssetView memory) {
        uint8 assetDecimals = _getAssetDecimals(asset);
        return
            AssetView({
                ltv: _getLTV(asset, assetDecimals),
                reserveBalance: IERC20(asset).balanceOf(
                    address(vrt)
                ),
                totalLoaned: getTotalLoaned(asset)
            });
    }

    function getLoanView(
        address borrower,
        address asset
    ) external view returns (LoanView memory) {
        // If loan does not exist, return empty struct
        if (!isActive(borrower, asset)) {
            return LoanView(0, 0, 0, 0, 0, 0, 0, 0);
        }

        Loan storage loan = _loans[borrower][asset];
        uint256 accruedInterest = getAccruedInterest(borrower, asset);
        uint256 netCollateral = loan.collateral - accruedInterest;
        uint256 ltv;
        if (netCollateral > 0) {
            uint256 scaledPrincipal = _scaleDecimals(
                loan.principal,
                _getAssetDecimals(asset),
                DEFAULT_DECIMALS
            );
            ltv = (scaledPrincipal * WAD) / netCollateral;
        }
        // When netCollateral == 0, ltv stays 0 — loan is underwater / fully consumed

        return
            LoanView({
                collateral: loan.collateral,
                principal: loan.principal,
                openedAt: loan.openedAt,
                interestAppliedAt: loan.interestAppliedAt,
                ltv: ltv,
                accruedInterest: accruedInterest,
                netCollateral: netCollateral,
                interestCarry: loan.interestCarry
            });
    }

    function getLoanConstraints(
        address asset,
        uint256 collateralBalance
    )
        external
        view
        onlySupportedAsset(asset)
        returns (LoanConstraintsView memory)
    {
        uint8 assetDecimals = _getAssetDecimals(asset);
        
        // Cache vrt address and reserve balance (used for LTV calc and constraint check)
        address vrtAddress = address(vrt);
        uint256 reserveBalance = IERC20(asset).balanceOf(vrtAddress);
        
        // Inline LTV calculation to avoid duplicate balanceOf call
        uint256 cap = vco.getAssetCap(asset);
        if (cap == 0 || collateralBalance == 0) {
            return LoanConstraintsView({maxCollateral: 0, maxPrincipal: 0});
        }
        
        uint256 scaledReserve = _scaleDecimals(reserveBalance, assetDecimals, DEFAULT_DECIMALS);
        uint256 ltv = (scaledReserve * WAD) / cap;

        if (ltv == 0) {
            return LoanConstraintsView({maxCollateral: 0, maxPrincipal: 0});
        }

        uint256 maxCollateral = collateralBalance;

        uint256 floor = vco.effectiveFloor();
        uint256 collateralLimit = cap > floor ? cap - floor : 0;

        if (maxCollateral > collateralLimit) {
            maxCollateral = collateralLimit;
        }

        // Cap per single loan to loanCapBps % of true circulating VY supply
        uint256 loanCapLimit = (vco.getTotalCirculatingVY() * loanCapBps) / BPS_MULTIPLIER;
        if (maxCollateral > loanCapLimit) {
            maxCollateral = loanCapLimit;
        }

        uint256 maxPrincipal = _toPrincipal(assetDecimals, ltv, maxCollateral);

        if (maxPrincipal > reserveBalance) {
            maxPrincipal = reserveBalance;
            maxCollateral = _toCollateral(assetDecimals, ltv, maxPrincipal);
        }

        return
            LoanConstraintsView({
                maxCollateral: maxCollateral,
                maxPrincipal: maxPrincipal
            });
    }

    /// @notice Muestra una vista previa del préstamo antes de abrirlo
    /// @dev El fee es en VY (1% del colateral), el borrower recibe el principal completo
    function getNewLoanView(
        address asset,
        uint256 collateral
    ) external view onlySupportedAsset(asset) returns (NewLoanView memory) {
        uint8 assetDecimals = _getAssetDecimals(asset);
        
        // Fee is calculated on VY collateral (1%)
        uint256 fee = _getProcessingFee(collateral);
        uint256 netCollateral = collateral - fee;
        
        uint256 ltv = _getLTV(asset, assetDecimals);
        uint256 principal = _toPrincipal(assetDecimals, ltv, netCollateral);

        return
            NewLoanView({
                principal: principal,
                ltv: ltv,
                fee: fee,           // Fee in VY
                netAmount: principal // Borrower receives full principal
            });
    }

    function getRepayView(
        address borrower,
        address asset,
        uint256 payment
    ) external view onlyActiveLoan(borrower, asset) returns (RepayView memory) {
        Loan storage loan = _loans[borrower][asset];

        if (payment > loan.principal) revert PaymentTooHigh();

        uint256 accruedInterest = getAccruedInterest(borrower, asset);
        uint256 netCollateral = loan.collateral - accruedInterest;

        // Underwater: any payment auto-closes, borrower gets 0 VY back
        if (netCollateral == 0) {
            return RepayView({
                collateralRatio: 0,
                collateralReturned: 0,
                principal: 0  // loan will be closed regardless of payment
            });
        }

        // V3: pro-rated — user receives a slice of effective claim proportional
        // to the fraction of debt repaid. Interest settled is the matching slice.
        // Note: (netCollateral * payment) / principal is exact when payment == principal.
        uint256 collateralReturned = (netCollateral * payment) / loan.principal;
        return
            RepayView({
                collateralRatio: (collateralReturned * WAD) / netCollateral,
                collateralReturned: collateralReturned,
                principal: loan.principal - payment
            });
    }

    // ─────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────

    function setInterestRatePerSecond(
        uint256 value
    ) external onlyRole(ADMIN_ROLE) {
        if (value == interestRatePerSecond) return;
        if (value > MAX_INTEREST_RATE_PER_SECOND) revert InvalidValue();
        interestRatePerSecond = value;
        emit InterestRatePerSecondUpdated(value);
    }

    function setLoanCapBps(uint16 bps) external onlyRole(ADMIN_ROLE) {
        if (bps == loanCapBps) return;
        if (bps == 0 || bps >= BPS_MULTIPLIER) revert InvalidValue();
        loanCapBps = bps;
        emit LoanCapBpsUpdated(bps);
    }

    function setVryo(address vryoAddress) external onlyRole(ADMIN_ROLE) {
        if (vryoAddress == address(vryo)) return;
        vryo = IValinityReserveYieldOfficer(vryoAddress);
        emit VryoUpdated(vryoAddress);
    }

    function setProcessingFeePercentage(
        uint16 value
    ) external onlyRole(ADMIN_ROLE) {
        if (value == processingFeePercentage) return;
        if (value >= BPS_MULTIPLIER) revert InvalidValue();
        processingFeePercentage = value;
        emit ProcessingFeePercentageUpdated(value);
    }

    /// @notice Configura el destinatario del processing fee (dirección de la compañía)
    /// @dev Esta dirección es configurable vía gobernanza para recibir el 1% de comisión
    /// @param recipient Dirección de la wallet/multisig de la compañía
    function setProcessingFeeRecipient(
        address recipient
    ) external onlyRole(ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();
        processingFeeRecipient = recipient;
        emit ProcessingFeeRecipientUpdated(recipient);
    }

    /// @notice Set the interest recipient (V3+: VBBO — backed interest from repays)
    function setInterestRecipient(
        address recipient
    ) external onlyRole(ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();
        interestRecipient = recipient;
        emit InterestRecipientUpdated(recipient);
    }

    /// @notice Set the underwater recipient (VYT — unbacked VY from liquidations)
    /// @dev Underwater VY has no incoming asset backing; routing it through the
    ///      buyback officer would force a second reserve withdrawal and dilute
    ///      other users' backing. VYT is the only safe destination.
    function setUnderwaterRecipient(
        address recipient
    ) external onlyRole(ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();
        underwaterRecipient = recipient;
        emit UnderwaterRecipientUpdated(recipient);
    }

    function migrateLoans(
        MigrateLoanVars[] calldata loanDataArray
    ) external onlyRole(ADMIN_ROLE) {
        uint256 len = loanDataArray.length;
        for (uint256 i = 0; i < len; ) {
            _migrateLoan(
                loanDataArray[i].borrower,
                loanDataArray[i].asset,
                loanDataArray[i].collateral,
                loanDataArray[i].principal
            );
            unchecked { ++i; }
        }
    }

    // ─────────────────────────────────────────────
    // Loan Operations
    // ─────────────────────────────────────────────

    function openLoan(
        address asset,
        uint256 collateral
    ) external nonReentrant onlySupportedAsset(asset) {
        address borrower = _msgSender();
        if (isActive(borrower, asset)) revert ActiveLoanExists();
        _checkLoanCap(collateral);

        (uint256 principal, uint256 fee) = _processLoanIncrease(
            borrower,
            asset,
            collateral
        );

        uint64 openedAt = uint64(block.timestamp);

        Loan storage loan = _loans[borrower][asset];
        loan.openedAt = openedAt;
        loan.interestAppliedAt = openedAt;

        _emitLoanEvent(
            LoanEventType.Opened,
            borrower,
            asset,
            int256(collateral),
            int256(principal),
            fee,
            0
        );

        _pingVRYO();
    }

    function increaseLoan(
        address asset,
        uint256 additionalCollateral
    ) external nonReentrant onlyActiveLoan(_msgSender(), asset) {
        address borrower = _msgSender();
        _checkLoanCap(additionalCollateral);

        // V3 model:
        //  - Compute newAccrual against current loan.collateral.
        //  - If carry + newAccrual >= loan.collateral, the position is underwater:
        //    the entire loan.collateral (which is what VRT physically holds for
        //    this loan) is routed to underwaterRecipient (VYT). No reserve asset
        //    leaves VRT — only the VY accounting.
        //  - Otherwise, crystallize newAccrual into loan.interestCarry. Nothing
        //    is transferred; VY stays in VRT, settled later on repay.
        Loan storage loan = _loans[borrower][asset];
        uint256 carry = loan.interestCarry;
        uint256 newAccrual;
        {
            uint256 elapsed = block.timestamp - loan.interestAppliedAt;
            newAccrual = (loan.collateral * interestRatePerSecond * elapsed) / WAD;
        }
        uint256 totalInterestOwed = carry + newAccrual;
        // Effective cap at loan.collateral (cannot owe more than what's locked)
        if (totalInterestOwed > loan.collateral) totalInterestOwed = loan.collateral;

        // Underwater branch
        if (totalInterestOwed == loan.collateral) {
            uint256 oldCollateral = loan.collateral;
            uint256 oldPrincipal = loan.principal;

            // Route VY to VYT (no reserve withdrawal — protects other users)
            vrt.applyInterest(asset, oldCollateral, underwaterRecipient);

            _totalLoanedPerAsset[asset] -= oldPrincipal;
            delete _loans[borrower][asset];

            // Open fresh loan with new collateral
            (uint256 newPrincipal, uint256 fee) = _processLoanIncrease(
                borrower,
                asset,
                additionalCollateral
            );

            Loan storage fresh = _loans[borrower][asset];
            fresh.openedAt = uint64(block.timestamp);
            fresh.interestAppliedAt = uint64(block.timestamp);

            _emitLoanEvent(
                LoanEventType.Increased,
                borrower,
                asset,
                int256(additionalCollateral) - int256(oldCollateral),
                int256(newPrincipal) - int256(oldPrincipal),
                fee,
                oldCollateral
            );
            _pingVRYO();
            return;
        }

        // Normal branch: crystallize accrual into carry. No transfer.
        if (newAccrual > 0) {
            loan.interestCarry = totalInterestOwed;
            loan.interestAppliedAt = uint64(block.timestamp);
        }

        // Merge new deposit with existing position
        (uint256 additionalPrincipal, uint256 fee_) = _processLoanIncrease(
            borrower,
            asset,
            additionalCollateral
        );

        _emitLoanEvent(
            LoanEventType.Increased,
            borrower,
            asset,
            int256(additionalCollateral),
            int256(additionalPrincipal),
            fee_,
            newAccrual // interest accrued this tx (added to carry, not yet paid)
        );

        _pingVRYO();
    }

    function repayLoan(
        address asset,
        uint256 payment
    ) external payable nonReentrant onlyActiveLoan(_msgSender(), asset) {
        address borrower = _msgSender();
        Loan storage loan = _loans[borrower][asset];

        // GAS: cache the two storage fields reused across this function.
        uint256 collateral = loan.collateral;
        uint256 principal = loan.principal;

        if (payment == 0) revert PaymentTooLow();
        if (payment > principal) revert PaymentTooHigh();

        // V3: total interest owed = carried + newly accrued, capped at loan.collateral.
        uint256 carry = loan.interestCarry;
        uint256 newAccrual;
        {
            uint256 elapsed = block.timestamp - loan.interestAppliedAt;
            newAccrual = (collateral * interestRatePerSecond * elapsed) / WAD;
        }
        uint256 totalInterest = carry + newAccrual;
        if (totalInterest > collateral) totalInterest = collateral;

        uint256 netCollateral = collateral - totalInterest;

        // Step 1: Pull asset payment from borrower
        if (asset == address(_weth)) {
            if (msg.value != payment) revert MismatchedETHValue();
            _weth.deposit{value: payment}();
        } else {
            if (msg.value > 0) revert ETHNotAccepted();
            IERC20(asset).safeTransferFrom(borrower, address(this), payment);
        }

        // ---- Underwater branch: position fully consumed by interest --------
        // The asset payment lands in VRT, but the entire loan.collateral is
        // owed as interest with no incoming VY-side backing. Route to VYT.
        if (netCollateral == 0) {
            _ensureMaxAllowance(IERC20(asset), address(vrt), payment);
            vrt.releaseLoan(asset, payment, collateral, address(this));

            // Underwater VY → underwaterRecipient (VYT), NOT VBBO.
            // No cap restore (the original cap reduction is intentionally lost
            // because we permanently underbacked the system by writing off
            // unrecoverable principal).
            IERC20(address(vyToken)).safeTransfer(
                underwaterRecipient,
                collateral
            );

            _totalLoanedPerAsset[asset] -= principal;
            delete _loans[borrower][asset];

            _emitLoanEvent(
                LoanEventType.Repaid,
                borrower,
                asset,
                -int256(collateral),
                -int256(principal),
                0,
                collateral // entire collateral was interest
            );
            _pingVRYO();
            return;
        }

        // ---- Normal branch: pro-rated by fraction of debt repaid -----------
        //  f = payment / principal
        //  collateralReturned = netCollateral * f      → user
        //  interestCharged    = totalInterest * f      → interestRecipient (VBBO)
        //  totalVyRelease     = collateralReturned + interestCharged
        //  vco cap restored by totalVyRelease (the full VY that left VRT)
        //  carry persists:  newCarry = totalInterest - interestCharged
        uint256 collateralReturned = (netCollateral * payment) / principal;
        uint256 interestCharged = (totalInterest * payment) / principal;
        uint256 totalVyRelease = collateralReturned + interestCharged;

        // Step 2: VRT releases asset back, sends totalVyRelease to VLO,
        //         decrements _collateralizedVY accordingly.
        _ensureMaxAllowance(IERC20(asset), address(vrt), payment);
        vrt.releaseLoan(asset, payment, totalVyRelease, address(this));

        // Step 3: Distribute VY
        if (interestCharged > 0) {
            IERC20(address(vyToken)).safeTransfer(
                interestRecipient,
                interestCharged
            );
            uint256 newTotal = cumulativeInterestPaidVY[borrower] + interestCharged;
            cumulativeInterestPaidVY[borrower] = newTotal;
            emit InterestAccruedToVRO(borrower, interestCharged, newTotal);
        }
        if (collateralReturned > 0) {
            IERC20(address(vyToken)).safeTransfer(borrower, collateralReturned);
        }

        // Step 4: Update loan state
        loan.collateral = collateral - totalVyRelease;
        loan.interestCarry = totalInterest - interestCharged; // remaining unpaid interest
        loan.interestAppliedAt = uint64(block.timestamp);
        loan.principal = principal - payment;
        _totalLoanedPerAsset[asset] -= payment;

        // Step 5: Restore cap by the FULL VY that left VRT (user + interest).
        //         The interest portion's cap will be reduced again by VBBO when
        //         it consumes that VY in a buyback cycle, keeping the system
        //         in balance modulo the VGC fee.
        vco.increaseAssetCap(asset, totalVyRelease);

        if (loan.principal == 0) {
            // Full repay: carry must be zero (interestCharged == totalInterest)
            delete _loans[borrower][asset];
        }

        _emitLoanEvent(
            LoanEventType.Repaid,
            borrower,
            asset,
            -int256(totalVyRelease),
            -int256(payment),
            0,
            interestCharged
        );

        _pingVRYO();
    }

    /// @notice Permissionless batch liquidation of underwater loans.
    /// @dev    A loan is "underwater" when `interestCarry + newAccrual >=
    ///         loan.collateral`, i.e. the user's effective VY claim is zero.
    ///         Anyone may call this to clean up such positions. The full
    ///         loan.collateral is routed to `underwaterRecipient` (VYT),
    ///         the principal is written off, and the loan is deleted.
    ///         No asset payment is required (and none is taken). Cap is
    ///         NOT restored (the system permanently underbacked itself
    ///         when the loan went underwater — same accounting as the
    ///         underwater branch of repayLoan).
    /// @param  asset      The loan asset to liquidate against.
    /// @param  borrowers  List of borrower addresses to check & liquidate.
    /// @return liquidated Count of borrowers actually liquidated. Borrowers
    ///                    that are not underwater (or have no loan) are
    ///                    silently skipped so a single bad input does not
    ///                    grief the whole batch.
    function liquidateUnderwater(
        address asset,
        address[] calldata borrowers
    ) external nonReentrant returns (uint256 liquidated) {
        uint256 rate = interestRatePerSecond;
        address recipient = underwaterRecipient;
        if (recipient == address(0)) revert InvalidAddress();

        uint256 len = borrowers.length;
        for (uint256 i = 0; i < len;) {
            address borrower = borrowers[i];
            unchecked { ++i; }

            if (!_loanExists(borrower, asset)) continue;

            Loan storage loan = _loans[borrower][asset];
            uint256 collateral = loan.collateral;
            uint256 elapsed = block.timestamp - loan.interestAppliedAt;
            uint256 newAccrual = (collateral * rate * elapsed) / WAD;
            uint256 totalInterest = loan.interestCarry + newAccrual;

            // Only underwater positions qualify
            if (totalInterest < collateral) continue;

            uint256 fullPrincipal = loan.principal;

            // Route the entire VY collateral to VYT (no reserve withdrawal).
            vrt.applyInterest(asset, collateral, recipient);

            // Write off principal and close the loan.
            _totalLoanedPerAsset[asset] -= fullPrincipal;
            delete _loans[borrower][asset];

            _emitLoanEvent(
                LoanEventType.Liquidated,
                borrower,
                asset,
                -int256(collateral),
                -int256(fullPrincipal),
                0,
                collateral // entire collateral was interest
            );

            unchecked { ++liquidated; }
        }

        if (liquidated > 0) _pingVRYO();
    }

    function _pingVRYO() internal {
        IValinityReserveYieldOfficer v = vryo;
        if (address(v) == address(0)) return;
        try v.execute() {} catch (bytes memory reason) {
            emit VryoHeartbeatFailed(reason);
        }
    }

    /// @notice Reverts if collateral exceeds loanCapBps % of true circulating VY supply.
    /// @dev Circulating supply = totalSupply - VY in VRT - VY in VYT (from VCO).
    function _checkLoanCap(uint256 collateral) internal view {
        uint256 circulatingVY = vco.getTotalCirculatingVY();
        uint256 maxCollateral = (circulatingVY * loanCapBps) / BPS_MULTIPLIER;
        if (collateral > maxCollateral) revert CollateralExceedsLoanCap();
    }

    function _loanExists(
        address borrower,
        address asset
    ) internal view returns (bool) {
        return _loans[borrower][asset].openedAt > 0;
    }

    function _checkActiveLoan(address borrower, address asset) internal view {
        if (!_loanExists(borrower, asset)) revert LoanNotFound();
    }

    /// @notice Calcula el processing fee en VY basado en el colateral
    /// @param vyCollateral Cantidad de VY usado como colateral
    /// @return fee El fee en VY (1% del colateral)
    function _getProcessingFee(
        uint256 vyCollateral
    ) internal view returns (uint256) {
        return (vyCollateral * processingFeePercentage) / BPS_MULTIPLIER;
    }

    /**
     * LTV = Reserve Balance / VY Collateral Cap
     * Expressed in asset units per VY, using 1e18 fixed-point scaling.
     * This reflects how many units of the given asset currently back each VY
     * that has been collateralized for this asset.
     *
     * Examples:
     * - 1e18 → 1 unit of asset per VY (e.g. 1 ETH / VY)
     * - 0.5e18 → 0.5 units of asset per VY
     * - 2e18 → 2 units of asset per VY (over-collateralized from asset's POV)
     *
     * A higher value indicates that more of the asset is backing each unit of VY cap,
     * which may affect how much of the asset is borrowable for a given VY input.
     */
    function _getLTV(
        address asset,
        uint8 assetDecimals
    ) internal view returns (uint256) {
        uint256 reserve = IERC20(asset).balanceOf(address(vrt));
        uint256 cap = vco.getAssetCap(asset);
        if (cap == 0) return 0;

        uint256 scaledReserve = _scaleDecimals(
            reserve,
            assetDecimals,
            DEFAULT_DECIMALS
        );
        return (scaledReserve * WAD) / cap;
    }

    function _depositCollateral(
        address borrower,
        address asset,
        uint256 vyAmount
    ) internal {
        vyToken.transferFrom(borrower, address(this), vyAmount);
        _loans[borrower][asset].collateral += vyAmount;
        vco.decreaseAssetCap(asset, vyAmount);
    }

    /// @notice Distribuye el principal completo al borrower (sin descuento de fee)
    /// @dev El fee se cobra en VY desde el colateral, no del asset prestado
    ///      VLO holds VY collateral internally, VRT just sends the asset
    function _distributeLoan(
        address borrower,
        address asset,
        uint256 assetAmount,
        uint256 vyCollateral
    ) internal {
        // Approve VRT to pull VY from this contract for collateral tracking
        _ensureMaxAllowance(IERC20(address(vyToken)), address(vrt), vyCollateral);
        
        // Transfer full amount to borrower (fee is taken from VY collateral)
        if (asset == address(_weth)) {
            // For WETH, we need to receive it here first, then unwrap and send as ETH
            vrt.processLoan(asset, assetAmount, vyCollateral, address(this));
            _weth.withdraw(assetAmount);
            // Use call instead of transfer to avoid 2300 gas limit issues
            (bool success, ) = payable(borrower).call{value: assetAmount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            // For other assets, VRT sends directly to borrower
            vrt.processLoan(asset, assetAmount, vyCollateral, borrower);
        }
    }
    
    function _processLoanIncrease(
        address borrower,
        address asset,
        uint256 collateral
    ) internal returns (uint256 principal, uint256 fee) {
        uint8 assetDecimals = _getAssetDecimals(asset);

        // Calculate processing fee in VY (1% of collateral)
        fee = _getProcessingFee(collateral);
        uint256 netCollateral = collateral - fee;

        // Convert net collateral to principal (e.g. WBTC)
        uint256 ltv = _getLTV(asset, assetDecimals);
        principal = _toPrincipal(assetDecimals, ltv, netCollateral);

        if (principal == 0) revert CollateralTooLow();

        // Transfer fee in VY from borrower to fee recipient
        if (fee > 0) {
            vyToken.transferFrom(borrower, processingFeeRecipient, fee);
        }

        // Deposit net collateral (pull VY from borrower → this contract, update internal state, decrease cap)
        _depositCollateral(borrower, asset, netCollateral);

        // Distribute full principal to borrower using the collateral we just received
        _distributeLoan(borrower, asset, principal, netCollateral);

        // Update loan principal and total loaned
        _loans[borrower][asset].principal += principal;
        _totalLoanedPerAsset[asset] += principal;
    }

    function _migrateLoan(
        address borrower,
        address asset,
        uint256 collateral,
        uint256 principal
    ) internal onlySupportedAsset(asset) {
        if (isActive(borrower, asset)) revert ActiveLoanExists();

        // Validate values
        if (collateral == 0) revert CollateralTooLow();
        if (principal == 0) revert PrincipalTooLow();

        // Pull VY from admin (msg.sender) and deposit into VRT
        vyToken.transferFrom(_msgSender(), address(this), collateral);
        _ensureMaxAllowance(IERC20(address(vyToken)), address(vrt), collateral);
        vrt.depositCollateral(asset, collateral);

        // Set loan state
        Loan storage loan = _loans[borrower][asset];
        loan.collateral = collateral;
        loan.principal = principal;
        loan.openedAt = uint64(block.timestamp);
        loan.interestAppliedAt = uint64(block.timestamp);

        // Update total loaned
        _totalLoanedPerAsset[asset] += principal;

        _emitLoanEvent(
            LoanEventType.Migrated,
            borrower,
            asset,
            int256(collateral),
            int256(principal),
            0,
            0
        );
    }

    function _toPrincipal(
        uint8 assetDecimals,
        uint256 ltv,
        uint256 collateral
    ) internal pure returns (uint256) {
        uint256 raw = (collateral * ltv) / WAD;
        return _scaleDecimals(raw, DEFAULT_DECIMALS, assetDecimals);
    }

    function _toCollateral(
        uint8 assetDecimals,
        uint256 ltv,
        uint256 principal
    ) internal pure returns (uint256) {
        if (ltv == 0) return 0;
        uint256 scaledPrincipal = _scaleDecimals(
            principal,
            assetDecimals,
            DEFAULT_DECIMALS
        );
        return (scaledPrincipal * WAD) / ltv;
    }

    function _getAssetDecimals(address asset) internal view returns (uint8) {
        try IERC20Metadata(asset).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return DEFAULT_DECIMALS;
        }
    }

    function _scaleDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256) {
        // Decimal differences are bounded (0-18), safe to use unchecked
        unchecked {
            if (fromDecimals > toDecimals) {
                return amount / 10 ** (fromDecimals - toDecimals);
            } else if (fromDecimals < toDecimals) {
                return amount * 10 ** (toDecimals - fromDecimals);
            }
            return amount;
        }
    }

    function _emitLoanEvent(
        LoanEventType eventType,
        address borrower,
        address asset,
        int256 deltaCollateral,
        int256 deltaPrincipal,
        uint256 processingFeeAmount,
        uint256 interestFeeAmount
    ) internal {
        Loan storage loan = _loans[borrower][asset];
        emit LoanEvent(
            eventType,
            borrower,
            asset,
            deltaCollateral,
            deltaPrincipal,
            processingFeeAmount,
            interestFeeAmount,
            loan.collateral,
            loan.principal
        );
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ADMIN_ROLE) {}

    /// @dev Lazy max-approval: pay an SSTORE once per (token, spender) pair,
    ///      then only a single SLOAD on subsequent calls.
    function _ensureMaxAllowance(
        IERC20 token,
        address spender,
        uint256 amount
    ) internal {
        if (token.allowance(address(this), spender) < amount) {
            SafeERC20.forceApprove(token, spender, type(uint256).max);
        }
    }

    /// @notice Reserved storage gap for future upgrades (append-only).
    /// @dev Sized so total V3 storage tail + gap = 40 slots.
    uint256[39] private __gap;
}
