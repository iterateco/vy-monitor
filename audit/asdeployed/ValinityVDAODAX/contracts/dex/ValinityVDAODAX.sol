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
import {IValinityVDAODAX, IDAXListing} from "./interfaces/IValinityVDAODAX.sol";

/**
 * @title ValinityVDAODAX - Valinity VDAO Decentralized Asset Exchange
 * @notice Private, VY-agnostic constant-product AMM for VDAO liquidity. Sibling of
 *         {ValinityDAX} (the main VY-only basket DEX), but pools pair ARBITRARY tokens.
 *
 * @dev Driven by VARO at Tier-4 VDAO launch, this exchange holds:
 *      - Asset-leg pools  — e.g. WBTC/VDAO_X, seeded with the asset half of the launch deposit.
 *      - VDAO/VDAO pools   — e.g. VDAO_Y/VDAO_X, enabling direct DAO-to-DAO trading.
 *      The main ValinityDAX simultaneously gets the VY/VDAO pool; it stays VY-hardcoded.
 *
 * Design decisions (locked):
 *  - NO LP TOKENS. Liquidity is permanently locked: pools are seeded once via {addPool}
 *    and can only ever shrink/move via swaps. There is no deposit/withdraw/remove path and
 *    no admin extraction. {rescueTokens} cannot touch pool tokens. This also makes the
 *    first-deposit inflation attack impossible (there are no shares to inflate).
 *
 *  - FEE-ON-TRANSFER NATIVE. Every VDAO burns 0.7% on transfers between non-exempt parties
 *    (see ValinityVDAO._update). This contract is intentionally NOT fee-exempt, so the burn
 *    fires on every VDAO swap leg — deflationary by design. Consequently the contract NEVER
 *    trusts requested amounts: it books reserves against actual balance deltas (Uniswap-V2
 *    style). VARO seeds are fee-free because VARO itself is exempt on each VDAO.
 *
 *  - ON-CHAIN LISTING RULE. A VDAO may only be paired here if it already has a VY pool in the
 *    main ValinityDAX (`mainDax.hasPool(vdao) == true`). Non-VDAO asset legs (WBTC/ETH/PAXG/…)
 *    are gated by an admin-managed `assetAllowed` whitelist instead. Every {addPool} leg must
 *    satisfy one of the two — see {_requireListed}.
 *
 *  - LEAST PRIVILEGE. VARO holds only POOL_CREATOR_ROLE (scoped to {addPool}) plus a
 *    swap-whitelist entry — never ADMIN_ROLE.
 */
