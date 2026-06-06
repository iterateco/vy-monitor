// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

/**
 * @title IValinityDAX
 * @notice Interface for the Valinity Decentralized Asset Exchange
 * @dev Defines all external functions, events, and errors for ValinityDAX contract
 */
interface IValinityDAX {
    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Represents a single liquidity pool in the DAX
     * @param asset Address of the asset token (e.g., WETH, WBTC, PAXG)
     * @param reserveVY Amount of VY tokens in the pool
     * @param reserveAsset Amount of asset tokens in the pool
     */
    struct Pool {
        address asset;
        uint256 reserveVY;
        uint256 reserveAsset;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidAddress();
    error InvalidAmount();
    error InvalidPoolId();
    error PoolAlreadyExists();
    error NotWhitelisted();
    error DepositsPaused();
    error WithdrawalsPaused();
    error SwapsPaused();
    error InsufficientLiquidity();
    error SlippageExceeded();
    error ZeroTotalSupply();
    error InvalidTokenIn();
    error AlreadyInitialized();
    error InvalidBasisPoints();

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a new pool is added
     * @param poolId ID of the new pool
     * @param asset Address of the asset token
     * @param vySeed Initial VY amount
     * @param assetSeed Initial asset amount
     */
    event PoolAdded(
        uint256 indexed poolId,
        address indexed asset,
        uint256 vySeed,
        uint256 assetSeed
    );

    /**
     * @notice Emitted when VY is deposited (VY-only deposit)
     * @param recipient Address receiving VDAX tokens
     * @param sharesMinted Amount of VDAX tokens minted
     * @param vyAmount Total VY deposited
     */
    event Deposit(
        address indexed recipient,
        uint256 sharesMinted,
        uint256 vyAmount
    );

    /**
     * @notice Emitted when VDAX is burned and liquidity withdrawn as VY
     * @param recipient Address receiving VY
     * @param sharesBurned Amount of VDAX tokens burned
     * @param vyOut Total VY withdrawn (includes converted assets)
     */
    event Withdraw(
        address indexed recipient,
        uint256 sharesBurned,
        uint256 vyOut
    );

    /**
     * @notice Emitted when admin withdraws raw assets (VY + assets) without conversion
     * @param recipient Address receiving the tokens
     * @param sharesBurned Amount of VDAX tokens burned
     * @param vyOut Total VY withdrawn
     * @param assets Array of asset addresses withdrawn
     * @param assetAmounts Array of asset amounts withdrawn
     */
    event WithdrawRaw(
        address indexed recipient,
        uint256 sharesBurned,
        uint256 vyOut,
        address[] assets,
        uint256[] assetAmounts
    );

