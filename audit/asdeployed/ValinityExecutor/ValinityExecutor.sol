// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/**
 * @title ValinityExecutor
 * @notice Timelock executor for governance-approved operations
 * @dev Key properties:
 * - MIN_DELAY is hardcoded and immutable (7 days)
 * - Non-upgradeable
 * - Only Governance can schedule (PROPOSER_ROLE)
 * - Anyone can execute once ready (EXECUTOR_ROLE = address(0))
 * - No canceller role
 * - No external admin role
 * - Must be the admin/owner of all governed contracts
 */
contract ValinityExecutor {
    // ============================================================
    // Constants (Immutable)
    // ============================================================

    /// @notice Minimum delay before a scheduled operation can execute
    ///         (hardcoded, immutable). 7 days gives the protocol a full week to
    ///         react to — and, off-chain, scrutinize — any approved batch.
    uint256 public constant MIN_DELAY = 7 days;

    /// @notice Role identifier for proposers (only Governance contract)
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

    // ============================================================
    // State
    // ============================================================

    /// @notice Timestamp when operation becomes executable
    mapping(bytes32 => uint256) public readyAt;

    /// @notice Whether operation has been executed
    mapping(bytes32 => bool) public executed;

    /// @notice Addresses with PROPOSER_ROLE
    mapping(address => bool) public isProposer;

    // ============================================================
    // Events
    // ============================================================

    event OperationScheduled(
        bytes32 indexed operationId,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        bytes32 salt,
        uint256 readyAt
    );

    event OperationExecuted(bytes32 indexed operationId);

    event ProposerGranted(address indexed account);

    // ============================================================
    // Errors
    // ============================================================

    error NotProposer();
    error OperationAlreadyScheduled(bytes32 operationId);
    error OperationNotScheduled(bytes32 operationId);
    error OperationNotReady(bytes32 operationId, uint256 readyAt, uint256 currentTime);
    error OperationAlreadyExecuted(bytes32 operationId);
    error ArrayLengthMismatch();
    error CallFailed(uint256 index, bytes returnData);
    error ZeroAddress();

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyProposer() {
        if (!isProposer[msg.sender]) revert NotProposer();
        _;
    }

    // ============================================================
    // Constructor
    // ============================================================

    /**
     * @notice Initializes the executor with the governance contract as proposer
     * @param governance Address of ValinityGovernanceOfficer contract
     * @dev After deployment:
     *      - governance is the only proposer
     *      - anyone can execute once delay passes
     *      - no admin can modify anything
     */
    constructor(address governance) {
        if (governance == address(0)) revert ZeroAddress();
        isProposer[governance] = true;
        emit ProposerGranted(governance);
    }

    // ============================================================
    // External Functions
    // ============================================================

    /**
     * @notice Schedule a batch of operations
     * @param targets Contract addresses to call
     * @param values ETH amounts for each call
     * @param calldatas Encoded function calls
     * @param salt Unique identifier (typically proposalId as bytes32)
     * @dev Only callable by Governance contract (PROPOSER_ROLE)
     */
    function schedule(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt
    ) external onlyProposer {
        if (targets.length != values.length || targets.length != calldatas.length) {
            revert ArrayLengthMismatch();
        }

        bytes32 operationId = hashOperation(targets, values, calldatas, salt);

        if (readyAt[operationId] != 0) {
            revert OperationAlreadyScheduled(operationId);
        }

        uint256 executeAt = block.timestamp + MIN_DELAY;
        readyAt[operationId] = executeAt;

        emit OperationScheduled(operationId, targets, values, calldatas, salt, executeAt);
    }

    /**
     * @notice Execute a scheduled batch of operations
     * @param targets Contract addresses to call
     * @param values ETH amounts for each call
     * @param calldatas Encoded function calls
     * @param salt Unique identifier (must match schedule)
     * @dev Anyone can call once operation is ready
     *      Execution is atomic - all calls must succeed or all revert
     */
    function execute(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt
    ) external payable {
        bytes32 operationId = hashOperation(targets, values, calldatas, salt);

        if (readyAt[operationId] == 0) {
            revert OperationNotScheduled(operationId);
        }

        if (block.timestamp < readyAt[operationId]) {
            revert OperationNotReady(operationId, readyAt[operationId], block.timestamp);
        }

        if (executed[operationId]) {
            revert OperationAlreadyExecuted(operationId);
        }

        // Mark as executed BEFORE making external calls (reentrancy protection)
        executed[operationId] = true;

        // Execute all calls atomically
        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, bytes memory returnData) = targets[i].call{value: values[i]}(
                calldatas[i]
            );
            if (!success) {
                revert CallFailed(i, returnData);
            }
        }

        emit OperationExecuted(operationId);
    }

    // ============================================================
    // View Functions
    // ============================================================

    /**
     * @notice Compute the operation ID for a batch
     * @param targets Contract addresses
     * @param values ETH amounts
     * @param calldatas Encoded function calls
     * @param salt Unique identifier
     * @return operationId Hash identifying this operation
     */
    function hashOperation(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(targets, values, calldatas, salt));
    }

    /**
     * @notice Check if an operation is pending (scheduled but not executed)
     * @param operationId The operation hash
     * @return True if scheduled and not executed
     */
    function isOperationPending(bytes32 operationId) external view returns (bool) {
        return readyAt[operationId] != 0 && !executed[operationId];
    }

    /**
     * @notice Check if an operation is ready for execution
     * @param operationId The operation hash
     * @return True if ready to execute
     */
    function isOperationReady(bytes32 operationId) external view returns (bool) {
        return readyAt[operationId] != 0 && 
               block.timestamp >= readyAt[operationId] && 
               !executed[operationId];
    }

    /**
     * @notice Check if an operation has been executed
     * @param operationId The operation hash
     * @return True if executed
     */
    function isOperationDone(bytes32 operationId) external view returns (bool) {
        return executed[operationId];
    }

    // ============================================================
    // Receive ETH (for operations that need to send ETH)
    // ============================================================

    receive() external payable {}
}
