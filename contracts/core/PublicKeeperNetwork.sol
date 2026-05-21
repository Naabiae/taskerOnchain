// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IExecutorHub.sol";

/**
 * @title PublicKeeperNetwork
 * @notice Permissionless keeper network for executing SmartAccount automations.
 *
 * THIS IS THE EXECUTION LAYER.
 *
 * How it works:
 * 1. Anyone can register as a keeper (no permission needed, just stake)
 * 2. Keepers discover automations via getExecutableTasks()
 * 3. Keeper calls executeAutomation(vault, automationId)
 * 4. SmartAccount executes the automation
 * 5. Keeper earns reward from vault's native balance (ETH/ARB)
 *
 * Reputation System:
 * - Each keeper has a reputation score (successful executions / total executions)
 * - High reputation keepers earn higher rewards (reward multiplier)
 * - Low reputation keepers face timeouts (fail 3 times → 1 day lockout)
 *
 * Stake Requirement:
 * - Register as keeper: must lock 1 ARB
 * - Slashing: none (but reputation degrades on failures)
 * - Unstaking: anytime (no timelock)
 *
 * Reward Model:
 * - Base reward: configurable (e.g., 0.0001 ETH per execution)
 * - Reputation bonus: +10% per 10% reputation (max 20% bonus at 100% success)
 * - Gas reimbursement: up to 0.002 ETH (tracked during execution)
 *
 * Key Property:
 * - Execution is permissionless (anyone can execute)
 * - Rewards are paid from vault (no protocol subsidy)
 * - No custody risk (keepers never control funds)
 * - Keeper failure = automation doesn't execute, try again next block
 *
 * This is the "decentralized automation backbone":
 * - Multiple independent keepers (no single point of failure)
 * - Economic incentives (earn reward per execution)
 * - Transparent reputation (on-chain success rate)
 * - Scalable (keeper network load grows with TVL, not linearly)
 */
