// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

// ─────────────────────────────────────────────────────────────────────────────
// ValinityVDAO  —  Valinity Decentralized Organization token
// ─────────────────────────────────────────────────────────────────────────────
//
// Fully-immutable creator token deployed by the VDAO factory at VARO Tier 4.
//
//   - No admin, no owner, no upgrade authority. Constructor-only setup.
//   - 18 decimals (fixed). ERC20 + Permit (EIP-2612) + Burnable.
//   - Metadata (`name`, `symbol`, `logoCID`) fixed at launch.
//   - FIXED SUPPLY: the ENTIRE supply (2× `activeSupply_`) is minted ONCE in the
//     constructor. There is no mint function — supply only ever shrinks (burns).
//
// SUPPLY SPLIT AT LAUNCH (total minted = 2 × activeSupply_)
// ─────────────────────────────────────────────────────────
//   - activeSupply_  → minted to the FACTORY (msg.sender), forwarded to VARO,
//                      which runs the usual launch split on it (LP legs + creator
//                      cut). This is the "active" half that goes liquid day one.
//   - activeSupply_  → minted to THIS CONTRACT (address(this)) and LOCKED as the
//                      creator's vesting pool. It releases LINEARLY, per-second,
//                      over {VEST_DURATION} (1 year). ONLY the creator can pull
//                      it, via {claimVested}. Until claimed it sits inert in the
//                      token (fee-exempt, so a claim pays no burn). Nothing about
//                      this half is mintable — it is pre-minted and time-locked.
//
//   So the user names `activeSupply_` (the tradeable/seeded amount). The token's
//   true max supply is 2× that; the second half can never reach the market faster
//   than the 1-year linear schedule allows.
//
// 0.7% TRANSFER FEE  → BURN
// ─────────────────────────
// Every transfer between two non-exempt parties deducts 0.7% from `value` and
// BURNS it. Through VEO (exempt) the intrinsic fee is skipped and VEO charges its
// own 0.7% to the creator; outside VEO the intrinsic 0.7% burns, shrinking supply.
//
// EXEMPTIONS (set once at construction, never changed)
// ────────────────────────────────────────────────────
//   - factory      (immediate post-mint forward to VARO; inert after launch tx)
//   - address(this)(PERMANENT — holds the vesting pool; a {claimVested} release
//                   to the creator must not burn the creator's own tranche)
//   - `varo`       (PERMANENT — claim-path handler; no fee skim)
//   - `veo`        (PERMANENT — the protocol's blessed router)
//   - `vdax`       (PERMANENT — the main ValinityDAX VY/V-DAO pool; trust-the-
//                   amount accounting must not be undercut by a burn. The SEPARATE
//                   VDAO DAX is NOT exempt — its balance-delta accounting makes the
//                   burn there safe AND intended/deflationary.)
//
// No setter, no latch — the exempt set is closed and final after deploy. Mint and
// burn (either side == 0x0) skip the fee. Direct Uniswap V2 trades work via the
// `*SupportingFeeOnTransferTokens` router variants.
// ─────────────────────────────────────────────────────────────────────────────

