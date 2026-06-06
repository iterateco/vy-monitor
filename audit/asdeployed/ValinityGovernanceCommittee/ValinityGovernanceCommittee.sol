// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title  ValinityGovernanceCommittee (VGC)
 * @notice Valinity's governance + keeper-funding token.
 *
 * @dev Design (credibly-fixed monetary policy — all schedule numbers are
 *      constants; changing them requires a redeploy):
 *
 *  - Plain ERC20 + Permit (EIP-2612), 18 decimals. NO transfer fee / NO burn.
 *    (A burn would let anyone shrink `totalSupply()` to cheapen the governance
 *    thresholds computed as bps of supply — so it is intentionally omitted.)
 *
 *  - SUPPLY: `INITIAL_SUPPLY` (1,000,000) is minted to the treasury at
 *    construction (used to seed the VARO launch). The remaining 6,000,000 up to
 *    `MAX_SUPPLY` (7,000,000) is minted over time, forever, ONLY by the locked
 *    `minter` (the VGO / Gas Officer), which rewards the callers of ecosystem
 *    functions for the gas they spend.
 *
 *  - EMISSION CEILING (geometric on the UNMINTED supply): each 7-day epoch the
 *    minter may mint at most `epochMintBps` of `(MAX_SUPPLY - totalSupply())`
 *    snapshotted at the epoch's start. Because each epoch can only take a
 *    fraction of what's left, total supply **asymptotically approaches but can
 *    never reach** MAX_SUPPLY. At the immutable `MAX_EPOCH_MINT_BPS` of
 *    0.25%/week, reaching 70% of supply takes ~8 years (longer in practice,
 *    since the VGO mints below the ceiling — sized to real gas cost).
 *
 *  - The rate is a SAFETY cap, not the spend rate. `epochMintBps` is settable by
 *    `admin` but can NEVER exceed the immutable `MAX_EPOCH_MINT_BPS` — so
 *    governance can only ever slow emission down or halt it (`0`), never speed
 *    it past the ~8-year schedule. Both the unminted snapshot AND the bps are
 *    frozen at each epoch's start, so a mid-epoch change only takes effect from
 *    the NEXT epoch.
 *
 *  - `admin` (two-step transfer, intended to be handed to the governance
 *    Executor) sets the minter once and tunes/halts the ceiling. It can NOT
 *    mint, change the minter after it is locked, or move balances.
 */