    /**
     * @notice Emitted when a swap is executed in a pool
     * @param poolId ID of the pool
     * @param tokenIn Address of input token
     * @param amountIn Amount of input token
     * @param amountOut Amount of output token
     * @param recipient Address receiving output token
     */
    event Swap(
        uint256 indexed poolId,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    /**
     * @notice Emitted when swap whitelist is updated
     * @param account Address whose whitelist status changed
     * @param whitelisted New whitelist status
     */
    event SwapWhitelistUpdated(address indexed account, bool whitelisted);

    /**
     * @notice Emitted when liquidity whitelist is updated
     * @param account Address whose whitelist status changed
     * @param whitelisted New whitelist status
     */
    event LiquidityWhitelistUpdated(address indexed account, bool whitelisted);

    /**
     * @notice Emitted when pause status is updated
     * @param depositsPaused New deposits pause status
     * @param withdrawalsPaused New withdrawals pause status
     * @param swapsPaused New swaps pause status
     */
    event PauseStatusUpdated(
        bool depositsPaused,
        bool withdrawalsPaused,
        bool swapsPaused
    );

    /**
     * @notice Emitted when tokens are rescued by admin
     * @param token Address of the rescued token
     * @param to Address receiving the tokens
     * @param amount Amount rescued
     */
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    /**
     * @notice Emitted when a pool is fully removed via 100% extraction
     * @param poolId ID of the removed pool (slot may now hold a different pool after compaction)
     * @param asset Address of the removed asset
     * @param vyOut Total VY returned to admin
     * @param assetOut Total asset returned to admin
     */
    event PoolRemoved(
        uint256 indexed poolId,
        address indexed asset,
        uint256 vyOut,
        uint256 assetOut
    );

    /**
     * @notice Emitted when a pool is partially thinned
     * @param poolId ID of the thinned pool
     * @param asset Address of the asset
     * @param vyOut VY returned to admin
     * @param assetOut Asset returned to admin
     * @param basisPoints Percentage extracted (1–9999)
     */
    event PoolThinned(
        uint256 indexed poolId,
        address indexed asset,
        uint256 vyOut,
        uint256 assetOut,
        uint256 basisPoints
    );

    /**
     * @notice Emitted when admin injects liquidity into a specific pool
     * @param poolId ID of the pool
     * @param asset Address of the asset
     * @param vyAmount VY injected
     * @param assetAmount Asset injected
     */
    event LiquidityInjected(
        uint256 indexed poolId,
        address indexed asset,
        uint256 vyAmount,
        uint256 assetAmount
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the number of pools
     * @return count Number of pools
     */
    function getNumPools() external view returns (uint256 count);

    /**
     * @notice Get pool reserves by pool ID
     * @param poolId ID of the pool
     * @return asset Address of the asset token
     * @return reserveVY Amount of VY in the pool
     * @return reserveAsset Amount of asset in the pool
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
        );

    /**
     * @notice Get total VY reserves across all pools
     * @return total Total VY in all pools
     */
    function getTotalVYReserves() external view returns (uint256 total);

    /**
     * @notice Get user's percentage share of the total VDAX supply
     * @param user Address of the user
     * @return sharePercentage User's share as a percentage (with 18 decimals: 1e18 = 100%)
     */
    function getUserShare(
        address user
    ) external view returns (uint256 sharePercentage);

    /**
     * @notice Preview withdrawal - simulates VY output including asset conversion
     * @param sharesToBurn Amount of VDAX tokens to burn
     * @return vyOut Total VY that would be withdrawn (includes converted assets)
     */
    function previewWithdraw(
        uint256 sharesToBurn
    ) external view returns (uint256 vyOut);

    /**
     * @notice Preview VDAX shares minted for a VY-only deposit
     * @dev Mirrors the math of `depositVYOnly` (sharesMinted formula).
     *      View-only: does not mutate state.
     * @param vyAmount Amount of VY that would be deposited
     * @return vdaxOut Amount of VDAX shares that would be minted
     */
    function previewDepositVYOnly(
        uint256 vyAmount
    ) external view returns (uint256 vdaxOut);

    // ═══════════════════════════════════════════════════════════════════════════
    // LIQUIDITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize the first pool (admin only, when VDAX supply = 0)
     * @param asset Address of the asset token
     * @param vySeed Initial VY amount
     * @param assetSeed Initial asset amount
     * @param recipient Address to receive initial VDAX tokens
     * @return sharesMinted Amount of VDAX tokens minted
     */
    function initializeFirstPool(
        address asset,
        uint256 vySeed,
        uint256 assetSeed,
        address recipient
    ) external returns (uint256 sharesMinted);

    /**
     * @notice Add a new pool (admin only, does NOT mint VDAX)
     * @param asset Address of the asset token
     * @param vySeed Initial VY amount
     * @param assetSeed Initial asset amount
     * @return poolId ID of the newly created pool
     */
    function addPool(
        address asset,
        uint256 vySeed,
        uint256 assetSeed
    ) external returns (uint256 poolId);

    /**
     * @notice Deposit VY-only and receive VDAX (VY distributed proportionally to each pool's existing VY reserves)
     * @param vyAmount Amount of VY to deposit
     * @param recipient Address to receive VDAX tokens
     * @return sharesMinted Amount of VDAX tokens minted
     */
    function depositVYOnly(
        uint256 vyAmount,
        address recipient
    ) external returns (uint256 sharesMinted);

    /**
     * @notice Withdraw liquidity and receive 100% VY
     * @dev Burns VDAX, withdraws pro-rata from all pools, converts assets to VY
     * @param sharesToBurn Amount of VDAX tokens to burn
     * @param recipient Address to receive VY
     * @return vyOut Total VY withdrawn (includes converted assets)
     */
    function withdraw(
        uint256 sharesToBurn,
        address recipient
    ) external returns (uint256 vyOut);

    // ═══════════════════════════════════════════════════════════════════════════
    // SWAP FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Swap tokens in a specific pool (AMM V2 style)
     * @param poolId ID of the pool to swap in
     * @param tokenIn Address of input token (VY or asset)
     * @param amountIn Amount of input token
     * @param minAmountOut Minimum amount of output token (slippage protection)
     * @param recipient Address to receive output token
     * @return amountOut Amount of output token received
     */
    function swapExactIn(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update swap whitelist for an account
     * @param account Address to update
     * @param whitelisted New whitelist status
     */
    function updateSwapWhitelist(address account, bool whitelisted) external;

    /**
     * @notice Update liquidity whitelist for an account
     * @param account Address to update
     * @param whitelisted New whitelist status
     */
    function updateLiquidityWhitelist(
        address account,
        bool whitelisted
    ) external;

    /**
     * @notice Update pause status for operations
     * @param _depositsPaused New deposits pause status
     * @param _withdrawalsPaused New withdrawals pause status
     * @param _swapsPaused New swaps pause status
     */
    function updatePauseStatus(
        bool _depositsPaused,
        bool _withdrawalsPaused,
        bool _swapsPaused
    ) external;

    /**
     * @notice Rescue tokens sent to contract by mistake (admin only)
     * @param token Address of the token to rescue (use address(0) for native tokens)
     * @param to Address to send rescued tokens to
     * @param amount Amount of tokens to rescue
     */
    function rescueTokens(address token, address to, uint256 amount) external;

    /**
     * @notice Extract liquidity from a specific pool by basis points
     * @dev At 10000 bps (100%), the pool is fully deleted and compacted out of the array.
     *      At < 10000 bps, the pool is thinned proportionally and remains active.
     * @param poolId ID of the pool to extract from
     * @param basisPoints Percentage to extract: 1–10000 (10000 = 100%)
     * @param recipient Address to receive extracted VY and asset tokens
     * @return vyOut Amount of VY sent to recipient
     * @return assetOut Amount of asset sent to recipient
     */
    function adminExtractLiquidity(
        uint256 poolId,
        uint256 basisPoints,
        address recipient
    ) external returns (uint256 vyOut, uint256 assetOut);

    /**
     * @notice Inject liquidity into a specific pool (admin only)
     * @dev No ratio enforcement — MEV bot rebalances afterward.
     *      No VDAX is minted; existing holders automatically own more reserves.
     * @param poolId ID of the pool to inject into
     * @param vyAmount Amount of VY to inject (can be 0)
     * @param assetAmount Amount of asset to inject (can be 0)
     */
    function adminInjectLiquidity(
        uint256 poolId,
        uint256 vyAmount,
        uint256 assetAmount
    ) external;
}
