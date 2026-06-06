// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VDAX} from "./VDAX.sol";
import {IValinityDAX} from "./interfaces/IValinityDAX.sol";

/**
 * @title ValinityDAX - Valinity Decentralized Asset Exchange
 * @notice Private DEX managing multiple V2-style pools with a single basket LP token (VDAX)
 * @dev Key features:
 *      - N internal pools: VY / Asset[i]
 *      - Single LP token (VDAX) represents proportional ownership across all pools
 *      - VY-only deposits with proportional injection across pools (organic, by current VY share)
 *      - Pro-rata withdrawals from all pools
 *      - AMM V2 swaps per pool (constant product)
 *
 * Architecture:
 * - Users deposit only VY
 * - VY is distributed proportionally to each pool's existing VY reserves
 * - Users receive VDAX tokens representing their share
 * - VDAX ownership = proportional ownership of ALL pools
 * - Withdrawals burn VDAX and return proportional amounts from each pool
 */
contract ValinityDAX is IValinityDAX, UUPSUpgradeable, AccessControl, ReentrancyGuardTransient, Initializable {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Role for administrative functions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Scoped role that gates ONLY `addPool`. Granted to VARO so it
    ///         can create new VY/launchedToken pools at tier-5 token launches
    ///         WITHOUT receiving full admin powers (no extract/pause/rescue/upgrade).
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES - TOKENS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice VY token contract
    IERC20 public VY;

    /// @notice VDAX LP token contract
    VDAX public vdax;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES - POOLS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Array of all pools
    /// @dev Pool ID = index in this array
    Pool[] public pools;

    /// @notice Mapping from asset address to pool ID (for O(1) lookup)
    /// @dev Returns 0 if asset has no pool (check hasPool mapping)
    mapping(address => uint256) public assetToPoolId;

    /// @notice Mapping from asset address to whether it has a pool
    /// @dev Required because poolId 0 is valid
    mapping(address => bool) public hasPool;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES - WHITELISTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Whitelist for swap operations
    /// @dev Only whitelisted addresses can call swap functions
    mapping(address => bool) public swapWhitelist;

    /// @notice Whitelist for liquidity operations (deposit/withdraw)
    /// @dev Only whitelisted addresses can deposit/withdraw liquidity
    mapping(address => bool) public liquidityWhitelist;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES - PAUSE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Whether deposits are paused
    bool public depositsPaused;

    /// @notice Whether withdrawals are paused
    bool public withdrawalsPaused;

    /// @notice Whether swaps are paused
    bool public swapsPaused;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initializes the ValinityDAX contract
     * @param vyAddress Address of the VY token contract
     * @param vdaxAddress Address of the VDAX token contract
     * @param adminAddress Address that will have ADMIN_ROLE
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address vyAddress, address vdaxAddress, address adminAddress) public initializer {
        if (
            vyAddress == address(0) ||
            vdaxAddress == address(0) ||
            adminAddress == address(0)
        ) {
            revert InvalidAddress();
        }

        VY = IERC20(vyAddress);
        vdax = VDAX(vdaxAddress);

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Restricts function to swap whitelisted addresses
     */
    modifier onlySwapWhitelisted() {
        if (!swapWhitelist[msg.sender]) {
            revert NotWhitelisted();
        }
        _;
    }

    /**
     * @notice Restricts function to liquidity whitelisted addresses
     */
    modifier onlyLiquidityWhitelisted() {
        if (!liquidityWhitelist[msg.sender]) {
            revert NotWhitelisted();
        }
        _;
    }

    /**
     * @notice Checks if deposits are not paused
     */
    modifier whenDepositsNotPaused() {
        if (depositsPaused) {
            revert DepositsPaused();
        }
        _;
    }

    /**
     * @notice Checks if withdrawals are not paused
     */
    modifier whenWithdrawalsNotPaused() {
        if (withdrawalsPaused) {
            revert WithdrawalsPaused();
        }
        _;
    }

    /**
     * @notice Checks if swaps are not paused
     */
    modifier whenSwapsNotPaused() {
        if (swapsPaused) {
            revert SwapsPaused();
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IValinityDAX
     */
    function getNumPools() external view returns (uint256) {
        return pools.length;
    }

    /**
     * @inheritdoc IValinityDAX
     */
    function getPoolReserves(
        uint256 poolId
    )
        external
        view
        returns (
            address asset,
            uint256 reserveVY,
            uint256 reserveAsset
        )
    {
        if (poolId >= pools.length) revert InvalidPoolId();

        Pool memory pool = pools[poolId];
        return (pool.asset, pool.reserveVY, pool.reserveAsset);
    }

    /**
     * @inheritdoc IValinityDAX
     */
    function getTotalVYReserves() public view returns (uint256 total) {
        uint256 poolsLen = pools.length;
        for (uint256 i; i < poolsLen;) {
            total += pools[i].reserveVY;
            unchecked { ++i; }
        }
    }

    /**
     * @inheritdoc IValinityDAX
     * @dev Returns user's percentage share of VDAX supply
     *      Returns the percentage with 18 decimals (1e18 = 100%)
     */
    function getUserShare(
        address user
    ) external view returns (uint256 sharePercentage) {
        uint256 totalSupply = vdax.totalSupply();
        if (totalSupply == 0) {
            return 0;
        }

        uint256 userBalance = vdax.balanceOf(user);
        sharePercentage = Math.mulDiv(userBalance, 1e18, totalSupply);
    }

    /**
     * @inheritdoc IValinityDAX
     * @dev Preview withdrawal - simulates asset→VY conversion to match actual withdraw()
     */
    function previewWithdraw(
        uint256 sharesToBurn
    ) external view returns (uint256 vyOut) {
        uint256 totalSupply = vdax.totalSupply();
        if (totalSupply == 0) revert ZeroTotalSupply();

        uint256 poolsLen = pools.length;

        for (uint256 i; i < poolsLen;) {
            Pool memory pool = pools[i];

            // Calculate pro-rata withdrawal amounts
            uint256 vyFromPool = Math.mulDiv(pool.reserveVY, sharesToBurn, totalSupply);
            uint256 assetFromPool = Math.mulDiv(pool.reserveAsset, sharesToBurn, totalSupply);

            // Accumulate VY portion
            vyOut += vyFromPool;

            // Simulate asset→VY swap (if any)
            // Denominator simplifies: (rAsset - assetFromPool + assetFromPool) = rAsset
            uint256 newReserveVY = pool.reserveVY - vyFromPool;
            if (assetFromPool > 0 && newReserveVY > 0 && pool.reserveAsset > assetFromPool) {
                vyOut += Math.mulDiv(newReserveVY, assetFromPool, pool.reserveAsset);
            }

            unchecked { ++i; }
        }
    }

    /**
     * @inheritdoc IValinityDAX
     * @dev View-only mirror of `depositVYOnly` minting math.
     *      Returns 0 when supply or reserves are zero (uninitialized state).
     */
    function previewDepositVYOnly(
        uint256 vyAmount
    ) external view returns (uint256 vdaxOut) {
        if (vyAmount == 0) return 0;
        uint256 totalSupply = vdax.totalSupply();
        if (totalSupply == 0) return 0;
        uint256 totalVYReserves = getTotalVYReserves();
        if (totalVYReserves == 0) return 0;
        // sharesMinted = (vyAmount × totalSupply) ÷ (2 × totalVYReserves)
        vdaxOut = Math.mulDiv(vyAmount, totalSupply, 2 * totalVYReserves);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS - MINTING CALCULATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate amount of VDAX tokens to mint for a VY deposit
     * @dev Implements the formula: sharesMinted = (V_dax × S) ÷ (2 × TVY_before)
     *      Uses Math.mulDiv for precise calculation without overflow
     *      The divisor of 2 ensures conservative minting
     *
     * @param vyAmount Amount of VY being deposited
     * @return sharesMinted Amount of VDAX tokens to mint
     */
    function _calculateMintAmount(
        uint256 vyAmount
    ) internal view returns (uint256 sharesMinted) {
        uint256 totalSupply = vdax.totalSupply();
        uint256 totalVYReserves = getTotalVYReserves();

        // Formula: sharesMinted = (vyAmount × totalSupply) ÷ (2 × totalVYReserves)
        // Using mulDiv to prevent overflow: mulDiv(a, b, c) = (a × b) ÷ c
        sharesMinted = Math.mulDiv(vyAmount, totalSupply, 2 * totalVYReserves);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - LIQUIDITY
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IValinityDAX
     * @dev Initialize the first pool when VDAX supply = 0
     *      Mints 10 × vySeed VDAX tokens (pre-mint for future pools)
     */
    function initializeFirstPool(
        address asset,
        uint256 vySeed,
        uint256 assetSeed,
        address recipient
    )
        external
        onlyRole(ADMIN_ROLE)
        whenDepositsNotPaused
        nonReentrant
        returns (uint256 sharesMinted)
    {
        if (asset == address(0) || recipient == address(0)) revert InvalidAddress();
        if (vySeed == 0 || assetSeed == 0) revert InvalidAmount();
        if (vdax.totalSupply() != 0) revert AlreadyInitialized();
        if (hasPool[asset]) revert PoolAlreadyExists();

        // Calculate shares to mint: 10 × vySeed (pre-mint for future pools)
        sharesMinted = 10 * vySeed;

        // Transfer tokens from caller
        VY.safeTransferFrom(msg.sender, address(this), vySeed);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assetSeed);

        // Create first pool
        uint256 poolId = pools.length;
        pools.push(
            Pool({
                asset: asset,
                reserveVY: vySeed,
                reserveAsset: assetSeed
            })
        );

        // Update mappings
        assetToPoolId[asset] = poolId;
        hasPool[asset] = true;

        // Mint VDAX tokens to recipient
        vdax.mint(recipient, sharesMinted);

        // Emit events
        emit PoolAdded(poolId, asset, vySeed, assetSeed);
        emit Deposit(recipient, sharesMinted, vySeed);
    }

    /**
     * @inheritdoc IValinityDAX
     * @dev VY-only deposit with proportional injection across pools.
     *      Each pool receives a share of vyAmount equal to its current
     *      percentage of total VY reserves (organic / self-weighted).
     *      Formula: sharesMinted = (vyAmount × totalSupply) ÷ (2 × totalVYReserves)
     */
    function depositVYOnly(
        uint256 vyAmount,
        address recipient
    )
        external
        onlyLiquidityWhitelisted
        whenDepositsNotPaused
        nonReentrant
        returns (uint256 sharesMinted)
    {
        if (recipient == address(0)) revert InvalidAddress();
        if (vyAmount == 0) revert InvalidAmount();

        uint256 poolsLen = pools.length;
        if (poolsLen == 0) revert InvalidPoolId();

        // Compute totalVY and sharesMinted in a single pool read pass.
        // _calculateMintAmount would call getTotalVYReserves() internally — inlining here
        // avoids a second full loop, saving N SLOADs per deposit.
        uint256 totalVY = getTotalVYReserves();
        sharesMinted = Math.mulDiv(vyAmount, vdax.totalSupply(), 2 * totalVY);

        // Transfer VY from caller
        VY.safeTransferFrom(msg.sender, address(this), vyAmount);

        // Distribute vyAmount proportionally to each pool's current VY share.
        // Pool i receives: vyAmount × pools[i].reserveVY / totalVY
        // The last pool absorbs any rounding dust so that Σ injected == vyAmount exactly.
        uint256 distributed;
        for (uint256 i; i < poolsLen - 1;) {
            uint256 share = Math.mulDiv(vyAmount, pools[i].reserveVY, totalVY);
            pools[i].reserveVY += share;
            distributed += share;
            unchecked { ++i; }
        }
        pools[poolsLen - 1].reserveVY += (vyAmount - distributed);

        // Mint VDAX
        vdax.mint(recipient, sharesMinted);

        emit Deposit(recipient, sharesMinted, vyAmount);
    }

    /**
     * @inheritdoc IValinityDAX
     * @dev Withdraw liquidity and receive 100% VY
     *      Burns VDAX, withdraws pro-rata from all pools, converts assets to VY
     *
     *      Flow:
     *      1. Burn VDAX tokens from caller
     *      2. For each active pool:
     *         - Calculate pro-rata VY and asset amounts
     *         - Withdraw VY portion
     *         - Convert asset portion to VY via internal swap
     *      3. Transfer all accumulated VY to recipient
     *
     *      Security:
     *      - Uses Math.mulDiv to prevent overflow
     *      - NonReentrant protection
     *      - Only liquidity whitelisted addresses
     */
    function withdraw(
        uint256 sharesToBurn,
        address recipient
    )
        external
        onlyLiquidityWhitelisted
        whenWithdrawalsNotPaused
        nonReentrant
        returns (uint256 vyOut)
    {
        if (recipient == address(0)) revert InvalidAddress();
        if (sharesToBurn == 0) revert InvalidAmount();

        uint256 totalSupply = vdax.totalSupply();
        if (totalSupply == 0) revert ZeroTotalSupply();

        // Burn VDAX tokens from caller
        vdax.burn(msg.sender, sharesToBurn);

        uint256 poolsLen = pools.length;

        // Single pass: withdraw + convert for each pool
        for (uint256 i; i < poolsLen;) {
            Pool storage pool = pools[i];

            // Cache storage reads
            uint256 rVY = pool.reserveVY;
            uint256 rAsset = pool.reserveAsset;

            // Calculate pro-rata withdrawal amounts
            uint256 vyFromPool = Math.mulDiv(rVY, sharesToBurn, totalSupply);
            uint256 assetFromPool = Math.mulDiv(rAsset, sharesToBurn, totalSupply);

            // Accumulate VY portion
            vyOut += vyFromPool;

            uint256 newReserveVY = rVY - vyFromPool;

            // Convert asset to VY via internal swap (if any)
            if (assetFromPool > 0 && newReserveVY > 0 && rAsset > assetFromPool) {
                // Swap formula: denominator simplifies from (rAsset - assetFromPool + assetFromPool) to rAsset
                uint256 vyFromSwap = Math.mulDiv(newReserveVY, assetFromPool, rAsset);

                if (vyFromSwap > 0) {
                    // Net effect: reserveAsset unchanged (withdraw + re-deposit cancel), reserveVY reduced
                    pool.reserveVY = newReserveVY - vyFromSwap;
                    vyOut += vyFromSwap;
                } else {
                    // Swap yields 0: asset stays out of pool (admin can rescue)
                    pool.reserveVY = newReserveVY;
                    pool.reserveAsset = rAsset - assetFromPool;
                }
            } else {
                pool.reserveVY = newReserveVY;
                if (assetFromPool > 0) {
                    pool.reserveAsset = rAsset - assetFromPool;
                }
            }

            unchecked { ++i; }
        }

        // Transfer all VY to recipient
        if (vyOut > 0) {
            VY.safeTransfer(recipient, vyOut);
        }

        emit Withdraw(recipient, sharesToBurn, vyOut);
    }

    /**
     * @notice Admin-only raw withdrawal: burns VDAX and returns VY + assets separately
     * @dev Does NOT convert assets to VY. Used for rebalancing when adding new pools.
     *      Returns pro-rata VY and each pool's asset directly to recipient.
     * @param sharesToBurn Amount of VDAX to burn
     * @param recipient Address to receive VY and assets
     * @return vyOut Total VY withdrawn
     */
    function adminWithdrawRaw(
        uint256 sharesToBurn,
        address recipient
    )
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        returns (uint256 vyOut)
    {
        if (recipient == address(0)) revert InvalidAddress();
        if (sharesToBurn == 0) revert InvalidAmount();

        uint256 totalSupply = vdax.totalSupply();
        if (totalSupply == 0) revert ZeroTotalSupply();

        // Burn VDAX from caller
        vdax.burn(msg.sender, sharesToBurn);

        uint256 poolsLen = pools.length;
        address[] memory assets = new address[](poolsLen);
        uint256[] memory assetAmounts = new uint256[](poolsLen);

        for (uint256 i; i < poolsLen;) {
            Pool storage pool = pools[i];

            // Cache storage reads
            uint256 rVY = pool.reserveVY;
            uint256 rAsset = pool.reserveAsset;

            // Calculate pro-rata amounts
            uint256 vyFromPool = Math.mulDiv(rVY, sharesToBurn, totalSupply);
            uint256 assetFromPool = Math.mulDiv(rAsset, sharesToBurn, totalSupply);

            // Update reserves (single write per slot)
            pool.reserveVY = rVY - vyFromPool;
            pool.reserveAsset = rAsset - assetFromPool;

            vyOut += vyFromPool;
            assets[i] = pool.asset;
            assetAmounts[i] = assetFromPool;

            // Transfer asset directly to recipient (use cached address from memory)
            if (assetFromPool > 0) {
                IERC20(assets[i]).safeTransfer(recipient, assetFromPool);
            }

            unchecked { ++i; }
        }

        // Transfer VY to recipient
        if (vyOut > 0) {
            VY.safeTransfer(recipient, vyOut);
        }

        emit WithdrawRaw(recipient, sharesToBurn, vyOut, assets, assetAmounts);
    }

    /**
     * @inheritdoc IValinityDAX
     * @dev AMM V2 swap with constant product formula (no fee)
     *      VY → Asset: amountOut = (rAsset × amountIn) ÷ (rVY + amountIn)
     *      Asset → VY: amountOut = (rVY × amountIn) ÷ (rAsset + amountIn)
     */
    function swapExactIn(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    )
        external
        onlySwapWhitelisted
        whenSwapsNotPaused
        nonReentrant
        returns (uint256 amountOut)
    {
        if (poolId >= pools.length) revert InvalidPoolId();

        Pool storage pool = pools[poolId];

        if (recipient == address(0)) revert InvalidAddress();
        if (amountIn == 0) revert InvalidAmount();

        bool isVYInput = tokenIn == address(VY);
        if (!isVYInput && tokenIn != pool.asset) revert InvalidTokenIn();

        // Calculate output using constant product formula
        if (isVYInput) {
            // VY → Asset: amountOut = (rAsset × amountIn) ÷ (rVY + amountIn)
            amountOut = Math.mulDiv(
                pool.reserveAsset,
                amountIn,
                pool.reserveVY + amountIn
            );

            // Check slippage
            if (amountOut < minAmountOut) revert SlippageExceeded();

            // Check liquidity
            if (amountOut > pool.reserveAsset) revert InsufficientLiquidity();

            // Transfer tokenIn from caller
            VY.safeTransferFrom(msg.sender, address(this), amountIn);

            // Update reserves
            pool.reserveVY += amountIn;
            pool.reserveAsset -= amountOut;

            // Transfer tokenOut to recipient
            IERC20(pool.asset).safeTransfer(recipient, amountOut);
        } else {
            // Asset → VY: amountOut = (rVY × amountIn) ÷ (rAsset + amountIn)
            amountOut = Math.mulDiv(
                pool.reserveVY,
                amountIn,
                pool.reserveAsset + amountIn
            );

            // Check slippage
            if (amountOut < minAmountOut) revert SlippageExceeded();

            // Check liquidity
            if (amountOut > pool.reserveVY) revert InsufficientLiquidity();

            // Transfer tokenIn from caller
            IERC20(pool.asset).safeTransferFrom(
                msg.sender,
                address(this),
                amountIn
            );

            // Update reserves
            pool.reserveAsset += amountIn;
            pool.reserveVY -= amountOut;

            // Transfer tokenOut to recipient
            VY.safeTransfer(recipient, amountOut);
        }

        emit Swap(poolId, tokenIn, amountIn, amountOut, recipient);
    }

    /**
     * @inheritdoc IValinityDAX
     * @dev Add a new pool. Callable by ADMIN_ROLE or POOL_CREATOR_ROLE.
     *      Does NOT mint VDAX — existing VDAX holders automatically own the
     *      new pool pro-rata via the seeded reserves.
     *      POOL_CREATOR_ROLE is the scoped role granted to VARO for tier-5
     *      token launches; it cannot do anything else on this contract.
     */
    function addPool(
        address asset,
        uint256 vySeed,
        uint256 assetSeed
    )
        external
        whenDepositsNotPaused
        nonReentrant
        returns (uint256 poolId)
    {
        if (
            !hasRole(POOL_CREATOR_ROLE, msg.sender) &&
            !hasRole(ADMIN_ROLE, msg.sender)
        ) revert AccessControlUnauthorizedAccount(msg.sender, POOL_CREATOR_ROLE);

        if (asset == address(0)) revert InvalidAddress();
        if (vySeed == 0 || assetSeed == 0) revert InvalidAmount();
        if (hasPool[asset]) revert PoolAlreadyExists();

        // Transfer tokens from caller to contract
        VY.safeTransferFrom(msg.sender, address(this), vySeed);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assetSeed);

        // Create new pool
        poolId = pools.length;
        pools.push(
            Pool({
                asset: asset,
                reserveVY: vySeed,
                reserveAsset: assetSeed
            })
        );

        // Update mappings
        assetToPoolId[asset] = poolId;
        hasPool[asset] = true;

        emit PoolAdded(poolId, asset, vySeed, assetSeed);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IValinityDAX
     */
    function updateSwapWhitelist(
        address account,
        bool whitelisted
    ) external onlyRole(ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        swapWhitelist[account] = whitelisted;
        emit SwapWhitelistUpdated(account, whitelisted);
    }

    /**
     * @inheritdoc IValinityDAX
     */
    function updateLiquidityWhitelist(
        address account,
        bool whitelisted
    ) external onlyRole(ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        liquidityWhitelist[account] = whitelisted;
        emit LiquidityWhitelistUpdated(account, whitelisted);
    }

    /**
     * @inheritdoc IValinityDAX
     */
    function updatePauseStatus(
        bool _depositsPaused,
        bool _withdrawalsPaused,
        bool _swapsPaused
    ) external onlyRole(ADMIN_ROLE) {
        depositsPaused = _depositsPaused;
        withdrawalsPaused = _withdrawalsPaused;
        swapsPaused = _swapsPaused;
        emit PauseStatusUpdated(_depositsPaused, _withdrawalsPaused, _swapsPaused);
    }

    /**
     * @inheritdoc IValinityDAX
     * @dev WARNING: Can desync reserves if used on pool tokens. Use only for truly stuck tokens.
     */
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    /**
     * @inheritdoc IValinityDAX
     * @dev On basisPoints == 10000:
     *      - Assigns reserves directly from storage (no division) → guaranteed zero dust
     *      - Clears hasPool and assetToPoolId mappings for the removed asset
     *      - Compacts the pools array via swap-and-pop so getNumPools() is immediately correct
     *      - Remaps the moved pool's assetToPoolId to its new index
     *      StakingRouter safety: it only calls getNumPools(), depositVYOnly(), withdraw() —
     *      none of which store pool IDs — so compaction is fully transparent to it.
     */
    function adminExtractLiquidity(
        uint256 poolId,
        uint256 basisPoints,
        address recipient
    )
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        returns (uint256 vyOut, uint256 assetOut)
    {
        if (poolId >= pools.length) revert InvalidPoolId();
        if (basisPoints == 0 || basisPoints > 10000) revert InvalidBasisPoints();
        if (recipient == address(0)) revert InvalidAddress();

        Pool storage pool = pools[poolId];

        // Cache storage reads
        uint256 rVY    = pool.reserveVY;
        uint256 rAsset = pool.reserveAsset;
        address asset  = pool.asset;

        if (basisPoints == 10000) {
            // ── FULL EXTRACTION: use raw values to guarantee zero dust ──
            vyOut    = rVY;
            assetOut = rAsset;

            // Erase pool from mappings before compaction
            hasPool[asset]       = false;
            assetToPoolId[asset] = 0;

            // Swap-and-pop: move last pool into this slot (unless this IS the last slot)
            uint256 lastIndex = pools.length - 1;
            if (poolId != lastIndex) {
                Pool storage lastPool   = pools[lastIndex];
                address movedAsset      = lastPool.asset;
                pools[poolId]           = lastPool;
                assetToPoolId[movedAsset] = poolId;
            }
            pools.pop();

            emit PoolRemoved(poolId, asset, vyOut, assetOut);
        } else {
            // ── PARTIAL EXTRACTION: thin the pool proportionally ──
            vyOut    = Math.mulDiv(rVY,    basisPoints, 10000);
            assetOut = Math.mulDiv(rAsset, basisPoints, 10000);

            // mulDiv with basisPoints <= 10000 guarantees vyOut <= rVY and assetOut <= rAsset
            unchecked {
                pool.reserveVY    = rVY    - vyOut;
                pool.reserveAsset = rAsset - assetOut;
            }

            emit PoolThinned(poolId, asset, vyOut, assetOut, basisPoints);
        }

        // Transfer extracted tokens to recipient
        if (vyOut    > 0) VY.safeTransfer(recipient, vyOut);
        if (assetOut > 0) IERC20(asset).safeTransfer(recipient, assetOut);
    }

    /**
     * @inheritdoc IValinityDAX
     * @dev No ratio enforcement applied — MEV bot rebalances price discrepancies afterward.
     *      No VDAX is minted; existing VDAX holders automatically own more reserves.
     *      Admin must approve this contract for both VY and the asset before calling.
     */
    function adminInjectLiquidity(
        uint256 poolId,
        uint256 vyAmount,
        uint256 assetAmount
    )
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
    {
        if (poolId >= pools.length) revert InvalidPoolId();
        if (vyAmount == 0 && assetAmount == 0) revert InvalidAmount();

        Pool storage pool = pools[poolId];
        address asset     = pool.asset;

        // ── INTERACTIONS: pull tokens first ──
        if (vyAmount    > 0) VY.safeTransferFrom(msg.sender, address(this), vyAmount);
        if (assetAmount > 0) IERC20(asset).safeTransferFrom(msg.sender, address(this), assetAmount);

        // ── EFFECTS: update reserves after all transfers complete ──
        if (vyAmount    > 0) pool.reserveVY    += vyAmount;
        if (assetAmount > 0) pool.reserveAsset += assetAmount;

        emit LiquidityInjected(poolId, asset, vyAmount, assetAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UUPS UPGRADE
    // ═══════════════════════════════════════════════════════════════════════════

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    uint256[44] private __gap;
}
