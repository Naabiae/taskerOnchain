// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ExecutorHub is Ownable, ReentrancyGuard {

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

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

    struct TaskKey {
        address vault;
        uint256 automationId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    mapping(address => Executor) public executors;
    address[] public executorList;
    mapping(address => uint256) public executorIndex;

    mapping(address => mapping(uint256 => Task)) private _tasks;
    TaskKey[] private _taskKeys;
    mapping(address => mapping(uint256 => uint256)) private _taskIndex;

    address public rewardManager;
    uint256 public baseRewardPerExecution = 0.0001 ether;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event ExecutorAdded(address indexed executor);
    event ExecutorRemoved(address indexed executor);
    event TaskRegistered(address indexed vault, uint256 automationId, address strategy);
    event TaskRemoved(address indexed vault, uint256 automationId);
    event AutomationExecuted(address indexed vault, uint256 automationId, address indexed executor, bool success);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotExecutor();
    error AlreadyExecutor();
    error NotActiveExecutor();
    error TaskAlreadyRegistered();
    error TaskNotFound();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyExecutor() {
        if (!executors[msg.sender].isActive) revert NotExecutor();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _owner) Ownable(_owner) {}

    // ─────────────────────────────────────────────────────────────────────────
    // Executor Management (Admin)
    // ─────────────────────────────────────────────────────────────────────────

    function addExecutor(address executor) external onlyOwner {
        if (executor == address(0)) revert("Invalid executor");
        if (executors[executor].isActive) revert AlreadyExecutor();

        executors[executor] = Executor({
            addr: executor,
            isActive: true,
            totalExecutions: 0,
            successfulExecutions: 0,
            failedExecutions: 0
        });

        executorIndex[executor] = executorList.length;
        executorList.push(executor);

        emit ExecutorAdded(executor);
    }

    function removeExecutor(address executor) external onlyOwner {
        if (!executors[executor].isActive) revert NotActiveExecutor();

        executors[executor].isActive = false;

        uint256 index = executorIndex[executor];
        uint256 lastIndex = executorList.length - 1;
        if (index != lastIndex) {
            address lastExecutor = executorList[lastIndex];
            executorList[index] = lastExecutor;
            executorIndex[lastExecutor] = index;
        }
        executorList.pop();
        delete executorIndex[executor];

        emit ExecutorRemoved(executor);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task Management (Called by Vault)
    // ─────────────────────────────────────────────────────────────────────────

    function registerTask(uint256 automationId, address strategy, bytes calldata params) external {
        address vault = msg.sender;

        if (_taskIndex[vault][automationId] != 0) revert TaskAlreadyRegistered();

        _tasks[vault][automationId] = Task({
            vault: vault,
            automationId: automationId,
            strategy: strategy,
            params: params,
            active: true
        });

        _taskIndex[vault][automationId] = _taskKeys.length + 1;
        _taskKeys.push(TaskKey({ vault: vault, automationId: automationId }));

        emit TaskRegistered(vault, automationId, strategy);
    }

    function removeTask(uint256 automationId) external {
        address vault = msg.sender;

        if (_taskIndex[vault][automationId] == 0) revert TaskNotFound();

        _tasks[vault][automationId].active = false;

        uint256 index = _taskIndex[vault][automationId] - 1;
        uint256 lastIndex = _taskKeys.length - 1;

        if (index != lastIndex) {
            TaskKey memory lastKey = _taskKeys[lastIndex];
            _taskKeys[index] = lastKey;
            _taskIndex[lastKey.vault][lastKey.automationId] = index + 1;
        }
        _taskKeys.pop();

        delete _taskIndex[vault][automationId];
        delete _tasks[vault][automationId];

        emit TaskRemoved(vault, automationId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Executor Calls
    // ─────────────────────────────────────────────────────────────────────────

    function executeAutomation(address vault, uint256 automationId)
        external
        onlyExecutor
        nonReentrant
    {
        require(vault != address(0), "Invalid vault");

        Executor storage executor = executors[msg.sender];
        executor.totalExecutions++;

        bool success = IVault(vault).triggerAutomation(automationId);

        if (success) {
            executor.successfulExecutions++;
        } else {
            executor.failedExecutions++;
        }

        emit AutomationExecuted(vault, automationId, msg.sender, success);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    function getTasks() external view returns (Task[] memory) {
        Task[] memory result = new Task[](_taskKeys.length);
        for (uint256 i = 0; i < _taskKeys.length; i++) {
            TaskKey memory key = _taskKeys[i];
            result[i] = _tasks[key.vault][key.automationId];
        }
        return result;
    }

    function getExecutor(address account) external view returns (Executor memory) {
        return executors[account];
    }

    function isExecutor(address account) external view returns (bool) {
        return executors[account].isActive;
    }

    function getAllExecutors() external view returns (address[] memory) {
        return executorList;
    }
}

interface IVault {
    function triggerAutomation(uint256 id) external returns (bool);
}
