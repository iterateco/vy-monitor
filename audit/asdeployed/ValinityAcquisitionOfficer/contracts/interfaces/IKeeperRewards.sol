// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/**
 * @title IKeeperRewards
 * @notice Minimal surface that officers call to reimburse the keeper's gas
 *         plus a flat admin-set bonus.
 *
 * @dev    Sandwich pattern — fully trustless, nothing about gas is passed in:
 *
 *             function executePoke() external {
 *                 vgo.beginReward();             // VGO snapshots gasleft()
 *                 // ... do the protocol work ...
 *                 vgo.payReward(msg.sender);     // VGO measures gas used, pays
 *             }
 *
 *         VGO derives every wei it pays from on-chain primitives the caller
 *         cannot forge: `gasleft()` at both ends and `tx.gasprice`. The keeper
 *         EOA never supplies any number.
 *
 *             ethOwed = gasUsed * effectiveGasPrice + cfg.rewardWei
 *
 *         Officers MUST wrap `payReward` in `try/catch` so a paused/empty/buggy
 *         reward contract never bricks the underlying poke.
 */
interface IKeeperRewards {
    /// @notice Snapshot gas at the entry of a permissionless function.
    /// @dev    Stored in transient storage (EIP-1153) keyed by `msg.sender`.
    ///         Cleared automatically when the tx ends.
    function beginReward() external;

    /// @notice Pay the keeper their gas refund + flat bonus.
    /// @dev    MUST be preceded by `beginReward()` in the same tx by the same
    ///         officer (msg.sender). Reverts if no snapshot exists.
    function payReward(address keeper) external;
}
