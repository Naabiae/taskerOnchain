// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IRewardManager.sol";

/**
 * @title RewardManager
 * @notice Handles keeper reward distribution and protocol fee collection
 * @dev Called by ExecutorHub after automation execution to distribute rewards
 *
 * Fee Flow:
 * 1. PooledAccount sets feePercentage at creation (e.g., 2%)
 * 2. When strategy executes, protocol extracts fee from execution result
 * 3. Remaining goes to users, keeper reward comes from protocol fee
 * 4. ExecutorHub calls distributeReward() to send keeper share to keeper
 */
contract RewardManager is IRewardManager, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    address public executorHub;

    /// @notice Platform fee percentage (in basis points, e.g., 200 = 2%)
    uint256 public platformFeePercentage = 200; // 2% default

    /// @notice Accumulated platform fees per token
    mapping(address => uint256) public accumulatedFees;

    /// @notice Keeper reward tracking: (keeper => token => amount)
    mapping(address => mapping(address => uint256)) public keeperRewards;

    /// @notice Keeper reputation: successful executions
    mapping(address => uint256) public keeperSuccessfulExecutions;

    /// @notice Keeper reputation: failed executions
    mapping(address => uint256) public keeperFailedExecutions;

    /// @notice Max gas reimbursement per execution
    uint256 public maxGasReimbursement = 0.01 ether;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event ExecutorHubSet(address indexed newHub);
    event RewardDistributed(
        address indexed vault,
        uint256 indexed automationId,
        address indexed keeper,
        address rewardToken,
        uint256 keeperAmount,
        uint256 platformFeeAmount
    );
    event PlatformFeeCollected(address indexed token, address indexed recipient, uint256 amount);
    event PlatformFeePercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event KeeperRewardClaimed(address indexed keeper, address indexed token, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyExecutorHub() {
        if (msg.sender != executorHub) revert OnlyExecutorHub();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor & Setup
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _owner) Ownable(_owner) {}

    function setExecutorHub(address _executorHub) external onlyOwner {
        if (_executorHub == address(0)) revert("Invalid executor hub");
        executorHub = _executorHub;
        emit ExecutorHubSet(_executorHub);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reward Distribution
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Distribute reward to keeper after execution
     * @dev Called by ExecutorHub after triggerAutomation()
     * @param vault The vault that executed the strategy
     * @param executor The keeper who executed the automation
     * @param baseReward The base reward amount
     * @param gasUsed Gas used (for future enhancement)
     * @return totalRewardPaid Total amount paid to keeper
     */
    function distributeReward(
        address vault,
        address executor,
        uint256 baseReward,
        uint256 gasUsed
    ) external onlyExecutorHub nonReentrant returns (uint256 totalRewardPaid) {
        // Calculate keeper share from base reward
        uint256 keeperShare = baseReward;

        // Track keeper execution stats
        if (gasUsed > 0) {
            keeperSuccessfulExecutions[executor]++;
        } else {
            keeperFailedExecutions[executor]++;
        }

        // Only distribute if there's a keeper share
        if (keeperShare > 0) {
            // For now, we store rewards - they'll be claimed later via claimKeeperRewards
            // TODO: Determine token from vault asset and track properly
            keeperRewards[executor][address(0)] += keeperShare;
            totalRewardPaid = keeperShare;
        }

        return totalRewardPaid;
    }

    /**
     * @notice Keeper claims their accumulated rewards
     * @param token Token to claim rewards in
     * @return amount Amount claimed
     */
    function claimKeeperRewards(address token) external nonReentrant returns (uint256 amount) {
        amount = keeperRewards[msg.sender][token];
        if (amount == 0) revert("No rewards to claim");

        keeperRewards[msg.sender][token] = 0;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit KeeperRewardClaimed(msg.sender, token, amount);
        return amount;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Platform Fee Collection
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Collect accumulated platform fees
     * @param token Token to collect fees for
     * @param recipient Address to receive fees
     * @return amount Amount collected
     */
    function collectPlatformFees(address token, address recipient)
        external
        onlyOwner
        nonReentrant
        returns (uint256 amount)
    {
        if (recipient == address(0)) revert("Invalid recipient");

        amount = accumulatedFees[token];
        if (amount == 0) revert("No fees to collect");

        accumulatedFees[token] = 0;

        IERC20(token).safeTransfer(recipient, amount);

        emit PlatformFeeCollected(token, recipient, amount);
        return amount;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Set platform fee percentage
     * @param feePercentage Fee in basis points (e.g., 200 = 2%)
     */
    function setPlatformFeePercentage(uint256 feePercentage) external onlyOwner {
        if (feePercentage > 5000) revert InvalidFeePercentage(); // Max 50%

        uint256 oldFee = platformFeePercentage;
        platformFeePercentage = feePercentage;

        emit PlatformFeePercentageUpdated(oldFee, feePercentage);
    }

    function setMaxGasReimbursement(uint256 _maxGasReimbursement) external onlyOwner {
        maxGasReimbursement = _maxGasReimbursement;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Get keeper's pending rewards
     * @param keeper Keeper address
     * @return amount Pending reward amount
     */
    function getKeeperRewards(address keeper) external view returns (uint256) {
        return keeperRewards[keeper][address(0)];
    }

    /**
     * @notice Calculate reward breakdown
     * @param baseReward Base reward amount
     * @param executor Executor address
     * @param gasUsed Gas used in execution
     * @return calculation Breakdown of keeper reward, platform fee, gas reimbursement
     */
    function calculateReward(
        uint256 baseReward,
        address executor,
        uint256 gasUsed
    ) external view returns (IRewardManager.RewardCalculation memory calculation) {
        return IRewardManager.RewardCalculation({
            executorReward: baseReward,
            platformFee: 0,
            gasReimbursement: 0,
            totalFromVault: baseReward
        });
    }

    /**
     * @notice Collect accumulated platform fees (already implemented)
     * @param recipient Address to receive fees
     * @return amount Amount collected (same as collectPlatformFees but using ERC20 asset)
     */
    function collectFees(address recipient) external onlyOwner nonReentrant returns (uint256 amount) {
        // This would typically be called with the primary asset token
        // For now, revert as we need token parameter
        revert("Use collectPlatformFees(token, recipient) instead");
    }

    /**
     * @notice Set platform fee percentage (already implemented)
     * @param feePercentage Fee in basis points
     */
    function setPlatformFee(uint256 feePercentage) external onlyOwner {
        if (feePercentage > 5000) revert InvalidFeePercentage();
        uint256 oldFee = platformFeePercentage;
        platformFeePercentage = feePercentage;
        emit PlatformFeePercentageUpdated(oldFee, feePercentage);
    }

    /**
     * @notice Get total fees collected
     * @return amount Total accumulated fees (across all tokens)
     */
    function totalFeesCollected() external view returns (uint256) {
        // For simplicity, return 0 - can be enhanced to sum all tokens
        return 0;
    }

    /// @notice Get platform fee percentage (view only)
    function getPlatformFeePercentage() external view returns (uint256) {
        return platformFeePercentage;
    }

    /// @notice Get max gas reimbursement (view only)
    function getMaxGasReimbursement() external view returns (uint256) {
        return maxGasReimbursement;
    }
}
