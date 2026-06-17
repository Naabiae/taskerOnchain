// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IRewardManager.sol";
import "../interfaces/IExecutorHub.sol";

/**
 * @title MockExecutorHub
 * @notice Test helper that forwards distributeReward calls to RewardManager.
 * @dev Allows testing RewardManager.distributeReward without modifying ExecutorHub.
 *      Also implements getExecutor so RewardManager.getReputationMultiplier works.
 *      Updated to match V5 IExecutorHub interface with Task struct.
 */
contract MockExecutorHub {
    function callDistributeReward(
        address rewardManager,
        address vault,
        address executor,
        uint256 baseReward,
        uint256 gasUsed
    ) external {
        IRewardManager(rewardManager).distributeReward(vault, executor, baseReward, gasUsed);
    }

    /// @notice Return a dummy executor for testing
    function getExecutor(address) external pure returns (IExecutorHub.Executor memory) {
        return IExecutorHub.Executor({
            addr: address(0),
            isActive: true,
            totalExecutions: 1,
            successfulExecutions: 1,
            failedExecutions: 0
        });
    }

    /// @notice Return a dummy isExecutor result
    function isExecutor(address) external pure returns (bool) {
        return true;
    }

    /// @notice No-op registerTask for testing
    function registerTask(uint256, address, bytes calldata) external pure {}

    /// @notice No-op removeTask for testing
    function removeTask(uint256) external pure {}

    /// @notice No-op updateTaskParams for testing
    function updateTaskParams(uint256, bytes calldata) external pure {}
}
