// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IValinityExecutor {
    function schedule(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt
    ) external;

    function execute(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt
    ) external payable;

    function MIN_DELAY() external view returns (uint256);
}

interface IPremiumRegistry {
    /// @notice True once `account` has been granted permanent premium status
    ///         (the VYO — free tier-3 lane or the paid-premium lane).
    function isPremium(address account) external view returns (bool);
}

interface IValinityStakingRouter {
    /// @notice Per-user VY stake slot (0..2). `principalVY` is the VY locked in
    ///         that slot; `unlockTime` is when it becomes withdrawable. Mirrors
    ///         the auto-generated getter for `mapping(address => Stake[3])`.
    function stakes(address user, uint256 stakeId) external view returns (
        bool active,
        uint8 tierId,
        uint64 unlockTime,
        uint256 daxCredits,
        uint256 uniCredits,
        uint256 principalVY
    );

    /// @notice Per-user asset stake. `asset` is the staked token, `principalAsset`
    ///         the amount in that token's units, `unlockTime` when withdrawable.
    ///         VGC stakes live here (the Stage-1 staked-weight source). Mirrors
    ///         the auto-generated getter for `mapping(address => mapping(uint256 => AssetStake))`.
    function assetStakes(address user, uint256 stakeId) external view returns (
        bool active,
        bool isUniLP,
        address asset,
        uint64 unlockTime,
        uint256 principalAsset,
        uint256 lpAmount
    );

    /// @notice One past the highest asset-stake id ever assigned to `user`; the
    ///         scan bound for summing a user's VGC asset stakes.
    function nextAssetStakeId(address user) external view returns (uint256);
}

/**
 * @title ValinityGovernanceOfficer (v3 — Dual Chamber, quorum + supermajority)
 * @notice Two-stage stake-to-vote governance:
 *           Stage 1 — VGC chamber votes on the DRAFT
 *           Stage 2 — VY  chamber votes on the EXECUTION
 *
 * FLOW
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. propose()  — Opens a draft with the caller's weight as auto-YES; weight
 *                 must reach >= 1% of VGC totalSupply (DRAFT_THRESHOLD_BPS).
 *                 Weight is the SUM of two Sybil-resistant sources (mirroring
 *                 Stage 2's VY rules):
 *                   • LIQUID:  VGC escrowed here (locked until the draft closes).
 *                   • STAKED:  the caller's VSR-staked VGC — asset stakes whose
 *                              asset is VGC and whose unlockTime outlasts the
 *                              draft window, auto-scanned from VSR (no list to
 *                              pass). State = Draft. The VGC supply is snapshotted
 *                              as the Stage-1 quorum denominator.
 * 2. supportDraft() / opposeDraft()  — Anyone votes VGC YES or NO during the
 *                 7-day draft window, with the same escrow + auto-scanned weight.
 * 3. promote()  — Anyone may call AFTER the draft window closes, IF the draft
 *                 passed all three Stage-1 gates:
 *                   (a) at least one PREMIUM wallet voted YES,
 *                   (b) QUORUM: vgcYes + vgcNo >= 50% of the VGC snapshot,
 *                   (c) MAJORITY: vgcYes >= 51% of the votes cast.
 *                 promote() snapshots circulating VY and opens Stage 2. It must
 *                 be called within PROMOTION_PERIOD of the draft closing, else
 *                 the (passed) draft expires.
 * 4. voteYes() / voteNo()  — VY voting during the 7-day proposal window. A
 *                 voter's weight is the SUM of two Sybil-resistant sources:
 *                   • LIQUID:  VY they escrow into this contract (locked until
 *                              the window closes), passed as the call `amount`.
 *                   • STAKED:  their VSR-staked VY (principalVY summed over slots
 *                              0..2), counted ONCE, and ONLY for slots whose
 *                              unlockTime outlasts voteEndTime — so the locked VY
 *                              cannot be withdrawn and re-voted from a 2nd wallet.
 *                 `amount` may be 0 to vote with the staked position alone.
 *                 Only VSR VY stakes count — VYO stakes are intentionally ignored.
 * 5. queue()    — Anyone may call AFTER the proposal window closes, IF:
 *                   (a) at least one PREMIUM wallet voted YES,
 *                   (b) QUORUM: vyYes + vyNo >= 50% of circulating VY snapshot,
 *                   (c) SUPERMAJORITY: vyYes >= 70% of the votes cast.
 * 6. execute()  — Anyone may call after the Executor's MIN_DELAY (7 days).
 *
 * Outcomes depend on the ratio of votes CAST, so they can only be evaluated once
 * a window has closed — there is no early promotion and no early kill; every
 * window runs its full length.
 *
 * Voters reclaim their ESCROWED tokens via withdrawVGC / withdrawVY after the
 * relevant window deadline (VSR-staked VGC/VY never leave VSR — nothing to
 * reclaim here). A proposer whose proposal fails is barred from opening another
 * for PENALTY_PERIOD (re-proposal cooldown). The full actions of every proposal
 * are emitted in DraftCreated, so proposals are self-describing on-chain.
 *
 * CIRCULATING SUPPLIES
 *   VGC circulating = VGC.totalSupply()            (snapshotted at propose)
 *   VY  circulating = VY.totalSupply() - VY.balanceOf(VRT) - VY.balanceOf(VYT)
 *                                                  (snapshotted at promote)
 *   Both liquid (escrowed) and VSR-staked VY are part of this circulating base,
 *   counted once each, so vyYes + vyNo can never exceed it.
 *
 * Non-upgradeable. All addresses immutable. No admin roles.
 */
