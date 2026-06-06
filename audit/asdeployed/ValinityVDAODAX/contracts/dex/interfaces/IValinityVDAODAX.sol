// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

/**
 * @title IValinityVDAODAX
 * @notice Interface for the Valinity VDAO DAX — a private, VY-agnostic constant-product
 *         AMM for VDAO asset-leg pools (e.g. WBTC/VDAO) and VDAO/VDAO pools.
 * @dev Sibling of {IValinityDAX}. Unlike the main DAX (every pool is VY/asset, single
 *      basket LP token), this exchange pairs ARBITRARY tokens, mints NO LP tokens, and
 *      keeps liquidity permanently locked — pools are seeded once by VARO at VDAO launch
 *      and can only ever be drained via swaps.
 */
interface IValinityVDAODAX {
    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice A single constant-product pool pairing two arbitrary tokens.
     * @dev Tokens are stored canonically: `token0 < token1` (address order).
     *      `reserveN` is the contract's pool-attributed balance of `tokenN`.
     * @param token0 Lower-address token of the pair
     * @param token1 Higher-address token of the pair
     * @param reserve0 Reserve of token0
     * @param reserve1 Reserve of token1
     */
    struct Pool {
        address token0;
        address token1;
        uint256 reserve0;
        uint256 reserve1;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidAddress();
    error InvalidAmount();
    error InvalidPoolId();
    error IdenticalTokens();
    error PoolAlreadyExists();
    error NotWhitelisted();
    error LegNotListed(address token);
    error SwapsPaused();
    error PoolPaused();
    error PoolCreationPaused();
    error InsufficientLiquidity();
    error SlippageExceeded();
    error InvalidTokenIn();
    error PoolTokenRescueForbidden();

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a new pool is created and seeded.
     * @param poolId ID of the new pool (index in the pools array)
     * @param token0 Lower-address token of the pair
     * @param token1 Higher-address token of the pair
     * @param reserve0 Seeded reserve of token0 (amount actually received, net of any transfer fee)
     * @param reserve1 Seeded reserve of token1 (amount actually received, net of any transfer fee)
     */
    event PoolAdded(
        uint256 indexed poolId,
        address indexed token0,
        address indexed token1,
        uint256 reserve0,
        uint256 reserve1
    );

    /**
     * @notice Emitted on a swap.
     * @param poolId ID of the pool
     * @param tokenIn Address of the input token
     * @param amountIn Amount of input ACTUALLY received by the pool (net of input-side transfer fee)
     * @param amountOut Gross pool output; the recipient receives this minus the output token's own
     *                  transfer fee/burn (if any), which is borne by the recipient
     * @param recipient Address receiving the output token
     */
    event Swap(
        uint256 indexed poolId,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    event SwapWhitelistUpdated(address indexed account, bool whitelisted);
    event AssetAllowedUpdated(address indexed asset, bool allowed);
    event PauseStatusUpdated(bool poolCreationPaused, bool swapsPaused);
    event PoolSwapPausedUpdated(uint256 indexed poolId, bool paused);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event Donated(uint256 indexed poolId, address indexed token, address indexed from, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Number of pools.
    function getNumPools() external view returns (uint256 count);

    /// @notice Reserves of a pool by ID.
    function getPoolReserves(
        uint256 poolId
    )
        external
        view
        returns (address token0, address token1, uint256 reserve0, uint256 reserve1);

    /// @notice Resolve a pool by (unordered) token pair.
    function getPoolIdByPair(
        address tokenA,
        address tokenB
    ) external view returns (uint256 poolId, bool exists);

    /**
     * @notice Quote the gross output for a swap.
     * @dev Does NOT account for the input token's transfer fee (caller passes gross `amountIn`)
     *      nor the output token's transfer fee on the way to a recipient. View-only quote.
     */
    function getAmountOut(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 amountOut);

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Create and seed a new pool. Callable by POOL_CREATOR_ROLE (VARO) or ADMIN_ROLE.
     * @dev Each leg must be either an admin-allowed asset OR a token with a live VY pool in
     *      the main ValinityDAX (the on-chain VDAO listing rule). Pulls both seeds from the
     *      caller using balance-delta accounting (fee-on-transfer safe). Mints no LP token.
     * @param tokenA First token (any order)
     * @param tokenB Second token (any order)
     * @param amountA Seed amount of tokenA
     * @param amountB Seed amount of tokenB
     * @return poolId ID of the newly created pool
     */
    function addPool(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) external returns (uint256 poolId);

    /**
     * @notice Constant-product swap (no AMM fee). Swap-whitelisted callers only.
     * @param poolId ID of the pool
     * @param tokenIn Input token (must be one of the pool's two tokens)
     * @param amountIn Input amount (gross; pool credits the net received after any transfer fee)
     * @param minAmountOut Minimum gross pool output (slippage guard)
     * @param recipient Address receiving the output token
     * @return amountOut Gross pool output (recipient receives this minus the output token's transfer fee)
     */
    function swapExactIn(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    /**
     * @notice Permissionlessly donate one token into a pool, increasing that leg's reserve.
     * @dev Anyone may call (e.g. VARO routing VDAO fees into a VDAO/asset pool). One-way: it can
     *      only ADD to a reserve — never withdraw — so liquidity stays locked. `token` must be one
     *      of the pool's two tokens. Uses balance-delta accounting (fee-on-transfer safe). Shifts
     *      the pool price toward the donated side; a donor cannot profit from that skew unless they
     *      are swap-whitelisted.
     * @param poolId ID of the pool to donate to
     * @param token Token to donate (must be token0 or token1 of the pool)
     * @param amount Amount to donate (gross; the pool credits the net received after any transfer fee)
     */
    function donate(uint256 poolId, address token, uint256 amount) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function updateSwapWhitelist(address account, bool whitelisted) external;

    function updateAssetAllowed(address asset, bool allowed) external;

    function updatePauseStatus(bool _poolCreationPaused, bool _swapsPaused) external;

    /// @notice Quarantine a single pool's swaps (e.g. if its main-DAX VY anchor is later removed,
    ///         or a listed VDAO turns malicious). Does not touch reserves — liquidity stays locked.
    function setPoolSwapPaused(uint256 poolId, bool paused) external;

    /// @notice Rescue foreign tokens. Reverts for any token that is part of a pool (liquidity is locked).
    function rescueTokens(address token, address to, uint256 amount) external;
}

/**
 * @title IDAXListing
 * @notice Minimal view into the main ValinityDAX used to enforce the VDAO listing rule.
 * @dev `hasPool` is a public mapping getter on ValinityDAX (not in IValinityDAX), so it is
 *      declared here to avoid coupling to the full implementation.
 */
interface IDAXListing {
    /// @notice True if the main ValinityDAX has a VY/<asset> pool for `asset`.
    function hasPool(address asset) external view returns (bool);
}