contract ValinityVDAODAX is
    IValinityVDAODAX,
    UUPSUpgradeable,
    AccessControl,
    ReentrancyGuardTransient,
    Initializable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Role for administrative functions.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Scoped role gating ONLY {addPool}. Granted to VARO so it can create
    ///         VDAO pools at Tier-4 launches WITHOUT any other power (no pause/rescue/
    ///         inject/upgrade). Mirrors the POOL_CREATOR_ROLE on the main ValinityDAX.
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES - REFERENCES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Main ValinityDAX, consulted for the VDAO listing rule via {IDAXListing.hasPool}.
    address public mainDax;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES - POOLS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice All pools. Pool ID = index in this array. Pools are never removed.
    Pool[] public pools;

    /// @notice Canonical-pair key => pool ID (O(1) lookup). Check {hasPair} first (ID 0 is valid).
    mapping(bytes32 => uint256) public pairToPoolId;

    /// @notice Canonical-pair key => whether a pool exists for it.
    mapping(bytes32 => bool) public hasPair;

    /// @notice Whether a token is part of any pool. Once true, never false (pools are permanent).
    /// @dev Guards {rescueTokens} so pool reserves can never be pulled — liquidity stays locked.
    mapping(address => bool) public isPoolToken;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES - WHITELISTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Whitelist for swap operations (e.g. MEV bot, VARO, VEO).
    mapping(address => bool) public swapWhitelist;

    /// @notice Non-VDAO asset legs allowed to form pools (e.g. WBTC, ETH, PAXG, USDC).
    /// @dev VDAO legs are gated by the main-DAX listing rule instead; see {_requireListed}.
    mapping(address => bool) public assetAllowed;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES - PAUSE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Whether new pool creation is paused.
    bool public poolCreationPaused;

    /// @notice Whether swaps are paused globally.
    bool public swapsPaused;

    /// @notice Per-pool swap quarantine. Lets the admin halt one pool without pausing the whole
    ///         exchange — e.g. if a token's main-DAX VY anchor is later removed (the listing rule
    ///         is a creation-time precondition only), or a listed VDAO turns malicious post-launch.
    ///         Does NOT touch reserves; liquidity remains permanently locked.
    mapping(uint256 => bool) public poolSwapPaused;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR / INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the ValinityVDAODAX contract.
     * @dev `adminAddress` should be the governance/VGC multisig from minute one
     *      (no deployer-EOA admin window). POOL_CREATOR_ROLE + swap whitelist for VARO
     *      are granted by the admin post-deploy. There is intentionally no setter for
     *      {mainDax} — both contracts are UUPS, so the reference is fixed at init.
     * @param mainDaxAddress Address of the main ValinityDAX (for the listing rule)
     * @param adminAddress Address that will hold DEFAULT_ADMIN_ROLE and ADMIN_ROLE
     */
    function initialize(address mainDaxAddress, address adminAddress) public initializer {
        if (mainDaxAddress == address(0) || adminAddress == address(0)) {
            revert InvalidAddress();
        }

        mainDax = mainDaxAddress;

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Restricts to swap-whitelisted addresses.
    modifier onlySwapWhitelisted() {
        if (!swapWhitelist[msg.sender]) revert NotWhitelisted();
        _;
    }

    /// @notice Reverts when pool creation is paused.
    modifier whenPoolCreationNotPaused() {
        if (poolCreationPaused) revert PoolCreationPaused();
        _;
    }

    /// @notice Reverts when swaps are paused.
    modifier whenSwapsNotPaused() {
        if (swapsPaused) revert SwapsPaused();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IValinityVDAODAX
    function getNumPools() external view returns (uint256) {
        return pools.length;
    }

    /// @inheritdoc IValinityVDAODAX
    function getPoolReserves(
        uint256 poolId
    )
        external
        view
        returns (address token0, address token1, uint256 reserve0, uint256 reserve1)
    {
        if (poolId >= pools.length) revert InvalidPoolId();
        Pool memory pool = pools[poolId];
        return (pool.token0, pool.token1, pool.reserve0, pool.reserve1);
    }

    /// @inheritdoc IValinityVDAODAX
    function getPoolIdByPair(
        address tokenA,
        address tokenB
    ) external view returns (uint256 poolId, bool exists) {
        (address token0, address token1) = _sort(tokenA, tokenB);
        bytes32 key = _pairKey(token0, token1);
        exists = hasPair[key];
        poolId = pairToPoolId[key];
    }

    /// @inheritdoc IValinityVDAODAX
    function getAmountOut(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        if (poolId >= pools.length) revert InvalidPoolId();
        if (amountIn == 0) return 0;

        Pool memory pool = pools[poolId];
        (uint256 reserveIn, uint256 reserveOut) = _reservesFor(pool, tokenIn);

        // Constant product, no AMM fee: out = reserveOut * amountIn / (reserveIn + amountIn)
        amountOut = Math.mulDiv(reserveOut, amountIn, reserveIn + amountIn);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE - POOL CREATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IValinityVDAODAX
    function addPool(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    )
        external
        whenPoolCreationNotPaused
        nonReentrant
        returns (uint256 poolId)
    {
        if (
            !hasRole(POOL_CREATOR_ROLE, msg.sender) &&
            !hasRole(ADMIN_ROLE, msg.sender)
        ) revert AccessControlUnauthorizedAccount(msg.sender, POOL_CREATOR_ROLE);

        if (tokenA == address(0) || tokenB == address(0)) revert InvalidAddress();
        if (tokenA == tokenB) revert IdenticalTokens();
        if (amountA == 0 || amountB == 0) revert InvalidAmount();

        // Listing rule: each leg must be an allowed asset OR a main-DAX-listed (VY-anchored) token.
        _requireListed(tokenA);
        _requireListed(tokenB);

        // Canonical ordering (token0 < token1), carrying each token's seed amount with it.
        (address token0, address token1, uint256 seed0, uint256 seed1) = tokenA < tokenB
            ? (tokenA, tokenB, amountA, amountB)
            : (tokenB, tokenA, amountB, amountA);

        bytes32 key = _pairKey(token0, token1);
        if (hasPair[key]) revert PoolAlreadyExists();

        // Pull seeds with balance-delta accounting (fee-on-transfer safe). VARO is fee-exempt
        // on each VDAO, so in practice received == requested for VARO-driven launches.
        uint256 reserve0 = _pullToken(token0, seed0);
        uint256 reserve1 = _pullToken(token1, seed1);
        if (reserve0 == 0 || reserve1 == 0) revert InvalidAmount();

        poolId = pools.length;
        pools.push(Pool({token0: token0, token1: token1, reserve0: reserve0, reserve1: reserve1}));

        pairToPoolId[key] = poolId;
        hasPair[key] = true;
        isPoolToken[token0] = true;
        isPoolToken[token1] = true;

        emit PoolAdded(poolId, token0, token1, reserve0, reserve1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE - SWAP
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IValinityVDAODAX
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
        if (poolSwapPaused[poolId]) revert PoolPaused();
        if (recipient == address(0)) revert InvalidAddress();
        if (amountIn == 0) revert InvalidAmount();

        Pool storage pool = pools[poolId];
        address token0 = pool.token0;
        address token1 = pool.token1;

        bool zeroForOne;
        if (tokenIn == token0) zeroForOne = true;
        else if (tokenIn == token1) zeroForOne = false;
        else revert InvalidTokenIn();

        (uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (pool.reserve0, pool.reserve1)
            : (pool.reserve1, pool.reserve0);
        address tokenOut = zeroForOne ? token1 : token0;

        // Pull input first, measuring the amount ACTUALLY received (net of any input-side
        // transfer fee). reserves were read above, so the constant-product math below uses
        // pre-swap reserves + the true input — Uniswap-V2-style, fee-on-transfer safe.
        uint256 actualIn = _pullToken(tokenIn, amountIn);
        if (actualIn == 0) revert InvalidAmount();

        // out = reserveOut * actualIn / (reserveIn + actualIn)   (no AMM fee).
        // reserveIn is always > 0 (seeded > 0, only grows on the input leg), so out < reserveOut
        // is structurally guaranteed — no upper-bound guard is needed; only reject rounding-to-zero.
        amountOut = Math.mulDiv(reserveOut, actualIn, reserveIn + actualIn);
        if (amountOut == 0) revert InsufficientLiquidity();
        if (amountOut < minAmountOut) revert SlippageExceeded();

        // Effects: keep reserves equal to the contract's pool-attributed balances.
        // Input leg grows by actualIn; output leg drops by the FULL amountOut that leaves the
        // contract. The recipient receives amountOut minus the output token's own transfer
        // burn (if any) — that burn is borne by the recipient, not the pool, so the pool's
        // constant-product invariant is preserved.
        if (zeroForOne) {
            pool.reserve0 = reserveIn + actualIn;
            pool.reserve1 = reserveOut - amountOut;
        } else {
            pool.reserve1 = reserveIn + actualIn;
            pool.reserve0 = reserveOut - amountOut;
        }

        // Interaction: send output.
        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        emit Swap(poolId, tokenIn, actualIn, amountOut, recipient);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CORE - DONATE
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IValinityVDAODAX
     * @dev Permissionless and one-way: it can only ADD to a single reserve, never withdraw, so
     *      the locked-liquidity guarantee holds. Pricing reads stored reserves, so this shifts
     *      the pool price toward the donated side; a donor cannot profit from that skew unless
     *      swap-whitelisted (only the MEV bot is, and it just arbitrages it back to market).
     *      Balance-delta accounting books the net received after any transfer fee.
     *      Typical use: VARO routing accrued VDAO fees into a VDAO/asset pool.
     */
    function donate(
        uint256 poolId,
        address token,
        uint256 amount
    ) external nonReentrant {
        if (poolId >= pools.length) revert InvalidPoolId();
        if (amount == 0) revert InvalidAmount();

        Pool storage pool = pools[poolId];

        uint256 received;
        if (token == pool.token0) {
            received = _pullToken(token, amount);
            pool.reserve0 += received;
        } else if (token == pool.token1) {
            received = _pullToken(token, amount);
            pool.reserve1 += received;
        } else {
            revert InvalidTokenIn();
        }
        if (received == 0) revert InvalidAmount();

        emit Donated(poolId, token, msg.sender, received);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IValinityVDAODAX
    function updateSwapWhitelist(
        address account,
        bool whitelisted
    ) external onlyRole(ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        swapWhitelist[account] = whitelisted;
        emit SwapWhitelistUpdated(account, whitelisted);
    }

    /// @inheritdoc IValinityVDAODAX
    function updateAssetAllowed(
        address asset,
        bool allowed
    ) external onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) revert InvalidAddress();
        assetAllowed[asset] = allowed;
        emit AssetAllowedUpdated(asset, allowed);
    }

    /// @inheritdoc IValinityVDAODAX
    function updatePauseStatus(
        bool _poolCreationPaused,
        bool _swapsPaused
    ) external onlyRole(ADMIN_ROLE) {
        poolCreationPaused = _poolCreationPaused;
        swapsPaused = _swapsPaused;
        emit PauseStatusUpdated(_poolCreationPaused, _swapsPaused);
    }

    /// @inheritdoc IValinityVDAODAX
    function setPoolSwapPaused(
        uint256 poolId,
        bool paused
    ) external onlyRole(ADMIN_ROLE) {
        if (poolId >= pools.length) revert InvalidPoolId();
        poolSwapPaused[poolId] = paused;
        emit PoolSwapPausedUpdated(poolId, paused);
    }

    /**
     * @inheritdoc IValinityVDAODAX
     * @dev Reverts for any pool token: liquidity is permanently locked and can never be
     *      pulled by the admin. Only foreign tokens accidentally sent here are recoverable.
     */
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (isPoolToken[token]) revert PoolTokenRescueForbidden();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Pull `amount` of `token` from msg.sender and return the amount ACTUALLY received.
     * @dev Balance-delta accounting makes reserve bookkeeping correct for fee-on-transfer
     *      tokens (every VDAO burns 0.7% between non-exempt parties).
     */
    function _pullToken(address token, uint256 amount) internal returns (uint256 received) {
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - balBefore;
    }

    /**
     * @notice Enforce the VDAO listing rule for a single pool leg.
     * @dev Allowed if it is an admin-whitelisted asset (WBTC/ETH/PAXG/USDC/…) OR it has a live
     *      VY pool in the main ValinityDAX (every launched VDAO does, created at the same instant).
     */
    function _requireListed(address token) internal view {
        if (assetAllowed[token]) return;
        if (IDAXListing(mainDax).hasPool(token)) return;
        revert LegNotListed(token);
    }

    /// @notice Map `tokenIn` to (reserveIn, reserveOut) for a pool, reverting if it isn't a leg.
    function _reservesFor(
        Pool memory pool,
        address tokenIn
    ) internal pure returns (uint256 reserveIn, uint256 reserveOut) {
        if (tokenIn == pool.token0) return (pool.reserve0, pool.reserve1);
        if (tokenIn == pool.token1) return (pool.reserve1, pool.reserve0);
        revert InvalidTokenIn();
    }

    /// @notice Canonical address sort.
    function _sort(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    /// @notice Canonical pair key. Assumes `token0 < token1`.
    function _pairKey(address token0, address token1) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token0, token1));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UUPS UPGRADE
    // ═══════════════════════════════════════════════════════════════════════════

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    uint256[43] private __gap;
}