contract ValinityVDAO is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice Transfer fee, in bps of `value`. Fixed at 70 (0.7%).
    uint256 public constant TRANSFER_FEE_BPS = 70;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Linear vesting window for the creator's locked half. Fixed 1 year.
    uint256 public constant VEST_DURATION = 365 days;

    /// @notice IPFS multihash (bytes32 v1) of the V-DAO logo.
    bytes32 public immutable logoCID;

    /// @notice EOA that paid the T4 launch fee. Receives V-DAO tokens at launch
    ///         (10% of the active half via VARO) and from VEO swap fees (full
    ///         0.7% on every VEO-routed swap). Also the ONLY address that can pull
    ///         the locked vesting half via {claimVested}. Does NOT receive the
    ///         intrinsic transfer fee — that burns.
    address public immutable creator;

    /// @notice VARO instance. PERMANENTLY exempt. Handles V-DAO movement during
    ///         T4 referrer claim payouts without fee skim.
    address public immutable varo;

    /// @notice VEO instance. PERMANENTLY exempt — the protocol's blessed router.
    address public immutable veo;

    /// @notice Main ValinityDAX (the VY/V-DAO basket pool). PERMANENTLY exempt.
    address public immutable vdax;

    /// @notice Total tokens locked for the creator's linear vest (the second half
    ///         = `activeSupply_`). Fixed at construction.
    uint256 public immutable vestTotal;

    /// @notice Unix timestamp the vest started (construction time).
    uint256 public immutable vestStart;

    /// @notice Cumulative amount already released to the creator via {claimVested}.
    uint256 public vestClaimed;

    /// @notice Per-address exemption from the 0.7% intrinsic burn fee.
    ///         Frozen after deploy; no setter.
    mapping(address => bool) public feeExempt;

    event VestedClaimed(address indexed creator, uint256 amount, uint256 totalClaimed);

    error NotCreator();
    error NothingToClaim();
    error ZeroSupply();

    /// @param activeSupply_ The tradeable half (what VARO seeds on). The locked
    ///        creator-vesting half equals this amount, so total minted = 2×.
    constructor(
        string  memory name_,
        string  memory symbol_,
        uint256 activeSupply_,
        address creator_,
        bytes32 logoCID_,
        address varo_,
        address veo_,
        address vdax_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (activeSupply_ == 0) revert ZeroSupply(); // fail fast — immutable token
        creator = creator_;
        varo    = varo_;
        veo     = veo_;
        vdax    = vdax_;
        logoCID = logoCID_;

        feeExempt[msg.sender]    = true; // factory (inert after the launch tx)
        feeExempt[address(this)] = true; // permanent — holds the vesting pool
        feeExempt[varo_]         = true; // permanent — claim-path handler
        feeExempt[veo_]          = true; // permanent — blessed swap router
        feeExempt[vdax_]         = true; // permanent — main DAX keeps accurate books

        // Active half → factory (forwarded to VARO for the usual launch split).
        _mint(msg.sender, activeSupply_);

        // Locked half → this contract, released linearly to the creator over 1yr.
        vestTotal = activeSupply_;
        vestStart = block.timestamp;
        _mint(address(this), activeSupply_);
    }

    /// @notice Total amount that has vested (unlocked) by `block.timestamp`.
    ///         Linear from 0 at `vestStart` to `vestTotal` at `vestStart +
    ///         VEST_DURATION`. Caps at `vestTotal` after the window closes.
    function vestedTotal() public view returns (uint256) {
        uint256 elapsed = block.timestamp - vestStart;
        if (elapsed >= VEST_DURATION) return vestTotal;
        return (vestTotal * elapsed) / VEST_DURATION;
    }

    /// @notice Amount the creator can pull right now (vested minus already claimed).
    function claimable() public view returns (uint256) {
        return vestedTotal() - vestClaimed;
    }

    /// @notice Pull all currently-claimable vested tokens to the creator. Linear
    ///         per-second; callable as often as desired (each call sweeps the
    ///         accrued delta). Creator-only. The token is fee-exempt, so the
    ///         creator receives the full amount with no burn.
    function claimVested() external returns (uint256 amount) {
        if (msg.sender != creator) revert NotCreator();
        uint256 claimed = vestClaimed;              // single SLOAD
        amount = vestedTotal() - claimed;           // inline claimable()
        if (amount == 0) revert NothingToClaim();
        claimed += amount;
        vestClaimed = claimed;
        _transfer(address(this), creator, amount);
        emit VestedClaimed(creator, amount, claimed);
    }

    /// @dev Override `_update` to BURN 0.7% on every non-exempt transfer. Mint and
    ///      burn (either side == 0x0) skip the fee.
    function _update(address from, address to, uint256 value) internal override {
        if (
            from == address(0) ||
            to   == address(0) ||
            feeExempt[from] ||
            feeExempt[to]
        ) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * TRANSFER_FEE_BPS) / BPS_DENOMINATOR;
        if (fee != 0) {
            // Burn the fee — reduces totalSupply.
            super._update(from, address(0), fee);
        }
        unchecked {
            super._update(from, to, value - fee);
        }
    }
}
