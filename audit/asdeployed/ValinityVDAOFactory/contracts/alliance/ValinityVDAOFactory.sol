// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ValinityVDAO} from "./ValinityVDAO.sol";

// ─────────────────────────────────────────────────────────────────────────────
// ValinityVDAOFactory  (UUPS-upgradeable)
// ─────────────────────────────────────────────────────────────────────────────
//
// Single-purpose deployer of ValinityVDAO instances for VARO Tier 4, and the
// SOLE SOURCE OF TRUTH for every piece of V-DAO token info:
//
//   - layer name/symbol DERIVATION ({previewNames})
//   - FCFS name/symbol UNIQUENESS registry ({nameTaken}/{symbolTaken})
//   - the PERMANENT, IMMUTABLE on-token wiring every minted V-DAO bakes in:
//       * `veo`     — the protocol's blessed swap router
//       * `mainDax` — the main ValinityDAX VY/V-DAO pool
//     Both are owned HERE, never passed in by VARO, so a buggy/misconfigured
//     VARO can never bake a wrong permanent exemption into an IMMUTABLE token.
//
// THE FACTORY IS UPGRADEABLE; THE TOKENS IT MINTS ARE NOT.
//   This contract is a UUPS proxy so launch logic / wiring can be patched. Each
//   {ValinityVDAO} it deploys is a plain CREATE2 contract with constructor-only
//   setup — no admin, no owner, no upgrade authority. Upgrading the factory
//   changes how FUTURE tokens are made; already-deployed tokens are frozen.
//
// WHY THE MAIN DAX (and only the main DAX) IS EXEMPT ON EVERY V-DAO:
//   The main ValinityDAX books the REQUESTED transfer amount, not the received
//   balance, so a 0.7% burn on every swap-in would slowly make it overcount its
//   V-DAO reserve. Exempting it keeps received == booked. The SEPARATE VDAO DAX
//   is intentionally NOT exempt — it uses balance-delta accounting, so the burn
//   there is safe AND intended/deflationary.
//   Fee exemption is one of three things a tradeable V-DAO needs; the other two
//   are handled OUTSIDE this factory:
//     1. The VY/V-DAO pool on the main DAX — created PER LAUNCH by VARO
//        (`vdax.addPool` inside `_executeVDAOSplit` / `bootstrapVGCVDAO`), which
//        also flips the main-DAX listing flag the VDAO DAX checks.
//     2. The MEV bot's swap-whitelist on the main DAX AND the VDAO DAX
//        (`swapExactIn` is `onlySwapWhitelisted`) — a ONE-TIME admin step,
//        global per-DAX not per-pool, so it covers every future V-DAO. VARO
//        CANNOT do it (POOL_CREATOR_ROLE only), so it lives in the deploy
//        checklist (see deploy/545). The main-DAX bot whitelist is already live.
//
// LAYER NAMING (nested V-DAOs, i.e. a V-DAO launched on top of another):
//   name   = "{userName} {directParentSymbol} L{depth}"   (bounded — carries only
//            the IMMEDIATE parent's symbol, never the whole ancestor chain)
//   symbol = "{userSymbol}L{depth}"                        (depth only; no parent)
//   depth  = 1 for a base V-DAO; first nesting = 2, then 3, … unlimited.
// Base (depth 1) V-DAOs keep the user's chosen name/symbol verbatim. Uniqueness
// is FCFS on the DERIVED strings, so siblings differ by the user prefix.
//
// Permissioning: `launch` is callable only by the configured VARO (VARO_ROLE).
// `DEFAULT_ADMIN_ROLE` may rotate the VARO pointer, the wiring, and authorize
// upgrades.
// ─────────────────────────────────────────────────────────────────────────────