contract PublicKeeperNetwork is ReentrancyGuard {

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    struct Keeper {
        address addr;
        bool active;
        uint256 totalExecutions;
        uint256 successfulExecutions;
        uint256 failedExecutions;
        uint256 stakeAmount;
        uint256 registeredAt;
        uint256 reputationScore;  // 0-10000 (0% to 100%)
        uint256 lastFailureTime;
        uint256 consecutiveFailures;
    }

    struct Task {
        address vault;
        uint256 automationId;
        address strategy;
        bytes params;
        bool active;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    address public owner;

    // Keepers
    mapping(address => Keeper) public keepers;
    address[] public keeperList;
    mapping(address => uint256) public keeperIndex;

    // Tasks (same as ExecutorHub)
    struct TaskKey {
        address vault;
        uint256 automationId;
    }

    mapping(address => mapping(uint256 => Task)) private _tasks;
    TaskKey[] private _taskKeys;
    mapping(address => mapping(uint256 => uint256)) private _taskIndex;

    // Configuration
    uint256 public minStakeAmount = 1 ether;  // 1 ARB (adjustable)
    uint256 public baseRewardPerExecution = 0.0001 ether;
    uint256 public gasReimbursementMultiplier = 120;  // 1.2x actual gas cost
    uint256 public maxGasReimbursement = 0.002 ether;
    uint256 public lockoutDuration = 1 days;  // Timeout after 3 consecutive failures
    uint256 public constant BASE_REPUTATION = 5000;  // 50% reputation baseline
    uint256 public constant MAX_REPUTATION_MULTIPLIER = 12500;  // Max 1.25x reward

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event KeeperRegistered(address indexed keeper, uint256 stakeAmount);
    event KeeperUnstaked(address indexed keeper, uint256 amount);
    event AutomationExecuted(
        address indexed vault,
        uint256 automationId,
        address indexed keeper,
        bool success,
        uint256 reward
    );
    event ReputationUpdated(address indexed keeper, uint256 newScore);
    event TaskRegistered(address indexed vault, uint256 automationId);
    event TaskRemoved(address indexed vault, uint256 automationId);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotKeeper();
    error NotOwner();
    error InsufficientStake(uint256 sent, uint256 required);
    error KeeperLocked(uint256 unlockTime);
    error TaskNotFound();
    error InvalidVault();
    error InvalidTask();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyKeeper() {
        if (!keepers[msg.sender].active) revert NotKeeper();

        // Check if keeper is in lockout
        Keeper storage keeper = keepers[msg.sender];
        if (keeper.consecutiveFailures >= 3) {
            if (block.timestamp < keeper.lastFailureTime + lockoutDuration) {
                revert KeeperLocked(keeper.lastFailureTime + lockoutDuration);
            } else {
                // Lockout expired, reset
                keeper.consecutiveFailures = 0;
            }
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _owner) {
        owner = _owner;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Keeper Registration (Permissionless)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Register as a keeper (requires stake)
    function registerAsKeeper() external payable {
        if (msg.value < minStakeAmount) revert InsufficientStake(msg.value, minStakeAmount);
        if (keepers[msg.sender].active) revert("Already registered");

        keepers[msg.sender] = Keeper({
            addr: msg.sender,
            active: true,
            totalExecutions: 0,
            successfulExecutions: 0,
            failedExecutions: 0,
            stakeAmount: msg.value,
            registeredAt: block.timestamp,
            reputationScore: BASE_REPUTATION,
            lastFailureTime: 0,
            consecutiveFailures: 0
        });

        keeperIndex[msg.sender] = keeperList.length;
        keeperList.push(msg.sender);

        emit KeeperRegistered(msg.sender, msg.value);
    }

    /// @notice Unstake and deregister as keeper
    function unstake() external {
        if (!keepers[msg.sender].active) revert NotKeeper();

        Keeper storage keeper = keepers[msg.sender];
        uint256 stake = keeper.stakeAmount;

        // Deactivate
        keeper.active = false;

        // Return stake
        (bool ok,) = msg.sender.call{value: stake}("");
        require(ok, "Unstake failed");

        // Remove from list
        uint256 index = keeperIndex[msg.sender];
        uint256 lastIndex = keeperList.length - 1;
        if (index != lastIndex) {
            address lastKeeper = keeperList[lastIndex];
            keeperList[index] = lastKeeper;
            keeperIndex[lastKeeper] = index;
        }
        keeperList.pop();
        delete keeperIndex[msg.sender];

        emit KeeperUnstaked(msg.sender, stake);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Task Management (Called by SmartAccount)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Register task (called by SmartAccount when automation is created)
    function registerTask(
        uint256 automationId,
        address strategy,
        bytes calldata params
    ) external {
        address vault = msg.sender;
        if (vault == address(0)) revert InvalidVault();

        if (_taskIndex[vault][automationId] != 0) revert("Task already registered");

        _tasks[vault][automationId] = Task({
            vault: vault,
            automationId: automationId,
            strategy: strategy,
            params: params,
            active: true
        });

        _taskIndex[vault][automationId] = _taskKeys.length + 1;
        _taskKeys.push(TaskKey({ vault: vault, automationId: automationId }));

        emit TaskRegistered(vault, automationId);
    }

    /// @notice Remove task (called by SmartAccount when automation is cancelled)
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

    /// @notice Update task params (called by SmartAccount when automation is updated)
    function updateTaskParams(uint256 automationId, bytes calldata params) external {
        address vault = msg.sender;
        if (_taskIndex[vault][automationId] == 0) revert TaskNotFound();

        _tasks[vault][automationId].params = params;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Keeper Execution (The Core Loop)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Execute a single automation (keeper calls this)
    function executeAutomation(address vault, uint256 automationId)
        external
        onlyKeeper
        nonReentrant
    {
        if (vault == address(0)) revert InvalidVault();

        Keeper storage keeper = keepers[msg.sender];
        keeper.totalExecutions++;

        uint256 gasBefore = gasleft();

        // Call SmartAccount to trigger automation
        try ISmartAccount(vault).triggerAutomation(automationId) returns (bool success) {
            uint256 gasUsed = gasBefore - gasleft();

            if (success) {
                keeper.successfulExecutions++;
                keeper.consecutiveFailures = 0;

                // Calculate reward
                uint256 reward = _calculateReward(keeper, gasUsed);

                // Pay keeper from vault
                (bool ok,) = msg.sender.call{value: reward}("");
                if (ok) {
                    emit AutomationExecuted(vault, automationId, msg.sender, true, reward);
                }
            } else {
                keeper.failedExecutions++;
                keeper.lastFailureTime = block.timestamp;
                keeper.consecutiveFailures++;

                // Degrade reputation on failure
                _updateReputation(msg.sender, false);

                emit AutomationExecuted(vault, automationId, msg.sender, false, 0);
            }
        } catch {
            keeper.failedExecutions++;
            keeper.lastFailureTime = block.timestamp;
            keeper.consecutiveFailures++;

            _updateReputation(msg.sender, false);

            emit AutomationExecuted(vault, automationId, msg.sender, false, 0);
        }
    }

    /// @notice Execute batch of automations (keeper optimizes gas)
    function executeAutomationBatch(
        address[] calldata vaults,
        uint256[] calldata automationIds
    ) external onlyKeeper nonReentrant {
        require(vaults.length == automationIds.length, "Length mismatch");

        Keeper storage keeper = keepers[msg.sender];

        for (uint256 i = 0; i < vaults.length; i++) {
            require(vaults[i] != address(0), "Invalid vault");

            keeper.totalExecutions++;

            uint256 gasBefore = gasleft();

            try ISmartAccount(vaults[i]).triggerAutomation(automationIds[i]) returns (bool success) {
                uint256 gasUsed = gasBefore - gasleft();

                if (success) {
                    keeper.successfulExecutions++;
                    keeper.consecutiveFailures = 0;

                    uint256 reward = _calculateReward(keeper, gasUsed);
                    (bool ok,) = msg.sender.call{value: reward}("");
                    if (ok) {
                        emit AutomationExecuted(vaults[i], automationIds[i], msg.sender, true, reward);
                    }
                } else {
                    keeper.failedExecutions++;
                    keeper.lastFailureTime = block.timestamp;
                    keeper.consecutiveFailures++;
                    _updateReputation(msg.sender, false);
                    emit AutomationExecuted(vaults[i], automationIds[i], msg.sender, false, 0);
                }
            } catch {
                keeper.failedExecutions++;
                keeper.lastFailureTime = block.timestamp;
                keeper.consecutiveFailures++;
                _updateReputation(msg.sender, false);
                emit AutomationExecuted(vaults[i], automationIds[i], msg.sender, false, 0);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reputation & Reward Calculation
    // ─────────────────────────────────────────────────────────────────────────

    function _calculateReward(Keeper storage keeper, uint256 gasUsed)
        internal
        view
        returns (uint256)
    {
        // Base reward
        uint256 reward = baseRewardPerExecution;

        // Gas reimbursement (up to max)
        uint256 gasReimburse = (gasUsed * gasReimbursementMultiplier) / 100;
        if (gasReimburse > maxGasReimbursement) gasReimburse = maxGasReimbursement;
        reward += gasReimburse;

        // Reputation multiplier (5000-12500 = 0.5x to 1.25x)
        uint256 multiplier = keeper.reputationScore;
        if (multiplier > MAX_REPUTATION_MULTIPLIER) multiplier = MAX_REPUTATION_MULTIPLIER;
        reward = (reward * multiplier) / 10000;

        return reward;
    }

    function _updateReputation(address keeper, bool success) internal {
        Keeper storage k = keepers[keeper];

        if (success) {
            // Increase reputation toward 100% (10000)
            k.reputationScore = (k.reputationScore * 105) / 100;  // +5%
            if (k.reputationScore > 10000) k.reputationScore = 10000;
        } else {
            // Decrease reputation toward 50% (5000)
            k.reputationScore = (k.reputationScore * 95) / 100;  // -5%
            if (k.reputationScore < BASE_REPUTATION) k.reputationScore = BASE_REPUTATION;
        }

        emit ReputationUpdated(keeper, k.reputationScore);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Keeper Discovery (Keepers find work here)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Get all tasks (keeper discovery)
    function getTasks() external view returns (Task[] memory) {
        Task[] memory result = new Task[](_taskKeys.length);
        for (uint256 i = 0; i < _taskKeys.length; i++) {
            TaskKey memory key = _taskKeys[i];
            result[i] = _tasks[key.vault][key.automationId];
        }
        return result;
    }

    /// @notice Get executable tasks (keeper calls this to find work)
    function getExecutableTasks() external view returns (Task[] memory) {
        uint256 len = _taskKeys.length;
        Task[] memory temp = new Task[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; i++) {
            TaskKey storage key = _taskKeys[i];
            Task storage task = _tasks[key.vault][key.automationId];
            if (!task.active) continue;

            // Check if SmartAccount says task is executable
            try ISmartAccount(task.vault).canExecuteAutomation(task.automationId)
                returns (bool canExec, string memory)
            {
                if (canExec) {
                    temp[count] = task;
                    count++;
                }
            } catch {}
        }

        Task[] memory result = new Task[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────

    function getKeeper(address keeper) external view returns (Keeper memory) {
        return keepers[keeper];
    }

    function getAllKeepers() external view returns (address[] memory) {
        return keeperList;
    }

    function getKeeperCount() external view returns (uint256) {
        return keeperList.length;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function setMinStake(uint256 newMinStake) external onlyOwner {
        minStakeAmount = newMinStake;
    }

    function setBaseReward(uint256 newReward) external onlyOwner {
        baseRewardPerExecution = newReward;
    }

    function setGasMultiplier(uint256 newMultiplier) external onlyOwner {
        gasReimbursementMultiplier = newMultiplier;
    }

    receive() external payable {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Interfaces
// ─────────────────────────────────────────────────────────────────────────────

interface ISmartAccount {
    function triggerAutomation(uint256 automationId) external returns (bool);
    function canExecuteAutomation(uint256 automationId) external view returns (bool, string memory);
}