contract ValinityGovernanceOfficer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────────────────────
    // Types
    // ────────────────────────────────────────────────────────────────────

    enum ProposalState {
        Draft,          // 0 — VGC voting in progress
        DraftDefeated,  // 1 — draft window closed without meeting the Stage-1 gates
                        //     (or passed but the promotion window then lapsed)
        DraftSucceeded, // 2 — draft passed all Stage-1 gates; awaiting promote()
        Active,         // 3 — promoted; VY voting in progress
        Defeated,       // 4 — VY window closed without meeting the Stage-2 gates
        Succeeded,      // 5 — VY passed all Stage-2 gates; awaiting queue()
        Queued,         // 6 — scheduled in Executor timelock
        Executed        // 7 — done
    }

    struct ProposalCore {
        // Identity
        address proposer;
        bytes32 actionsHash;

        // Stage 1 — VGC (draft)
        uint64  draftEndTime;
        uint256 vgcSnapshot;     // VGC totalSupply at propose() — Stage-1 quorum denominator
        uint256 vgcYes;
        uint256 vgcNo;
        bool    premiumYesVgc;   // a premium wallet staked YES in the VGC chamber

        // Stage 2 — VY (proposal)
        uint64  voteStartTime;   // 0 until promoted
        uint64  voteEndTime;     // 0 until promoted
        uint256 circulatingVY;   // snapshot at promotion — Stage-2 quorum denominator
        uint256 vyYes;
        uint256 vyNo;
        bool    premiumYesVy;    // a premium wallet staked YES in the VY chamber

        // Flags
        bool queued;
        bool executed;
    }

    /// @dev yes/no hold total WEIGHT (escrow + counted stake). `stakeCounted`
    ///      ensures a voter's VSR-staked VGC is folded into their weight only once.
    struct DraftVoter { uint256 yesAmount; uint256 noAmount; bool stakeCounted; bool hasVoted; }
    /// @dev yes/no hold total WEIGHT (escrow + counted stake). `stakeCounted`
    ///      ensures a voter's VSR-staked VY is folded into their weight only once.
    struct VoteVoter  { uint256 yesAmount; uint256 noAmount; bool stakeCounted; bool hasVoted; }

    // ────────────────────────────────────────────────────────────────────
    // Immutable links
    // ────────────────────────────────────────────────────────────────────

    IERC20 public immutable vgcToken;
    IERC20 public immutable vyToken;
    address public immutable vrt;
    address public immutable vyt;
    IValinityExecutor public immutable executor;
    /// @notice The VYO — sole authority on which wallets are PREMIUM.
    IPremiumRegistry public immutable premiumRegistry;
    /// @notice The VSR — source of per-user staked VY used as Stage-2 weight.
    IValinityStakingRouter public immutable stakingRouter;

    // ────────────────────────────────────────────────────────────────────
    // Parameters (immutable constants)
    // ────────────────────────────────────────────────────────────────────

    /// @dev 1% of VGC totalSupply required to open a draft.
    uint256 public constant DRAFT_THRESHOLD_BPS = 100;

    /// @dev Stage 1 QUORUM: 50% of the VGC snapshot must vote (yes + no).
    uint256 public constant DRAFT_QUORUM_BPS = 5000;

    /// @dev Stage 1 MAJORITY: 51% of the VGC votes cast must be YES.
    uint256 public constant DRAFT_MAJORITY_BPS = 5100;

    /// @dev Stage 2 QUORUM: 50% of the circulating-VY snapshot must vote (yes + no).
    uint256 public constant VY_QUORUM_BPS = 5000;

    /// @dev Stage 2 SUPERMAJORITY: 70% of the VY votes cast must be YES.
    uint256 public constant VY_PASS_BPS = 7000;

    /// @dev VGC support-collection window.
    uint256 public constant DRAFT_PERIOD = 7 days;

    /// @dev VY voting window once promoted.
    uint256 public constant VOTING_PERIOD = 7 days;

    /// @dev After the draft closes, a PASSED draft must be promoted within this
    ///      window; otherwise it expires (frees the single-proposal slot).
    uint256 public constant PROMOTION_PERIOD = 7 days;

    /// @dev Cooldown barring a proposer from opening another proposal after their
    ///      draft or proposal fails.
    uint256 public constant PENALTY_PERIOD = 7 days;

    uint256 private constant BASIS_POINTS = 10_000;

    // ────────────────────────────────────────────────────────────────────
    // Storage
    // ────────────────────────────────────────────────────────────────────

    uint256 public proposalCount;
    /// @notice ID of the proposal currently occupying a contested voting phase
    ///         (Draft / DraftSucceeded / Active). 0 if none.
    uint256 public activeProposalId;

    mapping(uint256 => ProposalCore) public proposals;
    mapping(uint256 => mapping(address => DraftVoter)) public draftVoter;
    mapping(uint256 => mapping(address => VoteVoter))  public voteVoter;

    // Locked balances and unlock deadlines, tracked separately per token.
    mapping(address => uint256) public vgcLocked;
    mapping(address => uint256) public vyLocked;
    mapping(address => uint256) public vgcUnlockTime;
    mapping(address => uint256) public vyUnlockTime;

    /// @notice Each proposer's most recent proposalId — drives the post-failure
    ///         re-proposal cooldown.
    mapping(address => uint256) public lastProposalOf;

    // ────────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────────

    event DraftCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        bytes32 actionsHash,
        string description,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        uint256 draftStartTime,
        uint256 draftEndTime,
        uint256 proposerWeight,
        uint256 vgcSnapshot
    );

    event DraftVoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 amount,
        uint256 totalVgcYes,
        uint256 totalVgcNo
    );

    event ProposalPromoted(
        uint256 indexed proposalId,
        uint256 voteStartTime,
        uint256 voteEndTime,
        uint256 circulatingVY
    );

    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 amount,
        uint256 totalVyYes,
        uint256 totalVyNo
    );

    event ProposalQueued(uint256 indexed proposalId, uint256 eta);
    event ProposalExecuted(uint256 indexed proposalId);

    event VGCWithdrawn(address indexed user, uint256 amount);
    event VYWithdrawn(address indexed user, uint256 amount);

    // ────────────────────────────────────────────────────────────────────
    // Errors
    // ────────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error ArrayLengthMismatch();
    error EmptyProposal();
    error AlreadyInFlight(uint256 activeId);
    error InsufficientBalance(uint256 required, uint256 available);
    error ProposalNotFound(uint256 proposalId);
    error InvalidState(uint256 proposalId, ProposalState current);
    error InvalidActionsHash(bytes32 expected, bytes32 provided);
    error CannotVoteBothSides(uint256 proposalId, address voter);
    error TokensStillLocked(uint256 unlockAt, uint256 nowTs);
    error InsufficientLocked(uint256 requested, uint256 available);
    error NoCirculatingVY();
    error ProposerInCooldown(uint256 cooldownEnd);

    // ────────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────────

    /**
     * @param _vgc       VGC token address.
     * @param _vy        VY token address.
     * @param _vrt       Valinity Reserve Treasury (excluded from VY circulating).
     * @param _vyt       Valinity Yield Treasury (excluded from VY circulating).
     * @param _executor  ValinityExecutor (timelock).
     * @param _vyo       ValinityYieldOfficer (premium-status registry).
     * @param _vsr       ValinityStakingRouter (source of staked-VY voting weight).
     */
    constructor(
        address _vgc,
        address _vy,
        address _vrt,
        address _vyt,
        address _executor,
        address _vyo,
        address _vsr
    ) {
        if (_vgc == address(0) || _vy == address(0) || _vrt == address(0)
            || _vyt == address(0) || _executor == address(0) || _vyo == address(0)
            || _vsr == address(0)) revert ZeroAddress();
        vgcToken        = IERC20(_vgc);
        vyToken         = IERC20(_vy);
        vrt             = _vrt;
        vyt             = _vyt;
        executor        = IValinityExecutor(_executor);
        premiumRegistry = IPremiumRegistry(_vyo);
        stakingRouter   = IValinityStakingRouter(_vsr);
    }

    // ====================================================================
    // STAGE 1 — DRAFT (VGC chamber)
    // ====================================================================

    /**
     * @notice Open a new draft. The caller's YES weight is escrowed VGC PLUS
     *         their VSR-staked VGC (auto-scanned, see {_vgcStakedWeight}); it must
     *         reach 1% of VGC totalSupply (DRAFT_THRESHOLD_BPS). The current VGC
     *         supply is snapshotted as the Stage-1 quorum base. The full actions
     *         are emitted in {DraftCreated} so the proposal is self-describing.
     * @dev    A proposer whose previous proposal FAILED is barred for
     *         PENALTY_PERIOD (re-proposal cooldown), computed inline from their
     *         own last proposal — no keeper, and un-dodgeable by same-block
     *         re-proposing. Deters slot-occupation griefing by a >=1% holder.
     * @param escrowAmount Liquid VGC to escrow as YES weight (may be 0).
     */
    function propose(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[]   calldata calldatas,
        string    calldata description,
        uint256   escrowAmount
    ) external nonReentrant returns (uint256 proposalId) {
        // Only one proposal may occupy a contested voting phase at a time.
        if (activeProposalId != 0) {
            ProposalState s = state(activeProposalId);
            if (s == ProposalState.Draft || s == ProposalState.DraftSucceeded || s == ProposalState.Active) {
                revert AlreadyInFlight(activeProposalId);
            }
        }

        // Post-failure cooldown: a proposer whose last proposal failed must wait
        // PENALTY_PERIOD past its terminal time before opening another.
        uint256 last = lastProposalOf[msg.sender];
        if (last != 0) {
            ProposalState ls = state(last);
            if (ls == ProposalState.DraftDefeated || ls == ProposalState.Defeated) {
                ProposalCore storage lp = proposals[last];
                uint256 cooldownEnd =
                    (ls == ProposalState.DraftDefeated ? lp.draftEndTime : lp.voteEndTime) + PENALTY_PERIOD;
                if (block.timestamp < cooldownEnd) revert ProposerInCooldown(cooldownEnd);
            }
        }

        if (targets.length != values.length || targets.length != calldatas.length) revert ArrayLengthMismatch();
        if (targets.length == 0) revert EmptyProposal();

        uint256 vgcSupply = vgcToken.totalSupply();
        uint256 threshold = (vgcSupply * DRAFT_THRESHOLD_BPS) / BASIS_POINTS;
        if (threshold == 0) revert ZeroAmount();

        proposalId = ++proposalCount;
        activeProposalId = proposalId;
        lastProposalOf[msg.sender] = proposalId;

        uint64 startTs = uint64(block.timestamp);
        uint64 endTs   = uint64(block.timestamp + DRAFT_PERIOD);
        bytes32 aHash  = hashActions(targets, values, calldatas);

        ProposalCore storage p = proposals[proposalId];
        p.proposer     = msg.sender;
        p.actionsHash  = aHash;
        p.draftEndTime = endTs;
        p.vgcSnapshot  = vgcSupply;

        // Proposer's YES weight = escrowed VGC + their qualifying staked VGC.
        uint256 weight = 0;
        if (escrowAmount > 0) {
            vgcToken.safeTransferFrom(msg.sender, address(this), escrowAmount);
            _addVgcLock(msg.sender, escrowAmount, endTs);
            weight += escrowAmount;
        }
        uint256 staked = _vgcStakedWeight(msg.sender, endTs);
        bool counted = staked > 0;
        if (counted) weight += staked;

        if (weight < threshold) revert InsufficientBalance(threshold, weight);

        p.vgcYes = weight;
        if (premiumRegistry.isPremium(msg.sender)) p.premiumYesVgc = true;

        draftVoter[proposalId][msg.sender] =
            DraftVoter({ yesAmount: weight, noAmount: 0, stakeCounted: counted, hasVoted: true });

        emit DraftCreated(
            proposalId, msg.sender, aHash, description,
            targets, values, calldatas,
            startTs, endTs, weight, vgcSupply
        );
    }

    /**
     * @notice Vote YES on the active draft. Weight = `escrowAmount` of VGC
     *         escrowed here PLUS (on the voter's first vote) their VSR-staked VGC.
     *         `escrowAmount` may be 0 to vote with staked VGC alone.
     */
    function supportDraft(uint256 proposalId, uint256 escrowAmount) external nonReentrant {
        _voteDraft(proposalId, escrowAmount, true);
    }

    /// @notice Vote NO on the active draft. Same weight rules as {supportDraft}.
    function opposeDraft(uint256 proposalId, uint256 escrowAmount) external nonReentrant {
        _voteDraft(proposalId, escrowAmount, false);
    }

    function _voteDraft(uint256 proposalId, uint256 escrowAmount, bool support) internal {
        ProposalCore storage p = proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalNotFound(proposalId);

        ProposalState cur = state(proposalId);
        if (cur != ProposalState.Draft) revert InvalidState(proposalId, cur);

        DraftVoter storage dv = draftVoter[proposalId][msg.sender];
        if (dv.hasVoted) {
            if ( support && dv.noAmount  > 0) revert CannotVoteBothSides(proposalId, msg.sender);
            if (!support && dv.yesAmount > 0) revert CannotVoteBothSides(proposalId, msg.sender);
        }

        uint256 weight = 0;
        if (escrowAmount > 0) {
            vgcToken.safeTransferFrom(msg.sender, address(this), escrowAmount);
            _addVgcLock(msg.sender, escrowAmount, p.draftEndTime);
            weight += escrowAmount;
        }
        // Fold the voter's staked VGC once (only stakes locked past the window).
        if (!dv.stakeCounted) {
            uint256 staked = _vgcStakedWeight(msg.sender, p.draftEndTime);
            if (staked > 0) {
                dv.stakeCounted = true;
                weight += staked;
            }
        }

        if (weight == 0) revert ZeroAmount(); // no escrow and no qualifying stake

        if (support) {
            p.vgcYes += weight; dv.yesAmount += weight;
            if (!p.premiumYesVgc && premiumRegistry.isPremium(msg.sender)) p.premiumYesVgc = true;
        } else {
            p.vgcNo += weight; dv.noAmount += weight;
        }
        dv.hasVoted = true;

        emit DraftVoteCast(proposalId, msg.sender, support, weight, p.vgcYes, p.vgcNo);
    }

    /**
     * @notice Sum a user's VSR-staked VGC that qualifies as Stage-1 weight.
     * @dev    Scans the user's asset stakes (0 .. nextAssetStakeId) and counts
     *         those that are active, whose asset is VGC, and whose `unlockTime`
     *         strictly outlasts the draft window — so the VGC stays locked in VSR
     *         for the whole vote and can't be withdrawn and re-cast elsewhere.
     *         The loop is over the caller's OWN stakes, so its gas is self-bounded.
     */
    function _vgcStakedWeight(address user, uint256 draftEndTime) internal view returns (uint256 total) {
        address vgc = address(vgcToken);
        uint256 n = stakingRouter.nextAssetStakeId(user);
        for (uint256 i = 0; i < n;) {
            (bool active, , address asset, uint64 unlockTime, uint256 principalAsset, ) =
                stakingRouter.assetStakes(user, i);
            if (active && asset == vgc && uint256(unlockTime) > draftEndTime) {
                total += principalAsset;
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Promote a passed draft → proposal. Anyone may call once the draft
     *         window has closed and the draft reached DraftSucceeded. Snapshots
     *         circulating VY and opens the VY voting window.
     */
    function promote(uint256 proposalId) external nonReentrant {
        ProposalCore storage p = proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalNotFound(proposalId);

        ProposalState cur = state(proposalId);
        if (cur != ProposalState.DraftSucceeded) revert InvalidState(proposalId, cur);

        uint256 circ = _circulatingVY();
        if (circ == 0) revert NoCirculatingVY();

        uint64 startTs = uint64(block.timestamp);
        uint64 endTs   = uint64(block.timestamp + VOTING_PERIOD);
        p.voteStartTime = startTs;
        p.voteEndTime   = endTs;
        p.circulatingVY = circ;

        emit ProposalPromoted(proposalId, startTs, endTs, circ);
    }

    // ====================================================================
    // STAGE 2 — PROPOSAL (VY chamber)
    // ====================================================================

    /**
     * @notice Vote YES on execution. Weight = `amount` of VY escrowed here PLUS
     *         (on the voter's first vote) their qualifying VSR-staked VY. Pass
     *         `amount = 0` to vote with the staked position alone.
     */
    function voteYes(uint256 proposalId, uint256 amount) external nonReentrant {
        _voteVy(proposalId, amount, true);
    }

    /**
     * @notice Vote NO on execution. Same weight rules as {voteYes}.
     */
    function voteNo(uint256 proposalId, uint256 amount) external nonReentrant {
        _voteVy(proposalId, amount, false);
    }

    /**
     * @param escrowAmount Liquid VY to escrow as weight (may be 0).
     * @dev   A voter's first vote also folds in their qualifying VSR stake; the
     *        chosen side is fixed for the proposal. The escrow and stake legs are
     *        each part of circulating VY and counted at most once, so they never
     *        double-count.
     */
    function _voteVy(uint256 proposalId, uint256 escrowAmount, bool support) internal {
        ProposalCore storage p = proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalNotFound(proposalId);

        ProposalState cur = state(proposalId);
        if (cur != ProposalState.Active) revert InvalidState(proposalId, cur);

        VoteVoter storage vv = voteVoter[proposalId][msg.sender];
        if (vv.hasVoted) {
            if ( support && vv.noAmount  > 0) revert CannotVoteBothSides(proposalId, msg.sender);
            if (!support && vv.yesAmount > 0) revert CannotVoteBothSides(proposalId, msg.sender);
        }

        uint256 weight = 0;

        // ── LIQUID leg: escrow VY into this contract (withdrawable post-window). ──
        if (escrowAmount > 0) {
            // Note: VY has a transfer fee. We rely on the governance contract
            // being VY-whitelisted (fee = 0) post-deployment, otherwise the
            // recorded weight will under-count vs. tokens debited. This is
            // enforced off-chain in the deployment pipeline (same as Executor).
            vyToken.safeTransferFrom(msg.sender, address(this), escrowAmount);
            _addVyLock(msg.sender, escrowAmount, p.voteEndTime);
            weight += escrowAmount;
        }

        // ── STAKED leg: fold in VSR-staked VY once, only stakes locked past the
        //    window (so the VY can't be withdrawn and re-voted elsewhere). ──
        if (!vv.stakeCounted) {
            uint256 staked = _vsrStakedWeight(msg.sender, p.voteEndTime);
            if (staked > 0) {
                vv.stakeCounted = true;
                weight += staked;
            }
        }

        if (weight == 0) revert ZeroAmount(); // no escrow and no qualifying stake

        if (support) {
            p.vyYes += weight; vv.yesAmount += weight;
            if (!p.premiumYesVy && premiumRegistry.isPremium(msg.sender)) p.premiumYesVy = true;
        } else {
            p.vyNo += weight; vv.noAmount += weight;
        }
        vv.hasVoted = true;

        emit VoteCast(proposalId, msg.sender, support, weight, p.vyYes, p.vyNo);
    }

    /**
     * @notice Sum a user's VSR-staked VY that qualifies as Stage-2 voting weight.
     * @dev    Only counts active slots whose `unlockTime` strictly outlasts the
     *         voting window — guaranteeing the VY stays locked in VSR for the
     *         whole vote and cannot be withdrawn and re-cast from another wallet.
     */
    function _vsrStakedWeight(address user, uint256 voteEndTime) internal view returns (uint256 total) {
        for (uint256 i = 0; i < 3;) {
            (bool active, , uint64 unlockTime, , , uint256 principalVY) = stakingRouter.stakes(user, i);
            if (active && uint256(unlockTime) > voteEndTime) {
                total += principalVY;
            }
            unchecked { ++i; }
        }
    }

    // ====================================================================
    // STAGE 3 — QUEUE + EXECUTE
    // ====================================================================

    function queue(
        uint256 proposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[]   calldata calldatas
    ) external nonReentrant {
        ProposalCore storage p = proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalNotFound(proposalId);

        ProposalState cur = state(proposalId);
        if (cur != ProposalState.Succeeded) revert InvalidState(proposalId, cur);

        bytes32 h = hashActions(targets, values, calldatas);
        if (h != p.actionsHash) revert InvalidActionsHash(p.actionsHash, h);

        p.queued = true;
        if (activeProposalId == proposalId) activeProposalId = 0;

        executor.schedule(targets, values, calldatas, bytes32(proposalId));

        emit ProposalQueued(proposalId, block.timestamp + executor.MIN_DELAY());
    }

    function execute(
        uint256 proposalId,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[]   calldata calldatas
    ) external payable nonReentrant {
        ProposalCore storage p = proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalNotFound(proposalId);

        ProposalState cur = state(proposalId);
        if (cur != ProposalState.Queued) revert InvalidState(proposalId, cur);

        bytes32 h = hashActions(targets, values, calldatas);
        if (h != p.actionsHash) revert InvalidActionsHash(p.actionsHash, h);

        p.executed = true;
        executor.execute{value: msg.value}(targets, values, calldatas, bytes32(proposalId));

        emit ProposalExecuted(proposalId);
    }

    // ====================================================================
    // Withdrawals
    // ====================================================================

    function withdrawVGC(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 unlockAt = vgcUnlockTime[msg.sender];
        if (block.timestamp < unlockAt) revert TokensStillLocked(unlockAt, block.timestamp);
        if (vgcLocked[msg.sender] < amount) revert InsufficientLocked(amount, vgcLocked[msg.sender]);

        vgcLocked[msg.sender] -= amount;
        vgcToken.safeTransfer(msg.sender, amount);
        emit VGCWithdrawn(msg.sender, amount);
    }

    function withdrawVY(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 unlockAt = vyUnlockTime[msg.sender];
        if (block.timestamp < unlockAt) revert TokensStillLocked(unlockAt, block.timestamp);
        if (vyLocked[msg.sender] < amount) revert InsufficientLocked(amount, vyLocked[msg.sender]);

        vyLocked[msg.sender] -= amount;
        vyToken.safeTransfer(msg.sender, amount);
        emit VYWithdrawn(msg.sender, amount);
    }

    // ====================================================================
    // State machine
    // ====================================================================

    function state(uint256 proposalId) public view returns (ProposalState) {
        ProposalCore storage p = proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalNotFound(proposalId);

        if (p.executed) return ProposalState.Executed;
        if (p.queued)   return ProposalState.Queued;

        // Stage 1 — not yet promoted.
        if (p.voteStartTime == 0) {
            if (block.timestamp <= p.draftEndTime) return ProposalState.Draft;
            if (!_draftPassed(p)) return ProposalState.DraftDefeated;
            // Passed the draft gates — promotable only within the promotion window.
            if (block.timestamp <= uint256(p.draftEndTime) + PROMOTION_PERIOD) {
                return ProposalState.DraftSucceeded;
            }
            return ProposalState.DraftDefeated;
        }

        // Stage 2 — promoted.
        if (block.timestamp <= p.voteEndTime) return ProposalState.Active;
        return _proposalPassed(p) ? ProposalState.Succeeded : ProposalState.Defeated;
    }

    /// @dev Stage-1 pass test: premium-YES gate + 50% quorum + 51% majority of cast.
    function _draftPassed(ProposalCore storage p) internal view returns (bool) {
        if (!p.premiumYesVgc) return false;
        uint256 cast = p.vgcYes + p.vgcNo;
        uint256 quorum = (p.vgcSnapshot * DRAFT_QUORUM_BPS) / BASIS_POINTS;
        if (cast < quorum) return false;
        return p.vgcYes * BASIS_POINTS >= cast * DRAFT_MAJORITY_BPS;
    }

    /// @dev Stage-2 pass test: premium-YES gate + 50% quorum + 70% supermajority of cast.
    function _proposalPassed(ProposalCore storage p) internal view returns (bool) {
        if (!p.premiumYesVy) return false;
        uint256 cast = p.vyYes + p.vyNo;
        uint256 quorum = (p.circulatingVY * VY_QUORUM_BPS) / BASIS_POINTS;
        if (cast < quorum) return false;
        return p.vyYes * BASIS_POINTS >= cast * VY_PASS_BPS;
    }

    // ====================================================================
    // Pure / view helpers
    // ====================================================================

    function hashActions(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[]   calldata calldatas
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(targets, values, calldatas));
    }

    function circulatingVY() external view returns (uint256) {
        return _circulatingVY();
    }

    function _circulatingVY() internal view returns (uint256) {
        uint256 supply = vyToken.totalSupply();
        uint256 inTreasuries = vyToken.balanceOf(vrt) + vyToken.balanceOf(vyt);
        if (inTreasuries >= supply) return 0;
        unchecked { return supply - inTreasuries; }
    }

    /// @notice VGC required to open a draft (1% of current VGC supply).
    function getDraftThreshold() external view returns (uint256) {
        return (vgcToken.totalSupply() * DRAFT_THRESHOLD_BPS) / BASIS_POINTS;
    }

    /// @notice VGC that must be cast (yes+no) for the Stage-1 quorum, for a given proposal.
    function getDraftQuorum(uint256 proposalId) external view returns (uint256) {
        return (proposals[proposalId].vgcSnapshot * DRAFT_QUORUM_BPS) / BASIS_POINTS;
    }

    /// @notice VY that must be cast (yes+no) for the Stage-2 quorum, for a given proposal.
    function getVyQuorum(uint256 proposalId) external view returns (uint256) {
        return (proposals[proposalId].circulatingVY * VY_QUORUM_BPS) / BASIS_POINTS;
    }

    /// @notice True if the proposal currently satisfies every Stage-1 gate.
    function draftPassed(uint256 proposalId) external view returns (bool) {
        ProposalCore storage p = proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalNotFound(proposalId);
        return _draftPassed(p);
    }

    /// @notice True if the proposal currently satisfies every Stage-2 gate.
    function proposalPassed(uint256 proposalId) external view returns (bool) {
        ProposalCore storage p = proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalNotFound(proposalId);
        return _proposalPassed(p);
    }

    // ====================================================================
    // Internal locking helpers
    // ====================================================================

    function _addVgcLock(address user, uint256 amount, uint256 deadline) internal {
        vgcLocked[user] += amount;
        if (vgcUnlockTime[user] < deadline) vgcUnlockTime[user] = deadline;
    }

    function _addVyLock(address user, uint256 amount, uint256 deadline) internal {
        vyLocked[user] += amount;
        if (vyUnlockTime[user] < deadline) vyUnlockTime[user] = deadline;
    }
}