contract ValinityVDAOFactory is Initializable, AccessControl, UUPSUpgradeable {
    /// @notice The VARO instance allowed to call {launch} / {reserveName}.
    bytes32 public constant VARO_ROLE = keccak256("VARO_ROLE");

    /// @notice The configured VARO address (mirrors VARO_ROLE for off-chain reads
    ///         and the VDAO's permanent `varo` exemption — it is this factory's
    ///         caller at deploy time, i.e. `msg.sender` of the CREATE2).
    address public varo;

    /// @notice Protocol's blessed swap router. Permanently exempt on every V-DAO
    ///         this factory deploys. Owned HERE (not a launch argument) so the
    ///         immutable token can never bake in a wrong router.
    address public veo;

    /// @notice Main ValinityDAX, fee-exempt on every V-DAO this factory deploys
    ///         so the main DAX's VY/V-DAO pool never overcounts its reserve.
    address public mainDax;

    /// @notice FCFS uniqueness registry on the DERIVED name/symbol. The factory
    ///         is the single authority: {launch} reserves the derived strings it
    ///         is about to mint; {reserveName} reserves for externally-deployed
    ///         V-DAOs (the VGC bootstrap), which never flow through {launch}.
    mapping(bytes32 => bool) public nameTaken;   // keccak(DERIVED name)
    mapping(bytes32 => bool) public symbolTaken;  // keccak(DERIVED symbol)

    event VDAOLaunched(address indexed creator, address indexed vdao, bytes32 salt);
    event VaroSet(address newVaro);
    event VeoSet(address newVeo);
    event MainDaxSet(address newMainDax);
    event NameReserved(bytes32 indexed nameKey, bytes32 indexed symbolKey);

    error ZeroAddress();
    error NameTaken();
    error SymbolTaken();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param admin_   DEFAULT_ADMIN_ROLE: rotates wiring + authorizes upgrades.
    /// @param veo_     Blessed router, permanently exempt on every minted V-DAO.
    /// @param mainDax_ Main ValinityDAX, permanently exempt on every minted V-DAO.
    function initialize(address admin_, address veo_, address mainDax_) external initializer {
        if (admin_ == address(0) || veo_ == address(0) || mainDax_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        veo     = veo_;
        mainDax = mainDax_;
        emit VeoSet(veo_);
        emit MainDaxSet(mainDax_);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ── Admin wiring ─────────────────────────────────────────────────────────

    function setVaro(address newVaro) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newVaro == address(0)) revert ZeroAddress();
        if (varo != address(0)) _revokeRole(VARO_ROLE, varo);
        varo = newVaro;
        _grantRole(VARO_ROLE, newVaro);
        emit VaroSet(newVaro);
    }

    function setVeo(address newVeo) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newVeo == address(0)) revert ZeroAddress();
        veo = newVeo;
        emit VeoSet(newVeo);
    }

    function setMainDax(address newMainDax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMainDax == address(0)) revert ZeroAddress();
        mainDax = newMainDax;
        emit MainDaxSet(newMainDax);
    }

    // ── Name derivation + uniqueness ───────────────────────────────────────────

    /// @notice Derive the final on-chain name/symbol for a (possibly nested)
    ///         V-DAO. For a base launch (`parent == 0` or `layer <= 1`) the
    ///         user's inputs are returned verbatim. For a layer, the name gets
    ///         the immediate parent's symbol + the depth suffix, and the symbol
    ///         gets only the depth suffix — both bounded regardless of depth.
    /// @dev    View, so VARO can pre-flight the FCFS uniqueness check on the
    ///         DERIVED strings for UX BEFORE the tx (the binding check is in
    ///         {launch}). `launch` re-derives internally — it never trusts a
    ///         caller-supplied derived string.
    function previewNames(
        string calldata baseName,
        string calldata baseSymbol,
        address parent,
        uint8 layer
    ) public view returns (string memory name_, string memory symbol_) {
        if (parent == address(0) || layer <= 1) return (baseName, baseSymbol);
        string memory d = Strings.toString(layer);
        name_   = string.concat(baseName, " ", IERC20Metadata(parent).symbol(), " L", d);
        symbol_ = string.concat(baseSymbol, "L", d);
    }

    /// @notice Reserve a name/symbol for a V-DAO deployed OUTSIDE this factory
    ///         (the one-shot VGC bootstrap). Reverts if either is taken. VARO
    ///         calls this so the factory stays the single uniqueness authority.
    function reserveName(string calldata name_, string calldata symbol_)
        external
        onlyRole(VARO_ROLE)
    {
        bytes32 nameKey   = keccak256(bytes(name_));
        bytes32 symbolKey = keccak256(bytes(symbol_));
        if (nameTaken[nameKey])     revert NameTaken();
        if (symbolTaken[symbolKey]) revert SymbolTaken();
        nameTaken[nameKey]     = true;
        symbolTaken[symbolKey] = true;
        emit NameReserved(nameKey, symbolKey);
    }

    // ── Launch ─────────────────────────────────────────────────────────────────

    /// @notice Deploy a V-DAO with deterministic CREATE2 address. Only callable
    ///         by the configured VARO. The factory DERIVES the final name/symbol,
    ///         enforces + reserves FCFS uniqueness, then mints — all atomically,
    ///         so VARO passes only the user's BASE inputs (+ parent/layer); it
    ///         never supplies a derived string or any permanent token wiring.
    ///         Salt = keccak256(creator).
    ///
    ///         SUPPLY: `activeSupply_` is the TRADEABLE half VARO seeds on. The
    ///         token mints 2× internally — `activeSupply_` to THIS factory (which
    ///         it forwards here to VARO for the usual launch split) and an equal
    ///         locked half held inside the token, vesting linearly to the creator
    ///         over 1 year ({ValinityVDAO.claimVested}). VARO is oblivious to the
    ///         locked half: it only ever sees/seeds `activeSupply_`.
    /// @return vdao   Deployed V-DAO address.
    /// @return name_  Final derived name (so VARO can record/emit it).
    /// @return symbol_ Final derived symbol.
    function launch(
        string  calldata baseName,
        string  calldata baseSymbol,
        uint256 activeSupply_,
        address creator_,
        bytes32 logoCID_,
        address parent_,
        uint8   layer_
    ) external onlyRole(VARO_ROLE) returns (address vdao, string memory name_, string memory symbol_) {
        (name_, symbol_) = previewNames(baseName, baseSymbol, parent_, layer_);

        bytes32 nameKey   = keccak256(bytes(name_));
        bytes32 symbolKey = keccak256(bytes(symbol_));
        if (nameTaken[nameKey])     revert NameTaken();
        if (symbolTaken[symbolKey]) revert SymbolTaken();
        nameTaken[nameKey]     = true;
        symbolTaken[symbolKey] = true;

        bytes32 salt = keccak256(abi.encodePacked("VALINITY_VDAO", creator_));
        vdao = address(new ValinityVDAO{salt: salt}(
            name_, symbol_, activeSupply_, creator_, logoCID_, msg.sender, veo, mainDax
        ));

        // The token mints the ACTIVE half to this factory (the locked vesting half
        // stays inside the token). Forward that active half on to VARO. Factory is
        // exempt at the V-DAO so this transfer pulls no fee.
        ValinityVDAO(vdao).transfer(msg.sender, activeSupply_);

        emit VDAOLaunched(creator_, vdao, salt);
    }

    /// @dev Reserved storage gap for future upgrades.
    uint256[44] private __gap;
}
