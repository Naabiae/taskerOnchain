// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRewardManager
 * @notice Interface for RewardManager — handles executor reward distribution
 * @dev V3: Works with UserVault instead of TaskVault. Called by ExecutorHub.
 */
interface IRewardManager {

    // ============ Structs ============

    struct RewardCalculation {
        uint256 executorReward;
        uint256 platformFee;
        uint256 gasReimbursement;
        uint256 totalFromVault;
    }

    // ============ Events ============

    event RewardDistributed(
        uint256 indexed automationId,
        address indexed executor,
        uint256 executorReward,
        uint256 platformFee,
        uint256 gasReimbursement
    );

    event PlatformFeeCollected(address indexed recipient, uint256 amount);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);

    // ============ Errors ============

    error OnlyExecutorHub();
    error InvalidFeePercentage();
    error InsufficientVaultBalance();

    // ============ Functions ============

    /// @notice Calculate reward breakdown
    function calculateReward(
        uint256 baseReward,
        address executor,
        uint256 gasUsed
    ) external view returns (RewardCalculation memory);

    /// @notice Distribute reward (called by ExecutorHub after automation execution)
    function distributeReward(
        address vault,
        address executor,
        uint256 baseReward,
        uint256 gasUsed
    ) external returns (uint256 totalPaid);

    /// @notice Collect accumulated platform fees
    function collectFees(address recipient) external returns (uint256 amount);

    /// @notice Set platform fee percentage
    function setPlatformFee(uint256 feePercentage) external;

    /// @notice Get platform fee percentage
    function getPlatformFeePercentage() external view returns (uint256);

    /// @notice Get total fees collected
    function totalFeesCollected() external view returns (uint256);

    /// @notice Get the global cap for gas reimbursement per execution
    function getMaxGasReimbursement() external view returns (uint256);
}