contract ValinityGovernanceCommittee is ERC20, ERC20Permit {
    // ============================================================
    // Constants (credibly-fixed monetary policy)
    // ============================================================

    /// @notice VGC minted to the treasury at deployment (seeds the VARO launch).
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 1e18;

    /// @notice Absolute hard cap. Supply asymptotically approaches but never reaches it.
    uint256 public constant MAX_SUPPLY = 7_000_000 * 1e18;

    /// @notice Length of each mint epoch.
    uint256 public constant MINT_EPOCH = 7 days;

    /// @notice Immutable hard cap on the per-epoch ceiling, in bps of the
    ///         unminted supply. 25 = 0.25%/week → ~8 years to 70% minted.
    ///         `epochMintBps` can never exceed this, so emission can only ever
    ///         be slowed or halted, never accelerated past the schedule.
    uint256 public constant MAX_EPOCH_MINT_BPS = 25;

    uint256 private constant BASIS_POINTS = 10_000;

    // ============================================================
    // State
    // ============================================================

    /// @notice Current per-epoch ceiling, in bps of the epoch-start unminted
    ///         supply. `<= MAX_EPOCH_MINT_BPS`. `0` halts minting (emergency stop).
    uint256 public epochMintBps;

    /// @notice Sets the minter once, tunes/halts the ceiling, hands off control.
    address public admin;

    /// @notice Incoming admin for the two-step transfer (must call `acceptAdmin`).
    address public pendingAdmin;

    /// @notice The sole address allowed to mint (the VGO). Locked after `setMinter`.
    address public minter;

    /// @notice True once `setMinter` has run — the minter can never change again.
    bool public minterLocked;

    /// @notice Per-epoch mint accounting, packed into a single storage slot.
    /// @dev    Bounds: `start` to year ~8.9M; `bps` ≤ 10_000; `minted`/`unminted`
    ///         ≤ MAX_SUPPLY (7e24) ≪ uint96 max (~7.9e28). All four are written
    ///         together at each epoch reset → one SLOAD / one SSTORE per mint.
    struct Epoch {
        uint48 start;     // timestamp the current epoch began (0 = uninitialized)
        uint16 bps;       // epochMintBps frozen at the epoch's start
        uint96 minted;    // amount minted so far this epoch
        uint96 unminted;  // MAX_SUPPLY - totalSupply() at the epoch's start
    }

    /// @notice Current epoch accounting (one packed slot).
    Epoch public epoch;

    // ============================================================
    // Events
    // ============================================================

    event MinterSet(address indexed minter);
    event EpochMintBpsSet(uint256 bps);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    // ============================================================
    // Errors
    // ============================================================

    error NotAdmin();
    error NotMinter();
    error NotPendingAdmin();
    error MinterAlreadyLocked();
    error ZeroAddress();
    error ZeroAmount();
    error BpsTooHigh(uint256 max);
    error EpochLimitReached(uint256 available, uint256 requested);

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ============================================================
    // Constructor
    // ============================================================

    /**
     * @param treasury Receives the full `INITIAL_SUPPLY`.
     * @param admin_   Sets the minter once + tunes/halts the ceiling.
     * @dev `epochMintBps` starts at the immutable maximum (the designed
     *      ~8-year-to-70% schedule); governance can only ever slow it.
     */
    constructor(address treasury, address admin_)
        ERC20("Valinity Governance Committee", "VGC")
        ERC20Permit("Valinity Governance Committee")
    {
        if (treasury == address(0) || admin_ == address(0)) revert ZeroAddress();

        admin = admin_;
        epochMintBps = MAX_EPOCH_MINT_BPS;

        _mint(treasury, INITIAL_SUPPLY);

        emit EpochMintBpsSet(MAX_EPOCH_MINT_BPS);
        emit AdminTransferred(address(0), admin_);
    }

    // ============================================================
    // Admin — minter / ceiling / handoff
    // ============================================================

    /**
     * @notice Set the sole minter (the VGO). One-time; locked forever after.
     * @dev    IRREVERSIBLE. Deploy the VGO before calling this.
     */
    function setMinter(address newMinter) external onlyAdmin {
        if (minterLocked) revert MinterAlreadyLocked();
        if (newMinter == address(0)) revert ZeroAddress();
        minter = newMinter;
        minterLocked = true;
        emit MinterSet(newMinter);
    }

    /**
     * @notice Tune the per-epoch ceiling (`<= MAX_EPOCH_MINT_BPS`). `0` halts
     *         minting. Takes effect from the NEXT epoch (the current epoch's
     *         snapshot is unchanged). Can only slow or halt — never accelerate
     *         past the immutable schedule.
     */
    function setEpochMintBps(uint256 newBps) external onlyAdmin {
        if (newBps > MAX_EPOCH_MINT_BPS) revert BpsTooHigh(MAX_EPOCH_MINT_BPS);
        epochMintBps = newBps;
        emit EpochMintBpsSet(newBps);
    }

    /// @notice Begin a two-step admin transfer (intended target: the Executor).
    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @notice Accept a pending admin transfer. Callable only by `pendingAdmin`.
    function acceptAdmin() external {
        if (pendingAdmin == address(0) || msg.sender != pendingAdmin) revert NotPendingAdmin();
        address previous = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(previous, admin);
    }

    // ============================================================
    // Minting
    // ============================================================

    /**
     * @notice Mint VGC to `to`. Minter-only; clamped to the per-epoch ceiling
     *         (`epochMintBps` of the unminted supply at the epoch's start).
     * @dev    Reads/writes the packed `epoch` slot once each. The geometric
     *         ceiling guarantees `totalSupply()` stays strictly below MAX_SUPPLY,
     *         so no separate cap check is needed. OZ `_mint` has no transfer
     *         hook, so `to` cannot reenter.
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        Epoch memory e = epoch; // single SLOAD of the packed slot

        // Initialize or roll the epoch — freeze BOTH the unminted supply and the bps.
        if (e.start == 0 || block.timestamp >= uint256(e.start) + MINT_EPOCH) {
            e.start = uint48(block.timestamp);
            e.minted = 0;
            e.unminted = uint96(MAX_SUPPLY - totalSupply());
            e.bps = uint16(epochMintBps);
        }

        uint256 cap = (uint256(e.unminted) * uint256(e.bps)) / BASIS_POINTS;
        uint256 available = cap > e.minted ? cap - e.minted : 0;
        if (amount > available) revert EpochLimitReached(available, amount);

        e.minted += uint96(amount); // amount ≤ available ≤ cap ≤ MAX_SUPPLY → fits uint96
        epoch = e;                  // single SSTORE of the packed slot

        _mint(to, amount);          // emits Transfer(0, to, amount) — records the emission
    }

    // ============================================================
    // View
    // ============================================================

    /**
     * @notice How much VGC can be minted right now, and when the current epoch
     *         ends. The reset branch mirrors `mint` exactly so the VGO never
     *         mis-sizes a mint across an epoch boundary.
     */
    function getMintAllowance() external view returns (uint256 available, uint256 epochEndsAt) {
        Epoch memory e = epoch;
        bool newEpoch = (e.start == 0 || block.timestamp >= uint256(e.start) + MINT_EPOCH);

        uint256 unmintedSnap = newEpoch ? (MAX_SUPPLY - totalSupply()) : uint256(e.unminted);
        uint256 bpsSnap = newEpoch ? epochMintBps : uint256(e.bps);

        uint256 cap = (unmintedSnap * bpsSnap) / BASIS_POINTS;
        uint256 already = newEpoch ? 0 : uint256(e.minted);
        available = cap > already ? cap - already : 0;
        epochEndsAt = newEpoch ? block.timestamp + MINT_EPOCH : uint256(e.start) + MINT_EPOCH;
    }
}
