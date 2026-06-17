// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IExecutorHub
 * @notice Interface for ExecutorHub — push-based task registry with admin-managed executors.
 *
 * @dev V5 Architecture: Vaults register tasks directly via cross-contract calls.
 *      ExecutorHub maintains its own task list — no more polling vaults.
 *      Executors query getTasks()/getExecutableTasks() to discover work,
 *      then call executeAutomation() to trigger execution.
 */
interface IExecutorHub {

    // ============ Structs ============

    struct Executor {
        address addr;
        bool isActive;
        uint256 totalExecutions;
        uint256 successfulExecutions;
        uint256 failedExecutions;
    }

    struct Task {
        address vault;
        uint256 automationId;
        address strategy;
        bytes params;
        bool active;
    }

    // ============ Events ============

    event ExecutorAdded(address indexed executor);
    event ExecutorRemoved(address indexed executor);
    event TaskRegistered(address indexed vault, uint256 indexed automationId, address strategy);
    event TaskRemoved(address indexed vault, uint256 indexed automationId);
    event TaskParamsUpdated(address indexed vault, uint256 indexed automationId);
    event AutomationExecuted(
        address indexed vault,
        uint256 indexed automationId,
        address indexed executor,
        bool success
    );

    // ============ Errors ============

    error NotExecutor();
    error AlreadyExecutor();
    error NotActiveExecutor();
    error NotVault();
    error TaskAlreadyRegistered();
    error TaskNotFound();

    // ============ Admin Functions ============

    function addExecutor(address executor) external;
    function removeExecutor(address executor) external;

    // ============ Vault-Called Functions (cross-contract) ============

    /// @notice Register a task — called by UserVault.createAutomation()
    /// @dev msg.sender is used as the vault address (no spoofing possible)
    function registerTask(uint256 automationId, address strategy, bytes calldata params) external;

    /// @notice Remove a task — called by UserVault.cancelAutomation() or on completion
    /// @dev msg.sender is used as the vault address
    function removeTask(uint256 automationId) external;

    /// @notice Update task params — called by UserVault.updateAutomation()
    /// @dev msg.sender is used as the vault address
    function updateTaskParams(uint256 automationId, bytes calldata params) external;

    // ============ Executor Functions ============

    function executeAutomation(address vault, uint256 automationId) external;
    function executeAutomationBatch(address[] calldata vaults, uint256[] calldata automationIds) external;

    // ============ View Functions ============

    /// @notice Check if a specific task is ready for execution
    function canExecute(address vault, uint256 automationId) external view returns (bool canExec, string memory reason);

    /// @notice Get all registered tasks (active only)
    function getTasks() external view returns (Task[] memory);

    /// @notice Get all tasks for a specific vault
    function getTasksByVault(address vault) external view returns (Task[] memory);

    /// @notice Get all tasks that are currently executable (canExecute returns true)
    function getExecutableTasks() external view returns (Task[] memory);

    function isExecutor(address account) external view returns (bool);
    function getExecutor(address account) external view returns (Executor memory);
    function getTaskCount() external view returns (uint256);
}
