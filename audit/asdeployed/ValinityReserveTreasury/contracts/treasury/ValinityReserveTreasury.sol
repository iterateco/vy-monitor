// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import { PositionSnapshot, pairKeyOf } from "../interfaces/IValinityPositions.sol";
import { V3LiquidityMath } from "../library/V3LiquidityMath.sol";

// Minimal inlined interfaces — Uniswap V3 periphery is pinned to 0.7.6, so we cannot
// import it directly. Same convention used by VLM and VRYO.
interface INonfungiblePositionManager {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);
    function positions(uint256 tokenId)
        external view returns (
            uint96 nonce, address operator, address token0, address token1, uint24 fee,
            int24 tickLower, int24 tickUpper, uint128 liquidity,
            uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0, uint128 tokensOwed1
        );
    function setApprovalForAll(address operator, bool approved) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function slot0() external view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

/**
 * @title ValinityReserveTreasury (VRT)
 * @notice Treasury that holds reserve assets (WBTC, WETH, etc.) and tracks VY collateralization
 * @dev UUPS upgradeable. Supports loan operations (via VLO) and buyback withdrawals.
 *      After migrateTo() is called, this contract should be considered defunct.
 */
contract ValinityReserveTreasury is UUPSUpgradeable, AccessControl, ReentrancyGuardTransient, Initializable, IERC721Receiver {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER_ROLE");
    bytes32 public constant BUYBACK_ROLE = keccak256("BUYBACK_ROLE");
    /// @notice Authoring role for Uniswap V3 positions. Held by VLM only.
    /// @dev Must be disjoint from VRYO_ROLE. See access invariants in contract natspec.
    bytes32 public constant VLM_ROLE = keccak256("VLM_ROLE");
    /// @notice Liquidity recall role. Held by VRYO only.
    /// @dev Must be disjoint from VLM_ROLE.
    bytes32 public constant VRYO_ROLE = keccak256("VRYO_ROLE");

    uint256 public constant MAX_BATCH_SIZE = 20;

    /// @notice The VY token address
    address public vyToken;

    /// @notice VY collateral locked per reserve asset
    mapping(address asset => uint256 vyLocked) private _collateralizedVY;

    error InvalidAddress();
    error InvalidAsset();
    error InvalidRecipient();
    error InsufficientBalance();
    error InsufficientCollateral();
    error ZeroAmount();
    error ArrayTooLarge();
    error EmptyArray();
    error ArrayLengthMismatch();

    // V3 position-management errors (distinct names aid cross-contract debugging).
    error InvalidParam();
    error InvalidSender();
    error InvalidOperator();
    error InvalidTimestamp();
    error ExpiredDeadline();
    error PositionAlreadyActive();
    error NoActivePosition();
    error NotOwner();
    error TokenIdMismatch();
    error TokenMismatch();
    error PoolMismatch();
    error PairNotConfigured();
    error PairKeyMismatch();
    error ActivePositionsExist();
    error PairAlreadyRegistered();

    event LoanProcessed(
        address indexed asset,
        address indexed borrower,
        uint256 assetAmountOut,
        uint256 vyAmountIn
    );
    event LoanReleased(
        address indexed asset,
        address indexed borrower,
        uint256 assetAmountIn,
        uint256 vyAmountOut
    );
    event InterestApplied(address indexed asset, address indexed recipient, uint256 vyAmount);
    event CollateralDeposited(address indexed asset, uint256 vyAmount);
    event TreasuryMigrated(address indexed newTreasury, address[] tokens, uint256 vyAmount);
    event BuybackWithdrawal(address indexed asset, address indexed recipient, uint256 amount);
    event YieldDeployed(address indexed asset, address indexed recipient, uint256 amount);

    // V3 position-management events.
    event V3PositionReceived(bytes32 indexed pairKey, uint256 indexed tokenId, address token0, address token1);
    event V3LiquidityDecreased(
        bytes32 indexed pairKey,
        uint256 indexed tokenId,
        uint128 liquidityBurned,
        uint256 amount0Out,
        uint256 amount1Out
    );
    event SnapshotWritten(
        bytes32 indexed pairKey,
        uint256 indexed tokenId,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint64 updatedAt
    );
    event SnapshotRefreshedByDecrease(
        bytes32 indexed pairKey,
        uint256 indexed tokenId,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint64 updatedAt
    );
    event PositionSnapshotCleared(bytes32 indexed pairKey);
    event LiquidityManagerFunded(
        bytes32 indexed pairKey,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1
    );
    event NpmApprovalUpdated(address indexed operator, bool approved);
    event PairRegistered(bytes32 indexed pairKey, address token0, address token1);
    event PairUnregistered(bytes32 indexed pairKey);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address adminAddress, address _vyToken) public initializer {
        if (adminAddress == address(0)) revert InvalidAddress();
        if (_vyToken == address(0)) revert InvalidAddress();

        vyToken = _vyToken;

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
        _setRoleAdmin(OFFICER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(BUYBACK_ROLE, ADMIN_ROLE);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LOAN FUNCTIONS (VLO only)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Process a loan: receive VY from VLO, send asset to borrower
     * @dev VLO determines exact amounts. Treasury just executes.
     *      VLO must approve this contract before calling.
     * @param asset Reserve asset to send out
     * @param assetAmountOut Exact amount of asset to send to borrower
     * @param vyAmountIn Exact amount of VY to pull from VLO and lock
     * @param borrower Recipient of the asset
     */
    function processLoan(
        address asset,
        uint256 assetAmountOut,
        uint256 vyAmountIn,
        address borrower
    ) external onlyRole(OFFICER_ROLE) nonReentrant {
        if (asset == address(0)) revert InvalidAsset();
        if (borrower == address(0)) revert InvalidRecipient();
        if (assetAmountOut == 0 || vyAmountIn == 0) revert ZeroAmount();

        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < assetAmountOut) revert InsufficientBalance();

        // Pull VY from VLO (msg.sender)
        IERC20(vyToken).safeTransferFrom(msg.sender, address(this), vyAmountIn);

        // Track collateralization
        _collateralizedVY[asset] += vyAmountIn;

        // Send asset to borrower
        IERC20(asset).safeTransfer(borrower, assetAmountOut);

        emit LoanProcessed(asset, borrower, assetAmountOut, vyAmountIn);
    }

    /**
     * @notice Release a loan: receive asset from borrower, send VY to VLO
     * @dev VLO determines exact amounts. Treasury just executes.
     *      Borrower must approve this contract before VLO calls.
     * @param asset Reserve asset to receive back
     * @param assetAmountIn Exact amount of asset to pull from borrower
     * @param vyAmountOut Exact amount of VY to release to VLO
     * @param borrower Source of the asset repayment
     */
    function releaseLoan(
        address asset,
        uint256 assetAmountIn,
        uint256 vyAmountOut,
        address borrower
    ) external onlyRole(OFFICER_ROLE) nonReentrant {
        if (asset == address(0)) revert InvalidAsset();
        if (borrower == address(0)) revert InvalidRecipient();
        if (assetAmountIn == 0 || vyAmountOut == 0) revert ZeroAmount();

        if (_collateralizedVY[asset] < vyAmountOut) revert InsufficientCollateral();

        // Pull asset from borrower
        IERC20(asset).safeTransferFrom(borrower, address(this), assetAmountIn);

        // Reduce collateralization tracking
        _collateralizedVY[asset] -= vyAmountOut;

        // Send VY to VLO (msg.sender)
        IERC20(vyToken).safeTransfer(msg.sender, vyAmountOut);

        emit LoanReleased(asset, borrower, assetAmountIn, vyAmountOut);
    }

    /**
     * @notice Apply accrued interest by sending VY from collateral to the interest recipient
     * @dev Used by VLO during increaseLoan to extract accrued interest from existing collateral.
     *      Deducts vyAmount from the asset's collateralized VY and transfers it to the recipient.
     * @param asset The reserve asset whose collateral pool to debit
     * @param vyAmount Amount of VY interest to apply
     * @param recipient Address to receive the VY interest (the VYT)
     */
    function applyInterest(
        address asset,
        uint256 vyAmount,
        address recipient
    ) external onlyRole(OFFICER_ROLE) nonReentrant {
        if (asset == address(0)) revert InvalidAsset();
        if (recipient == address(0)) revert InvalidRecipient();
        if (vyAmount == 0) revert ZeroAmount();
        if (_collateralizedVY[asset] < vyAmount) revert InsufficientCollateral();

        _collateralizedVY[asset] -= vyAmount;
        IERC20(vyToken).safeTransfer(recipient, vyAmount);

        emit InterestApplied(asset, recipient, vyAmount);
    }

    /**
     * @notice Deposit VY as collateral without sending out any reserve asset
     * @dev Used by VLO during loan migration to sync VRT state
     *      VLO must approve this contract before calling.
     * @param asset The reserve asset to associate the collateral with
     * @param vyAmount Amount of VY to pull from caller and lock
     */
    function depositCollateral(
        address asset,
        uint256 vyAmount
    ) external onlyRole(OFFICER_ROLE) nonReentrant {
        if (asset == address(0)) revert InvalidAsset();
        if (vyAmount == 0) revert ZeroAmount();

        IERC20(vyToken).safeTransferFrom(msg.sender, address(this), vyAmount);
        _collateralizedVY[asset] += vyAmount;

        emit CollateralDeposited(asset, vyAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get collateralized VY for an asset
     * @param asset The asset to check
     * @return VY amount locked as collateral for this asset
     */
    function collateralizedOf(address asset) external view returns (uint256) {
        return _collateralizedVY[asset];
    }

    /**
     * @notice Get total reserve balance for an asset
     * @param asset The asset to check
     * @return Total balance held in treasury
     */
    function getReserveBalance(address asset) external view returns (uint256) {
        if (asset == address(0)) return 0;
        return IERC20(asset).balanceOf(address(this));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BUYBACK FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw assets for buyback operations
     * @dev Only callable by BuybackOfficer. Does not affect collateralization tracking.
     *      Zero amounts are silently skipped. For single asset, pass arrays of length 1.
     * @param assets Array of asset addresses to withdraw
     * @param amounts Array of amounts to withdraw
     * @param recipient Address to receive all assets (typically DEX or aggregator)
     */
    function withdrawForBuyback(
        address[] calldata assets,
        uint256[] calldata amounts,
        address recipient
    ) external onlyRole(BUYBACK_ROLE) nonReentrant {
        uint256 length = assets.length;
        if (length != amounts.length) revert ArrayLengthMismatch();
        if (length == 0) revert EmptyArray();
        if (length > MAX_BATCH_SIZE) revert ArrayTooLarge();
        if (recipient == address(0)) revert InvalidRecipient();

        for (uint256 i = 0; i < length;) {
            address asset = assets[i];
            uint256 amt = amounts[i];
            if (asset == address(0)) revert InvalidAsset();

            if (amt != 0) {
                uint256 balance = IERC20(asset).balanceOf(address(this));
                if (balance < amt) revert InsufficientBalance();

                IERC20(asset).safeTransfer(recipient, amt);

                emit BuybackWithdrawal(asset, recipient, amt);
            }

            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // YIELD FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy reserve assets for yield generation
     * @dev Restricted to VRYO_ROLE — the yield officer is the sole authorized
     *      caller for pulling reserves into V3 deployments.
     * @param assets Reserve asset addresses to deploy
     * @param amounts Amounts to deploy per asset
     * @param recipient Destination (VRYO)
     */
    function deployForYield(
        address[] calldata assets,
        uint256[] calldata amounts,
        address recipient
    ) external onlyRole(VRYO_ROLE) nonReentrant {
        uint256 length = assets.length;
        if (length != amounts.length) revert ArrayLengthMismatch();
        if (length == 0) revert EmptyArray();
        if (length > MAX_BATCH_SIZE) revert ArrayTooLarge();
        if (recipient == address(0)) revert InvalidRecipient();

        for (uint256 i = 0; i < length;) {
            address asset = assets[i];
            uint256 amt = amounts[i];
            if (asset == address(0)) revert InvalidAsset();

            if (amt != 0) {
                if (IERC20(asset).balanceOf(address(this)) < amt) {
                    revert InsufficientBalance();
                }

                IERC20(asset).safeTransfer(recipient, amt);
                emit YieldDeployed(asset, recipient, amt);
            }

            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MIGRATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Migrate all assets (including VY collateral) to a new treasury
     * @dev After migration, this contract should be considered defunct.
     *      Collateralization tracking remains but is stale.
     *
     *      V3 POSITIONS NOTE: this function does NOT migrate V3 NFTs. If any V3
     *      position is active (`_activeTokenId[k] != 0` for any managed pairKey),
     *      admin MUST first call VLM's `burnPosition` for each active pair so all
     *      value is back as tokens in VRT, then call this function.
     * @param newTreasury Address of the new treasury contract
     * @param tokens Array of reserve asset addresses to migrate
     */
    function migrateTo(address newTreasury, address[] calldata tokens) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (newTreasury == address(0)) revert InvalidAddress();
        if (_activePositionCount != 0) revert ActivePositionsExist();
        uint256 length = tokens.length;
        if (length > MAX_BATCH_SIZE) revert ArrayTooLarge();

        // Migrate specified reserve assets (VY handled separately)
        for (uint256 i = 0; i < length;) {
            address tok = tokens[i];
            if (tok == address(0)) revert InvalidAsset();

            if (tok != vyToken) {
                uint256 balance = IERC20(tok).balanceOf(address(this));
                if (balance > 0) {
                    IERC20(tok).safeTransfer(newTreasury, balance);
                }
            }

            unchecked { ++i; }
        }

        // Migrate VY collateral
        uint256 vyBalance = IERC20(vyToken).balanceOf(address(this));
        if (vyBalance > 0) {
            IERC20(vyToken).safeTransfer(newTreasury, vyBalance);
        }

        emit TreasuryMigrated(newTreasury, tokens, vyBalance);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UUPS UPGRADE
    // ═══════════════════════════════════════════════════════════════════════════

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    // ═══════════════════════════════════════════════════════════════════════════
    // V3 POSITION MANAGEMENT (V2 UPGRADE)
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // Role model (disjoint, enforced off-chain by admin granting):
    //   VLM_ROLE  → VLM only: author snapshots, fund liquidity, clear, receive NFTs.
    //   VRYO_ROLE → VRYO only: recall liquidity (decrease + collect + re-snapshot).
    //
    // V3 NFT CUSTODY INVARIANT: VRT only custodies V3 NFTs minted by VLM for the
    // managed pairs. VLM is granted `operatorForAll` on the NonfungiblePositionManager.
    // Adding any other V3 NFT strategy to this treasury requires revoking this blanket
    // approval and migrating to per-token approvals, or VLM will have operator rights
    // over the new NFTs.
    // ═══════════════════════════════════════════════════════════════════════════

    // --- V2 storage (append-only; see __gap shrink below) ---
    INonfungiblePositionManager internal _npm;       // slot +1
    IUniswapV3Factory internal _factory;              // slot +2

    /// @notice Active snapshot per pair (full struct). Source of truth for VRYO reads.
    mapping(bytes32 pairKey => PositionSnapshot) internal _snapshots; // slot +3

    /// @notice Active tokenId per pair. Mirrors `_snapshots[k].tokenId` for cheap reads
    ///         and tamper-proof cross-checks inside `setPositionSnapshot`.
    mapping(bytes32 pairKey => uint256 tokenId) internal _activeTokenId; // slot +4

    /// @notice Pinned pair tokens set on `receiveV3Position`. Scope anchor for
    ///         `fundLiquidityManager` — VLM can only pull the pair's own tokens.
    mapping(bytes32 pairKey => address token0) internal _pairToken0;    // slot +5
    mapping(bytes32 pairKey => address token1) internal _pairToken1;    // slot +6

    /// @notice Count of pair keys currently holding an active V3 NFT. Used by
    ///         `migrateTo` to block migration while NFTs are outstanding (they
    ///         are not transferable by this function).
    uint256 internal _activePositionCount;                               // slot +7

    /**
     * @notice Reinitializer for V3 position management.
     * @dev Can only be called once by admin during UUPS upgrade via upgradeToAndCall.
     * @param npm_ Uniswap V3 NonfungiblePositionManager address.
     * @param factory_ Uniswap V3 Factory address.
     */
    function initializeV2(address npm_, address factory_) external reinitializer(2) onlyRole(ADMIN_ROLE) {
        if (npm_ == address(0) || factory_ == address(0)) revert InvalidAddress();
        _npm = INonfungiblePositionManager(npm_);
        _factory = IUniswapV3Factory(factory_);

        _setRoleAdmin(VLM_ROLE, ADMIN_ROLE);
        _setRoleAdmin(VRYO_ROLE, ADMIN_ROLE);
    }

    // --- Views ---

    function npm() external view returns (address) { return address(_npm); }
    function uniswapV3Factory() external view returns (address) { return address(_factory); }

    /// @notice Full snapshot read path for VRYO and VLM. Returns zero-struct if unset.
    function getPositionSnapshot(bytes32 pairKey) external view returns (PositionSnapshot memory) {
        return _snapshots[pairKey];
    }

    function getActiveTokenId(bytes32 pairKey) external view returns (uint256) {
        return _activeTokenId[pairKey];
    }

    function getPairTokens(bytes32 pairKey) external view returns (address token0, address token1) {
        return (_pairToken0[pairKey], _pairToken1[pairKey]);
    }

    /// @notice Number of pairs currently holding an active V3 NFT.
    function activePositionCount() external view returns (uint256) {
        return _activePositionCount;
    }

    // --- ERC-721 receive hook (defense-in-depth) ---

    /**
     * @notice Rejects any NFT not originating from a VLM-initiated NPM action.
     * @dev In the current design VLM mints directly to VRT (recipient = address(this)),
     *      which does NOT trigger this hook. Kept for defense-in-depth against future
     *      post-rebalance NFT transfers into VRT.
     */
    function onERC721Received(
        address operator,
        address /*from*/,
        uint256 /*tokenId*/,
        bytes calldata /*data*/
    ) external view override returns (bytes4) {
        if (msg.sender != address(_npm)) revert InvalidSender();
        if (!hasRole(VLM_ROLE, operator)) revert InvalidOperator();
        return IERC721Receiver.onERC721Received.selector;
    }

    // --- VLM-facing writes ---

    /**
     * @notice Binds a VLM-minted tokenId to a pre-registered pairKey.
     * @dev VLM must call this after `npm.mint(... recipient: address(vrt) ...)`.
     *      The pair must have been registered by admin via `registerPair` beforehand;
     *      the NFT's tokens must match the pinned tokens and the claimed pairKey.
     *      Rejects if VRT does not own the tokenId.
     */
    function receiveV3Position(bytes32 pairKey, uint256 tokenId)
        external
        onlyRole(VLM_ROLE)
        nonReentrant
    {
        if (tokenId == 0) revert InvalidParam();
        if (_activeTokenId[pairKey] != 0) revert PositionAlreadyActive();

        address pinned0 = _pairToken0[pairKey];
        address pinned1 = _pairToken1[pairKey];
        if (pinned0 == address(0) || pinned1 == address(0)) revert PairNotConfigured();

        (, , address t0, address t1, , , , , , , , ) = _npm.positions(tokenId);
        if (_npm.ownerOf(tokenId) != address(this)) revert NotOwner();

        // The NFT's tokens must match the registered pins AND the claimed pairKey.
        if (t0 != pinned0 || t1 != pinned1) revert TokenMismatch();
        if (pairKeyOf(t0, t1) != pairKey) revert PairKeyMismatch();

        _activeTokenId[pairKey] = tokenId;
        unchecked { ++_activePositionCount; }

        emit V3PositionReceived(pairKey, tokenId, t0, t1);
    }

    /**
     * @notice Author the canonical snapshot for a pair. VLM-only.
     * @dev `snap.tokenId` must match `_activeTokenId[pairKey]` AND must be non-zero.
     *      To wipe snapshot state after a burn, VLM calls `clearPositionSnapshot`
     *      instead of writing a zero struct here.
     */
    function setPositionSnapshot(bytes32 pairKey, PositionSnapshot calldata snap)
        external
        onlyRole(VLM_ROLE)
    {
        if (snap.updatedAt != uint64(block.timestamp)) revert InvalidTimestamp();
        if (snap.tokenId == 0) revert InvalidParam();
        if (snap.tokenId != _activeTokenId[pairKey]) revert TokenIdMismatch();
        if (snap.poolAddress == address(0)) revert InvalidParam();
        // Defense-in-depth: reject malformed range bounds so VRYO's recall
        // math can never see inverted ticks / sqrt ratios from a buggy VLM.
        if (snap.tickLower >= snap.tickUpper) revert InvalidParam();
        if (snap.sqrtRatioLowerX96 >= snap.sqrtRatioUpperX96) revert InvalidParam();
        if (snap.token0 != _pairToken0[pairKey]) revert TokenMismatch();
        if (snap.token1 != _pairToken1[pairKey]) revert TokenMismatch();
        // The single most important check: the canonical pool must match the
        // factory-resolved pool. Without this, a compromised VLM could point
        // snapshots at an attacker-controlled "pool" whose slot0() returns
        // manipulated sqrtPrices, which VRYO trusts.
        if (_factory.getPool(snap.token0, snap.token1, snap.fee) != snap.poolAddress) {
            revert PoolMismatch();
        }

        _snapshots[pairKey] = snap;
        emit SnapshotWritten(pairKey, snap.tokenId, snap.sqrtPriceX96, snap.liquidity, snap.updatedAt);
    }

    /**
     * @notice Clear the active snapshot + tokenId for a pair.
     * @dev VLM must call this after `npm.burn(tokenId)` to leave position state clean.
     *      Token pins (`_pairToken0/1`) are PRESERVED — they are owned by the pair
     *      registration lifecycle (`registerPair` / `unregisterPair`), not the
     *      per-position lifecycle. This lets VLM's rebalance flow
     *      `close → fund → clear → mint → receive` keep funding working across
     *      the snapshot-cleared window. Idempotent.
     */
    function clearPositionSnapshot(bytes32 pairKey) external onlyRole(VLM_ROLE) nonReentrant {
        if (_activeTokenId[pairKey] == 0 && _snapshots[pairKey].tokenId == 0) return;

        bool hadActive = _activeTokenId[pairKey] != 0;
        delete _snapshots[pairKey];
        _activeTokenId[pairKey] = 0;
        if (hadActive) {
            unchecked { --_activePositionCount; }
        }

        emit PositionSnapshotCleared(pairKey);
    }

    /**
     * @notice Transfer scoped amounts of the pair's pinned tokens to the caller (VLM).
     * @dev Capped at VRT balance; returns amounts actually sent (no revert on shortfall)
     *      so VLM can size the subsequent mint deterministically. Only pinned tokens
     *      are transferable — VLM has no access to arbitrary treasury assets.
     */
    function fundLiquidityManager(bytes32 pairKey, uint256 amount0, uint256 amount1)
        external
        onlyRole(VLM_ROLE)
        nonReentrant
        returns (uint256 sent0, uint256 sent1)
    {
        address t0 = _pairToken0[pairKey];
        address t1 = _pairToken1[pairKey];
        if (t0 == address(0) || t1 == address(0)) revert PairNotConfigured();

        if (amount0 != 0) {
            uint256 bal0 = IERC20(t0).balanceOf(address(this));
            sent0 = amount0 > bal0 ? bal0 : amount0;
            if (sent0 != 0) IERC20(t0).safeTransfer(msg.sender, sent0);
        }
        if (amount1 != 0) {
            uint256 bal1 = IERC20(t1).balanceOf(address(this));
            sent1 = amount1 > bal1 ? bal1 : amount1;
            if (sent1 != 0) IERC20(t1).safeTransfer(msg.sender, sent1);
        }

        emit LiquidityManagerFunded(pairKey, msg.sender, sent0, sent1);
    }

    // --- VRYO-facing recall ---

    /**
     * @notice Decrease the active position's liquidity, collect principal + owed fees
     *         to VRT, and re-snapshot. VRYO-only.
     * @dev Order is Decrease → Collect → Re-snapshot. Range params (ticks, sqrtRatios)
     *      are intentionally NOT refreshed here; only VLM writes those on mint/rebalance.
     */
    function decreasePositionLiquidity(
        bytes32 pairKey,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external onlyRole(VRYO_ROLE) nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 tokenId = _activeTokenId[pairKey];
        if (tokenId == 0) revert NoActivePosition();
        if (liquidity == 0) revert ZeroAmount();
        if (deadline < block.timestamp) revert ExpiredDeadline();

        _npm.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: deadline
        }));

        // Collect proceeds DIRECTLY to msg.sender (VRYO) so unmanaged
        // counterparty tokens (e.g. USDC for the PAXG/USDC pair) never sit in
        // VRT — preserves the invariant that VRT only custodies managed
        // reserve assets (WETH, WBTC, PAXG). VRYO performs the reverse-zap
        // and only the unified managed asset is later transferred back to VRT.
        (amount0, amount1) = _npm.collect(INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: msg.sender,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        }));

        _reSnapshotAfterDecrease(pairKey, tokenId);

        emit V3LiquidityDecreased(pairKey, tokenId, liquidity, amount0, amount1);
    }

    function _reSnapshotAfterDecrease(bytes32 pairKey, uint256 tokenId) internal {
        PositionSnapshot storage s = _snapshots[pairKey];
        // Defensive: VRYO may not call decreasePositionLiquidity until VLM has
        // written the initial snapshot (poolAddress is the gate). Without this
        // check, slot0() on address(0) produces an opaque low-level revert.
        if (s.poolAddress == address(0)) revert NoActivePosition();

        (, , , , , int24 tickLower, int24 tickUpper, uint128 liq,
            , , uint128 owed0, uint128 owed1) = _npm.positions(tokenId);

        (uint160 sqrtP, int24 curTick, , , , , ) = IUniswapV3Pool(s.poolAddress).slot0();

        // Recompute principal from the post-burn liquidity using the shared library
        // VLM also uses. Using a different implementation here would cause snapshots
        // to oscillate between the two writers.
        (uint256 p0, uint256 p1) = V3LiquidityMath.getAmountsForLiquidity(
            sqrtP, s.sqrtRatioLowerX96, s.sqrtRatioUpperX96, liq
        );

        s.liquidity    = liq;
        s.sqrtPriceX96 = sqrtP;
        s.principal0   = p0;
        s.principal1   = p1;
        s.feesOwed0    = uint256(owed0);
        s.feesOwed1    = uint256(owed1);
        s.inRange      = (tickLower <= curTick && curTick < tickUpper);
        s.updatedAt    = uint64(block.timestamp);

        // Emit both events so keeper heartbeats (SnapshotWritten) aren't missed on
        // VRYO-path refreshes, and monitoring can still distinguish the source.
        emit SnapshotRefreshedByDecrease(pairKey, tokenId, sqrtP, liq, s.updatedAt);
        emit SnapshotWritten(pairKey, tokenId, sqrtP, liq, s.updatedAt);
    }

    // --- Admin: pair registration + NPM operator management ---

    /**
     * @notice Register a token pair for V3 position management. Admin-only.
     * @dev Must be called once per pair BEFORE VLM's first `mintPosition` for that pair.
     *      Sets the token pins used by `fundLiquidityManager` and validated by
     *      `receiveV3Position`. Idempotent on identical inputs; reverts if the pair
     *      is already registered with different tokens.
     * @param tokenA One of the pair's tokens (order-agnostic).
     * @param tokenB The other token.
     * @return pairKey The canonical sorted pair key.
     */
    function registerPair(address tokenA, address tokenB)
        external
        onlyRole(ADMIN_ROLE)
        returns (bytes32 pairKey)
    {
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) revert InvalidParam();

        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pairKey = pairKeyOf(t0, t1);

        address existing0 = _pairToken0[pairKey];
        address existing1 = _pairToken1[pairKey];
        if (existing0 != address(0) || existing1 != address(0)) {
            // Idempotent: identical re-registration is a no-op. Mismatched re-registration reverts.
            if (existing0 != t0 || existing1 != t1) revert PairAlreadyRegistered();
            return pairKey;
        }

        _pairToken0[pairKey] = t0;
        _pairToken1[pairKey] = t1;

        emit PairRegistered(pairKey, t0, t1);
    }

    /**
     * @notice Unregister a pair. Admin-only.
     * @dev Requires no active position. Clears token pins; subsequent
     *      `fundLiquidityManager` / `receiveV3Position` calls revert with
     *      `PairNotConfigured` until re-registered.
     */
    function unregisterPair(bytes32 pairKey) external onlyRole(ADMIN_ROLE) {
        if (_activeTokenId[pairKey] != 0) revert ActivePositionsExist();
        if (_pairToken0[pairKey] == address(0)) return; // idempotent

        _pairToken0[pairKey] = address(0);
        _pairToken1[pairKey] = address(0);

        emit PairUnregistered(pairKey);
    }

    /**
     * @notice Grant or revoke `setApprovalForAll` on the NPM for the given VLM.
     * @dev When `approved == true`, operator must currently hold `VLM_ROLE`.
     *      Revocations (`approved == false`) are always allowed so admin can
     *      clean up approvals even after revoking the role.
     *      Revoke before adding any other V3 NFT strategy (see
     *      "V3 NFT CUSTODY INVARIANT" above).
     */
    function setNpmApproval(address operator, bool approved) external onlyRole(ADMIN_ROLE) {
        if (operator == address(0)) revert InvalidAddress();
        if (approved && !hasRole(VLM_ROLE, operator)) revert InvalidOperator();
        _npm.setApprovalForAll(operator, approved);
        emit NpmApprovalUpdated(operator, approved);
    }

    /**
     * @dev UUPS storage discipline: 7 slots were consumed above
     *      (_npm, _factory, _snapshots, _activeTokenId, _pairToken0, _pairToken1,
     *       _activePositionCount). Gap shrunk from 48 → 41 to preserve downstream layout.
     */
    uint256[41] private __gap;
}
