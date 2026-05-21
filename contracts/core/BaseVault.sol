// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IStrategyAdapter.sol";
import "../interfaces/IExecutorHub.sol";

/**
 * @title BaseVault
 * @notice Shared execution engine for all vault types.
 *
 * BaseVault is abstract. It provides:
 * - Token tracking (which tokens vault holds)
 * - Strategy execution (approve → execute → revoke pattern)
 * - Automation state machine (create, trigger, cancel)
 * - Reentrancy protection
 *
 * Subclasses (via modules) implement:
 * - Access control (_canExecute, _canWithdraw)
 * - Accounting (single-owner, pooled shares, DAO voting)
 * - Permission hooks (_beforeExecution for spending rules, etc.)
 *
 * Subclasses should override:
 * - _canExecute(caller): who can execute strategies?
 * - _canWithdraw(caller): who can withdraw funds?
 * - _beforeExecution(caller, strategy, params): permission checks
 */
abstract contract BaseVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    enum AutomationStatus { ACTIVE, COMPLETED, CANCELLED }

    struct Automation {
        uint256 id;
        address strategy;
        bytes params;
        AutomationStatus status;
        uint256 createdAt;
        uint256 executionCount;
        uint256 lastExecutionTime;
        uint256 maxExecutions;
        string label;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    address public strategyRegistry;
    address public executorHub;

    // Token discovery
    address[] internal _heldTokens;
    mapping(address => bool) internal _isTracked;

    // Automations
    mapping(uint256 => Automation) internal _automations;
    uint256[] internal _automationIds;
    uint256 public nextAutomationId;

    // Replay protection
    uint256 public nonce;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event StrategyExecuted(address indexed strategy, bool success, uint256 nonce);
    event AutomationCreated(uint256 indexed id, address indexed strategy, string label);
    event AutomationTriggered(uint256 indexed id, bool success, uint256 executionCount);
    event AutomationCancelled(uint256 indexed id);
    event AutomationCompleted(uint256 indexed id);
    event AutomationUpdated(uint256 indexed id, bytes newParams);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotExecutorHub();
    error AutomationNotActive(uint256 id);
    error StrategyNotRegistered(address strategy);
    error InvalidParams(string reason);
    error InsufficientBalance(address token, uint256 needed);
    error TransferFailed();
    error ZeroAddress();
    error ZeroAmount();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyExecutorHub() {
        if (msg.sender != executorHub) revert NotExecutorHub();
        _;
    }

    modifier onlyRegistered(address strategy) {
        if (!IStrategyRegistry(strategyRegistry).isStrategyActive(strategy))
            revert StrategyNotRegistered(strategy);
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Abstract Hooks — Subclasses Override
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Subclass defines: who can execute strategies?
    function _canExecute(address caller) internal view virtual returns (bool);

    /// @notice Subclass defines: who can withdraw funds?
    function _canWithdraw(address caller) internal view virtual returns (bool);

    /// @notice Subclass defines: permission checks before execution
    /// @dev Called before every strategy execution. Throw if caller not allowed.
    function _beforeExecution(
        address caller,
        address strategy,
        bytes memory params
    ) internal virtual;

    // ─────────────────────────────────────────────────────────────────────────
    // Token Tracking
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Track a token if not already tracked
    function _trackToken(address token) internal {
        if (token == address(0)) return; // Skip ETH tracking
        if (_isTracked[token]) return;

        _isTracked[token] = true;
        _heldTokens.push(token);
    }

    function getHeldTokens() external view returns (address[] memory) {
        return _heldTokens;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Strategy Execution Core
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Execute a strategy immediately
    /// @dev Only callable by authorized callers. Subclass defines via _canExecute.
    function _executeStrategy(
        address strategy,
        uint256 value,
        bytes memory params
    ) internal returns (bool success, bytes memory result) {
        // Step 1: Get token requirements from adapter
        (address[] memory tokens, uint256[] memory amounts) =
            IStrategyAdapter(strategy).getTokenRequirements(params);

        // Step 2: Check balances and approve adapter
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(0) && amounts[i] > 0) {
                uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
                if (balance < amounts[i]) revert InsufficientBalance(tokens[i], amounts[i]);

                IERC20(tokens[i]).forceApprove(strategy, amounts[i]);
            }
        }

        // Step 3: Execute strategy (forward value for native ETH strategies)
        (success, result) = strategy.call{value: value}(
            abi.encodeWithSelector(IStrategyAdapter.execute.selector, address(this), params)
        );

        // Step 4: Revoke approvals
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(0) && amounts[i] > 0) {
                IERC20(tokens[i]).forceApprove(strategy, 0);
            }
        }

        // Step 5: Track output tokens
        for (uint256 i = 0; i < tokens.length; i++) {
            _trackToken(tokens[i]);
        }

        return (success, result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation Management (Internal Primitives)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Internal: Create automation
    function _createAutomation(
        address strategy,
        bytes calldata params,
        uint256 maxExecutions,
        string calldata label
    ) internal returns (uint256 automationId) {
        // Validate params early
        (bool valid, string memory err) = IStrategyAdapter(strategy).validateParams(params);
        if (!valid) revert InvalidParams(err);

        automationId = nextAutomationId++;

        _automations[automationId] = Automation({
            id: automationId,
            strategy: strategy,
            params: params,
            status: AutomationStatus.ACTIVE,
            createdAt: block.timestamp,
            executionCount: 0,
            lastExecutionTime: 0,
            maxExecutions: maxExecutions,
            label: label
        });

        _automationIds.push(automationId);

        // Register with ExecutorHub (defensive try/catch)
        try IExecutorHub(executorHub).registerTask(automationId, strategy, params) {} catch {}

        emit AutomationCreated(automationId, strategy, label);
    }

    /// @notice Internal: Trigger automation (called by ExecutorHub)
    function _triggerAutomation(uint256 automationId)
        internal
        returns (bool success)
    {
        Automation storage auto_ = _automations[automationId];
        if (auto_.status != AutomationStatus.ACTIVE) revert AutomationNotActive(automationId);

        // Check max executions
        if (auto_.maxExecutions > 0 && auto_.executionCount >= auto_.maxExecutions) {
            auto_.status = AutomationStatus.COMPLETED;
            try IExecutorHub(executorHub).removeTask(automationId) {} catch {}
            emit AutomationCompleted(automationId);
            return false;
        }

        // Check execution conditions
        (bool canExec, string memory reason) = IStrategyAdapter(auto_.strategy).canExecute(auto_.params);
        if (!canExec) revert InvalidParams(reason);

        // Execute
        (success,) = _executeStrategy(auto_.strategy, 0, auto_.params);

        // Update state
        auto_.executionCount++;
        auto_.lastExecutionTime = block.timestamp;

        if (auto_.maxExecutions > 0 && auto_.executionCount >= auto_.maxExecutions) {
            auto_.status = AutomationStatus.COMPLETED;
            try IExecutorHub(executorHub).removeTask(automationId) {} catch {}
            emit AutomationCompleted(automationId);
        }

        emit AutomationTriggered(automationId, success, auto_.executionCount);
    }

    /// @notice Internal: Cancel automation
    function _cancelAutomation(uint256 automationId) internal {
        Automation storage auto_ = _automations[automationId];
        if (auto_.status != AutomationStatus.ACTIVE) revert AutomationNotActive(automationId);

        auto_.status = AutomationStatus.CANCELLED;
        try IExecutorHub(executorHub).removeTask(automationId) {} catch {}

        emit AutomationCancelled(automationId);
    }

    /// @notice Internal: Update automation params
    function _updateAutomation(uint256 automationId, bytes calldata newParams) internal {
        Automation storage auto_ = _automations[automationId];
        if (auto_.status != AutomationStatus.ACTIVE) revert AutomationNotActive(automationId);

        // Validate new params
        (bool valid, string memory err) = IStrategyAdapter(auto_.strategy).validateParams(newParams);
        if (!valid) revert InvalidParams(err);

        auto_.params = newParams;
        try IExecutorHub(executorHub).updateTaskParams(automationId, newParams) {} catch {}

        emit AutomationUpdated(automationId, newParams);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation Management (Public Interface — Access Controlled)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Create automation (subclass controls access via _canExecute)
    function createAutomation(
        address strategy,
        bytes calldata params,
        uint256 maxExecutions,
        string calldata label
    )
        external
        onlyRegistered(strategy)
        returns (uint256 id)
    {
        require(_canExecute(msg.sender), "Not authorized");
        _beforeExecution(msg.sender, strategy, params);
        return _createAutomation(strategy, params, maxExecutions, label);
    }

    /// @notice Cancel automation (subclass controls access)
    function cancelAutomation(uint256 automationId) external {
        require(_canExecute(msg.sender), "Not authorized");
        _cancelAutomation(automationId);
    }

    /// @notice Update automation (subclass controls access)
    function updateAutomation(uint256 automationId, bytes calldata newParams) external {
        require(_canExecute(msg.sender), "Not authorized");
        _beforeExecution(msg.sender, _automations[automationId].strategy, newParams);
        _updateAutomation(automationId, newParams);
    }

    /// @notice Trigger automation (ExecutorHub only)
    function triggerAutomation(uint256 automationId)
        external
        onlyExecutorHub
        nonReentrant
        returns (bool)
    {
        return _triggerAutomation(automationId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────

    function getAutomation(uint256 id) external view returns (Automation memory) {
        return _automations[id];
    }

    function getAutomations() external view returns (Automation[] memory) {
        Automation[] memory result = new Automation[](_automationIds.length);
        for (uint256 i = 0; i < _automationIds.length; i++) {
            result[i] = _automations[_automationIds[i]];
        }
        return result;
    }

    function getExecutableAutomations() external view returns (Automation[] memory) {
        uint256 len = _automationIds.length;
        Automation[] memory temp = new Automation[](len);
        uint256 count = 0;

        for (uint256 i = 0; i < len; i++) {
            Automation storage auto_ = _automations[_automationIds[i]];
            if (auto_.status != AutomationStatus.ACTIVE) continue;

            try IStrategyAdapter(auto_.strategy).canExecute(auto_.params)
                returns (bool canExec, string memory)
            {
                if (canExec) {
                    temp[count] = auto_;
                    count++;
                }
            } catch {}
        }

        Automation[] memory result = new Automation[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Receive ETH
    // ─────────────────────────────────────────────────────────────────────────

    receive() external payable {}
}
