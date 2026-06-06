// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ValinityToken} from "../token/ValinityToken.sol";
import {ValinityReserveTreasury} from "../treasury/ValinityReserveTreasury.sol";

/**
 * @notice Interface for ValinityAcquisitionOfficer price queries
 */
interface IValinityAcquisitionOfficer {
    function getAssetTwapPrice(address asset) external view returns (uint256);
}

/**
 * @title ValinityCapOfficer
 * @notice Manages collateral caps for assets, asset registry, and provides system metrics
 * @dev Combines former AssetRegistry functionality with cap management.
 *      Also functions as the "Accounting Officer" by exposing view functions for TVL, LTV, etc.
 */
contract ValinityCapOfficer is
    UUPSUpgradeable,
    AccessControl,
    ReentrancyGuardTransient,
    Initializable
{
    /// @notice Configuration for each supported asset
    struct AssetConfig {
        bool acquisitionPaused;
    }

    /// @notice Metrics for a single asset
    struct AssetMetrics {
        uint256 totalReserve; // Balance in VRT
        uint256 collateralCap; // Current cap
        uint256 ltvRatio; // Current LTV (reserve/cap) scaled by 1e18
        uint256 ltvF; // LTV-F in USD (reserve USD value / cap) scaled by 1e18
        uint256 utilized; // VY currently collateralized
        uint256 available; // Cap available for collateralization
    }

    /// @notice Global system metrics
    struct SystemMetrics {
        uint256 totalValueLocked; // TVL total (sum of all reserves)
        uint256 totalVYCirculating; // VY in circulation
        uint256 totalVYCollateralized; // VY used as collateral
        uint256 floorPrice; // TVL / Circulating (scaled by 1e18)
    }

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER_ROLE");

    uint8 internal constant DEFAULT_DECIMALS = 18;
    uint256 internal constant WAD = 1e18;

    // ═══════════════════════════════════════════════════════════════════════════
    // IMMUTABLE CONTRACT REFERENCES (replaces Registrar)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice ValinityToken contract reference
    ValinityToken public vyToken;
    /// @notice ValinityReserveTreasury contract reference
    ValinityReserveTreasury public vrt;
    /// @notice ValinityYieldTreasury address
    address public vyt;
    /// @notice ValinityAcquisitionOfficer for price queries
    IValinityAcquisitionOfficer public vao;

    // ═══════════════════════════════════════════════════════════════════════════
    // ASSET REGISTRY STATE (merged from ValinityAssetRegistry)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice List of supported asset addresses
    address[] internal _assets;
    /// @notice Asset configurations (paused, etc.)
    mapping(address => AssetConfig) internal _assetConfigs;
    /// @notice Whether an asset is supported
    mapping(address => bool) internal _supported;

    // ═══════════════════════════════════════════════════════════════════════════
    // CAP MANAGEMENT STATE
    // ═══════════════════════════════════════════════════════════════════════════

    mapping(address => uint256) internal _caps;
    mapping(address => uint256) internal _utilizedCaps;

    /// @notice Absolute floor (hard backstop). Effective floor is
    ///         max(assetCapFloor, maxCap / capSpreadDivisor).
    uint256 public assetCapFloor;

    /// @notice Divisor used to compute the dynamic component of the floor:
    ///         dynamicFloor = maxCap / capSpreadDivisor.
    ///         Set to 0 to disable the dynamic component (absolute floor only).
    /// @dev Appended in V2 upgrade. Initialized to 2 via migrateToDynamicFloor().
    uint256 public capSpreadDivisor;

    /// @dev Reserved storage for future upgrades (V2+).
    uint256[48] private __gapV2;

    error InvalidAddress();
    error InvalidAsset();
    error UnsupportedAsset();
    error ZeroAmount();
    error CapUnderflow();
    error CapOverflow();
    error InvalidFloor();
    error NoSupportedAssets();
    error NoValidAssetFound();
    error AssetAlreadySupported();
    error AssetNotSupported();
    error InvalidERC20Contract();

    event CapUpdated(address indexed asset, uint256 oldCap, uint256 newCap);
    event AssetCapFloorUpdated(uint256 value);
    event CapSpreadDivisorUpdated(uint256 newDivisor);
    event HighestLTVCapIncreased(
        address indexed asset,
        uint256 amount,
        uint256 newCap
    );
    event FeesAppliedToLowestLTV(
        address indexed asset,
        uint256 reduction,
        uint256 newCap
    );
    event CapUtilizationUpdated(
        address indexed asset,
        uint256 oldUtilized,
        uint256 newUtilized
    );
    event AssetConfigSet(address indexed asset, AssetConfig config);
    event AssetAdded(address indexed asset, AssetConfig config);
    event AssetRemoved(address indexed asset);
    event UnprocessedFees(uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vyTokenAddress,
        address vrtAddress,
        address vytAddress,
        address adminAddress
    ) public initializer {
        if (vyTokenAddress == address(0)) revert InvalidAddress();
        if (vrtAddress == address(0)) revert InvalidAddress();
        if (vytAddress == address(0)) revert InvalidAddress();
        if (adminAddress == address(0)) revert InvalidAddress();

        vyToken = ValinityToken(vyTokenAddress);
        vrt = ValinityReserveTreasury(vrtAddress);
        vyt = vytAddress;

        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE, adminAddress);
        _setRoleAdmin(OFFICER_ROLE, ADMIN_ROLE);

        assetCapFloor = 10_000 * 10 ** 18;
    }

    /**
     * @notice Set the ValinityAcquisitionOfficer reference for price queries
     * @param vaoAddress Address of ValinityAcquisitionOfficer
     */
    function setVAO(address vaoAddress) external onlyRole(ADMIN_ROLE) {
        if (vaoAddress == address(0)) revert InvalidAddress();
        vao = IValinityAcquisitionOfficer(vaoAddress);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ASSET REGISTRY FUNCTIONS (merged from ValinityAssetRegistry)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get all supported asset addresses
     * @return Array of supported asset addresses
     */
    function getAssets() external view returns (address[] memory) {
        return _assets;
    }

    /**
     * @notice Check if an asset is supported
     * @param asset The asset address to check
     * @return Whether the asset is supported
     */
    function isSupported(address asset) external view returns (bool) {
        return _supported[asset];
    }

    /**
     * @notice Get configuration for an asset
     * @param asset The asset address
     * @return config The asset configuration
     */
    function getAssetConfig(
        address asset
    ) external view returns (AssetConfig memory) {
        return _assetConfigs[asset];
    }

    /**
     * @notice Set configuration for an asset
     * @param asset The asset address
     * @param config The new configuration
     */
    function setAssetConfig(
        address asset,
        AssetConfig calldata config
    ) external onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) revert InvalidAsset();
        if (!_supported[asset]) revert AssetNotSupported();

        _assetConfigs[asset] = config;
        emit AssetConfigSet(asset, config);
    }

    /**
     * @notice Add a new supported asset
     * @param asset The asset address to add
     * @param config Initial configuration for the asset
     */
    function addAsset(
        address asset,
        AssetConfig calldata config
    ) external onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) revert InvalidAsset();
        if (_supported[asset]) revert AssetAlreadySupported();

        // Make sure asset address is ERC20 and not externally owned
        if (asset.code.length == 0) revert InvalidERC20Contract();
        try IERC20(asset).totalSupply() returns (uint256) {} catch {
            revert InvalidERC20Contract();
        }
        _assets.push(asset);
        _assetConfigs[asset] = config;
        _supported[asset] = true;

        emit AssetAdded(asset, config);
    }

    /**
     * @notice Remove a supported asset
     * @param asset The asset address to remove
     */
    function removeAsset(address asset) external onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) revert InvalidAsset();
        if (!_supported[asset]) revert AssetNotSupported();

        uint256 length = _assets.length;
        for (uint256 i = 0; i < length;) {
            if (_assets[i] == asset) {
                _assets[i] = _assets[length - 1];
                _assets.pop();
                break;
            }
            unchecked { ++i; }
        }

        delete _assetConfigs[asset];
        delete _caps[asset];
        delete _utilizedCaps[asset];
        _supported[asset] = false;

        emit AssetRemoved(asset);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CAP MANAGEMENT FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function getAssetCap(address asset) public view returns (uint256) {
        return _caps[asset];
    }

    function setAssetCap(
        address asset,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) {
            revert InvalidAsset();
        }
        if (!_supported[asset]) {
            revert UnsupportedAsset();
        }

        uint256 oldCap = _caps[asset];
        _caps[asset] = amount;

        emit CapUpdated(asset, oldCap, amount);
    }

    /**
     * @notice Set the absolute (hard backstop) cap floor.
     * @dev The effective floor is max(assetCapFloor, maxCap / capSpreadDivisor).
     */
    function setAssetCapFloor(uint256 newFloor) external onlyRole(ADMIN_ROLE) {
        if (newFloor == assetCapFloor) return;
        if (newFloor == 0) {
            revert InvalidFloor();
        }
        assetCapFloor = newFloor;
        emit AssetCapFloorUpdated(newFloor);
    }

    /**
     * @notice Set the divisor for the dynamic component of the cap floor.
     * @dev dynamicFloor = maxCap / capSpreadDivisor. 0 disables the dynamic component.
     *      effectiveFloor = max(assetCapFloor, dynamicFloor).
     * @param newDivisor New divisor (e.g. 2 = floor is half of the largest cap).
     */
    function setCapSpreadDivisor(uint256 newDivisor) external onlyRole(ADMIN_ROLE) {
        if (newDivisor == capSpreadDivisor) return;
        capSpreadDivisor = newDivisor;
        emit CapSpreadDivisorUpdated(newDivisor);
    }

    /**
     * @notice One-shot migration to seed capSpreadDivisor on V2 upgrade.
     * @dev Called via upgradeToAndCall during the V2 upgrade. Idempotent via reinitializer(2).
     *      Admin-only as defense-in-depth (reinitializer already prevents replay).
     */
    function migrateToDynamicFloor() external onlyRole(ADMIN_ROLE) reinitializer(2) {
        capSpreadDivisor = 2;
        emit CapSpreadDivisorUpdated(2);
    }

    /**
     * @notice Compute the effective per-asset cap floor.
     * @dev effectiveFloor = max(assetCapFloor, maxCap / capSpreadDivisor).
     *      Iterates supported assets; with the current basket size this is cheap.
     */
    function _effectiveFloor() internal view returns (uint256) {
        uint256 maxCap;
        uint256 length = _assets.length;
        for (uint256 i = 0; i < length;) {
            uint256 c = _caps[_assets[i]];
            if (c > maxCap) maxCap = c;
            unchecked { ++i; }
        }
        uint256 divisor = capSpreadDivisor;
        uint256 dyn = divisor == 0 ? 0 : maxCap / divisor;
        return dyn > assetCapFloor ? dyn : assetCapFloor;
    }

    /**
     * @notice Public view of the dynamic floor enforced by decreaseAssetCap.
     * @return floor The current effective floor:
     *         max(assetCapFloor, maxCap / capSpreadDivisor).
     */
    function effectiveFloor() external view returns (uint256 floor) {
        return _effectiveFloor();
    }

    function increaseAssetCap(
        address asset,
        uint256 amount
    ) external onlyRole(OFFICER_ROLE) {
        if (asset == address(0)) revert InvalidAsset();
        if (!_supported[asset]) revert UnsupportedAsset();
        if (amount == 0) revert ZeroAmount();

        uint256 oldCap = _caps[asset];
        uint256 newCap = oldCap + amount;
        if (newCap < oldCap) revert CapOverflow();
        
        _caps[asset] = newCap;

        emit CapUpdated(asset, oldCap, newCap);
    }

    function decreaseAssetCap(
        address asset,
        uint256 amount
    ) external onlyRole(OFFICER_ROLE) {
        if (asset == address(0)) revert InvalidAsset();
        if (!_supported[asset]) revert UnsupportedAsset();
        if (amount == 0) revert ZeroAmount();

        uint256 oldCap = _caps[asset];
        // Enforce that cap cannot go below the effective floor
        if (oldCap < amount || oldCap - amount < _effectiveFloor()) {
            revert CapUnderflow();
        }

        uint256 newCap;
        unchecked { newCap = oldCap - amount; }
        _caps[asset] = newCap;

        emit CapUpdated(asset, oldCap, newCap);
    }
    /**
     * @notice Add amount to the collateral cap of the asset with highest LTV-F
     * @dev Called by YieldOfficer when yield is paid. LTV-F = (reserve value in USD) / (VY cap)
     *      Uses TWAP prices from VAO to calculate real USD value
     * @param amount Amount to add to the highest LTV-F asset's cap
     */
    function addToHighestLTVFCap(
        uint256 amount
    ) external onlyRole(OFFICER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 length = _assets.length;
        if (length == 0) revert NoSupportedAssets();
        if (address(vao) == address(0)) revert InvalidAddress();

        address highestAsset;
        uint256 highestLtvF = 0;
        address vrtAddress = address(vrt);

        for (uint256 i = 0; i < length;) {
            address asset = _assets[i];
            uint256 ltvF = _calculateLTVF(asset, vrtAddress);

            if (ltvF > highestLtvF) {
                highestLtvF = ltvF;
                highestAsset = asset;
            }
            unchecked { ++i; }
        }

        if (highestAsset == address(0)) revert NoValidAssetFound();

        uint256 oldCap = _caps[highestAsset];
        uint256 newCap = oldCap + amount;
        if (newCap < oldCap) revert CapOverflow();

        _caps[highestAsset] = newCap;

        emit CapUpdated(highestAsset, oldCap, newCap);
        emit HighestLTVCapIncreased(highestAsset, amount, newCap);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FEE PROCESSING & CAP REDUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Process transaction fees by reducing caps of lowest LTV-F assets
     * @dev Called per transaction (not monthly) to reduce cap of lowest LTV-F asset.
     *      Uses TWAP prices from VAO to calculate real USD value.
     *      Cap cannot go below the effective floor =
     *      max(assetCapFloor, maxCap / capSpreadDivisor).
     *      If an asset hits the floor, remaining fees are applied to next lowest LTV-F asset.
     * @param amount Amount of VY fees to process
     */
    function processTransactionFees(
        uint256 amount
    ) external onlyRole(OFFICER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (_assets.length == 0) revert NoSupportedAssets();
        if (address(vao) == address(0)) revert InvalidAddress();

        uint256 remainingFees = amount;

        while (remainingFees > 0) {
            // Find asset with lowest LTV-F that is above floor
            (address lowestAsset, uint256 availableReduction) = _findLowestLTVFAsset();

            // No more assets can be reduced
            if (lowestAsset == address(0)) break;

            uint256 currentCap = _caps[lowestAsset];

            // Calculate actual reduction (minimum of remaining fees and available room above floor)
            uint256 actualReduction = remainingFees > availableReduction
                ? availableReduction
                : remainingFees;

            // Apply reduction (safe: actualReduction <= availableReduction <= currentCap - floor)
            uint256 newCap;
            unchecked {
                newCap = currentCap - actualReduction;
                remainingFees -= actualReduction;
            }
            _caps[lowestAsset] = newCap;

            emit FeesAppliedToLowestLTV(lowestAsset, actualReduction, newCap);
        }

        // Emit event if fees couldn't be fully applied (all assets at floor)
        if (remainingFees > 0) {
            emit UnprocessedFees(remainingFees);
        }
    }

    /**
     * @notice Update cap utilization tracking
     * @dev Called by LoanOfficer when loans are opened/closed
     * @param asset The asset to update
     * @param utilized New utilized amount
     */
    function updateCapUtilization(
        address asset,
        uint256 utilized
    ) external onlyRole(OFFICER_ROLE) {
        if (asset == address(0)) revert InvalidAsset();
        if (!_supported[asset]) revert UnsupportedAsset();

        uint256 oldUtilized = _utilizedCaps[asset];
        _utilizedCaps[asset] = utilized;

        emit CapUtilizationUpdated(asset, oldUtilized, utilized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS (Accounting Officer functionality)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate Total Value Locked (TVL) across all assets in VRT
     * @dev Sums the balance of all supported assets in ValinityReserveTreasury
     *      Note: For simplicity, returns raw balance. In production, multiply by oracle price.
     * @return tvl Total value locked (in smallest units, normalized to 18 decimals)
     */
    function getTVL() external view returns (uint256) {
        return _calculateTVL();
    }

    /**
     * @notice Get detailed metrics for a specific asset
     * @param asset The asset address to get metrics for
     * @return metrics AssetMetrics struct with all relevant data
     */
    function getAssetMetrics(
        address asset
    ) external view returns (AssetMetrics memory metrics) {
        address vrtAddress = address(vrt);
        uint256 balance = IERC20(asset).balanceOf(vrtAddress);
        uint8 assetDecimals = _getAssetDecimals(asset);
        uint256 normalizedBalance = _scaleDecimals(
            balance,
            assetDecimals,
            DEFAULT_DECIMALS
        );

        uint256 cap = _caps[asset];
        uint256 utilized = _utilizedCaps[asset];

        // Calculate LTV-F if VAO is set
        uint256 ltvF = 0;
        if (address(vao) != address(0) && _supported[asset]) {
            ltvF = _calculateLTVF(asset, vrtAddress);
        }

        metrics = AssetMetrics({
            totalReserve: balance,
            collateralCap: cap,
            ltvRatio: cap > 0 ? (normalizedBalance * WAD) / cap : 0,
            ltvF: ltvF,
            utilized: utilized,
            available: cap > utilized ? cap - utilized : 0
        });
    }

    /**
     * @notice Get assets sorted by LTV-F (lowest first)
     * @dev LTV-F = (reserve value in USD) / (VY cap)
     *      Uses TWAP prices from VAO. Bubble sort - O(n²), suitable for small arrays.
     * @return sortedAssets Array of asset addresses sorted by LTV-F ascending
     */
    function getAssetsSortedByLTVF()
        external
        view
        returns (address[] memory sortedAssets)
    {
        uint256 len = _assets.length;
        if (len == 0) return new address[](0);
        if (address(vao) == address(0)) return _assets;

        sortedAssets = new address[](len);
        uint256[] memory ltvFs = new uint256[](len);
        address vrtAddress = address(vrt);

        // Calculate LTV-F for each asset
        for (uint256 i = 0; i < len;) {
            address asset = _assets[i];
            sortedAssets[i] = asset;
            ltvFs[i] = _calculateLTVF(asset, vrtAddress);
            unchecked { ++i; }
        }

        // Bubble sort ascending by LTV-F
        for (uint256 i = 0; i < len - 1;) {
            for (uint256 j = 0; j < len - i - 1;) {
                if (ltvFs[j] > ltvFs[j + 1]) {
                    (ltvFs[j], ltvFs[j + 1]) = (ltvFs[j + 1], ltvFs[j]);
                    (sortedAssets[j], sortedAssets[j + 1]) = (sortedAssets[j + 1], sortedAssets[j]);
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }

        return sortedAssets;
    }

    /**
     * @notice Get available cap for an asset (cap - utilized)
     * @param asset The asset to check
     * @return available Available cap for new collateralization
     */
    function getAvailableCap(
        address asset
    ) external view returns (uint256 available) {
        uint256 cap = _caps[asset];
        uint256 utilized = _utilizedCaps[asset];
        return cap > utilized ? cap - utilized : 0;
    }

    /**
     * @notice Get utilized cap for an asset
     * @param asset The asset to check
     * @return utilized Amount of cap currently utilized
     */
    function getUtilizedCap(
        address asset
    ) external view returns (uint256 utilized) {
        return _utilizedCaps[asset];
    }

    /**
     * @notice Get global system metrics
     * @dev Returns TVL, circulating VY, collateralized VY, and floor price
     * @return metrics SystemMetrics struct with all system-wide data
     */
    function getSystemMetrics() external view returns (SystemMetrics memory metrics) {
        uint256 tvl = _calculateTVL();
        address vrtAddress = address(vrt);

        uint256 vyInVrt = vyToken.balanceOf(vrtAddress);
        uint256 vyInVyt = vyToken.balanceOf(vyt);
        uint256 totalSupply = vyToken.totalSupply();
        uint256 circulating = totalSupply - vyInVrt - vyInVyt;

        metrics = SystemMetrics({
            totalValueLocked: tvl,
            totalVYCirculating: circulating,
            totalVYCollateralized: vyInVrt,
            floorPrice: circulating > 0 ? (tvl * WAD) / circulating : 0
        });
    }

    /// @notice Returns true circulating VY supply: totalSupply minus VY held in VRT and VYT.
    /// @dev Lightweight alternative to getSystemMetrics() — avoids the TVL loop entirely.
    function getTotalCirculatingVY() external view returns (uint256) {
        uint256 totalSupply = vyToken.totalSupply();
        uint256 vyInVrt = vyToken.balanceOf(address(vrt));
        uint256 vyInVyt = vyToken.balanceOf(vyt);
        return totalSupply - vyInVrt - vyInVyt;
    }

    /**
     * @notice Calculate LTV (Loan-to-Value) ratio for an asset
     * @dev LTV = (reserve balance normalized to 18 decimals) / cap
     * @param asset The asset to calculate LTV for
     * @return ltv LTV ratio scaled by WAD (1e18)
     */
    function getLTV(address asset) public view returns (uint256) {
        uint256 cap = _caps[asset];
        if (!_supported[asset] || cap == 0) return 0;

        uint256 reserve = IERC20(asset).balanceOf(address(vrt));
        uint256 scaledReserve = _scaleDecimals(
            reserve,
            _getAssetDecimals(asset),
            DEFAULT_DECIMALS
        );

        return (scaledReserve * WAD) / cap;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADDITIONAL VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get VY collateralized against an asset via VRT
     * @param asset The asset to check
     * @return Amount of VY collateralized
     */
    function getAssetCollateralized(
        address asset
    ) external view returns (uint256) {
        return vrt.collateralizedOf(asset);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

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
        if (fromDecimals > toDecimals) {
            return amount / 10 ** (fromDecimals - toDecimals);
        } else if (fromDecimals < toDecimals) {
            return amount * 10 ** (toDecimals - fromDecimals);
        }
        return amount;
    }

    /**
     * @notice Calculate TVL across all assets
     * @return tvl Total value locked normalized to 18 decimals
     */
    function _calculateTVL() internal view returns (uint256 tvl) {
        uint256 length = _assets.length;
        address vrtAddress = address(vrt);
        for (uint256 i = 0; i < length;) {
            address asset = _assets[i];
            uint256 balance = IERC20(asset).balanceOf(vrtAddress);
            uint8 assetDecimals = _getAssetDecimals(asset);
            tvl += _scaleDecimals(balance, assetDecimals, DEFAULT_DECIMALS);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Calculate LTV-F for an asset
     * @param asset The asset address
     * @param vrtAddress Cached VRT address
     * @return ltvF LTV-F value scaled by WAD, or 0 if invalid
     */
    function _calculateLTVF(
        address asset,
        address vrtAddress
    ) internal view returns (uint256 ltvF) {
        uint256 cap = _caps[asset];
        if (cap == 0) return 0;

        uint256 reserveBalance = IERC20(asset).balanceOf(vrtAddress);
        if (reserveBalance == 0) return 0;

        uint256 assetPriceUSD = vao.getAssetTwapPrice(asset);
        if (assetPriceUSD == 0) return 0;

        uint8 assetDecimals = _getAssetDecimals(asset);
        uint256 reserveNormalized = _scaleDecimals(
            reserveBalance,
            assetDecimals,
            DEFAULT_DECIMALS
        );

        uint256 reserveValueUSD = (reserveNormalized * assetPriceUSD) / WAD;
        return (reserveValueUSD * WAD) / cap;
    }

    /**
     * @notice Find asset with lowest LTV-F that has room above floor
     * @dev LTV-F = (reserve value in USD) / (VY cap)
     *      Uses TWAP prices from VAO to calculate real USD value
     * @return lowestAsset Address of asset with lowest LTV-F above floor
     * @return availableReduction Maximum amount cap can be reduced (cap - floor)
     */
    function _findLowestLTVFAsset()
        internal
        view
        returns (address lowestAsset, uint256 availableReduction)
    {
        uint256 lowestLtvF = type(uint256).max;
        address vrtAddress = address(vrt);
        uint256 floor = _effectiveFloor();
        uint256 length = _assets.length;

        for (uint256 i = 0; i < length;) {
            address asset = _assets[i];
            uint256 cap = _caps[asset];

            // Skip assets at or below floor (no room to reduce)
            if (cap <= floor) {
                unchecked { ++i; }
                continue;
            }

            uint256 ltvF = _calculateLTVF(asset, vrtAddress);

            // Find the lowest LTV-F among reducible assets
            if (ltvF < lowestLtvF) {
                lowestLtvF = ltvF;
                lowestAsset = asset;
                availableReduction = cap - floor;
            }
            unchecked { ++i; }
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ADMIN_ROLE) {}
}
