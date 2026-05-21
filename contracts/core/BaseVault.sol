// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IStrategyAdapter.sol";

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
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    address public strategyRegistry;
    address public executorHub;

    address[] internal _heldTokens;
    mapping(address => bool) internal _isTracked;

    mapping(uint256 => Automation) internal _automations;
    uint256[] internal _automationIds;
    uint256 public nextAutomationId;

    uint256 public nonce;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event StrategyExecuted(address indexed strategy, bool success, uint256 nonce);
    event AutomationCreated(uint256 indexed id, address indexed strategy);
    event AutomationTriggered(uint256 indexed id, bool success, uint256 executionCount);
    event AutomationCancelled(uint256 indexed id);
    event AutomationCompleted(uint256 indexed id);

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

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyExecutorHub() {
        if (msg.sender != executorHub) revert NotExecutorHub();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Abstract Hooks
    // ─────────────────────────────────────────────────────────────────────────

    function _canExecute(address caller) internal view virtual returns (bool);
    function _canWithdraw(address caller) internal view virtual returns (bool);
    function _beforeExecution(address caller, address strategy, bytes memory params) internal virtual;

    // ─────────────────────────────────────────────────────────────────────────
    // Token Tracking
    // ─────────────────────────────────────────────────────────────────────────

    function _trackToken(address token) internal {
        if (token == address(0)) return;
        if (_isTracked[token]) return;
        _isTracked[token] = true;
        _heldTokens.push(token);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Strategy Execution
    // ─────────────────────────────────────────────────────────────────────────

    function _executeStrategy(
        address strategy,
        uint256 value,
        bytes memory params
    ) internal returns (bool success, bytes memory result) {
        (address[] memory tokens, uint256[] memory amounts) =
            IStrategyAdapter(strategy).getTokenRequirements(params);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(0) && amounts[i] > 0) {
                uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
                if (balance < amounts[i]) revert InsufficientBalance(tokens[i], amounts[i]);
                IERC20(tokens[i]).forceApprove(strategy, amounts[i]);
            }
        }

        (success, result) = strategy.call{value: value}(
            abi.encodeWithSelector(IStrategyAdapter.execute.selector, address(this), params)
        );

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(0) && amounts[i] > 0) {
                IERC20(tokens[i]).forceApprove(strategy, 0);
            }
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            _trackToken(tokens[i]);
        }

        return (success, result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation Management
    // ─────────────────────────────────────────────────────────────────────────

    function _createAutomation(
        address strategy,
        bytes calldata params,
        uint256 maxExecutions
    ) internal returns (uint256 automationId) {
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
            maxExecutions: maxExecutions
        });

        _automationIds.push(automationId);

        try IExecutorHub(executorHub).registerTask(automationId, strategy, params) {} catch {}

        emit AutomationCreated(automationId, strategy);
    }

    function _triggerAutomation(uint256 automationId) internal returns (bool success) {
        Automation storage auto_ = _automations[automationId];
        if (auto_.status != AutomationStatus.ACTIVE) revert AutomationNotActive(automationId);

        if (auto_.maxExecutions > 0 && auto_.executionCount >= auto_.maxExecutions) {
            auto_.status = AutomationStatus.COMPLETED;
            try IExecutorHub(executorHub).removeTask(automationId) {} catch {}
            emit AutomationCompleted(automationId);
            return false;
        }

        (bool canExec, string memory reason) = IStrategyAdapter(auto_.strategy).canExecute(auto_.params);
        if (!canExec) revert InvalidParams(reason);

        (success,) = _executeStrategy(auto_.strategy, 0, auto_.params);

        auto_.executionCount++;
        auto_.lastExecutionTime = block.timestamp;

        if (auto_.maxExecutions > 0 && auto_.executionCount >= auto_.maxExecutions) {
            auto_.status = AutomationStatus.COMPLETED;
            try IExecutorHub(executorHub).removeTask(automationId) {} catch {}
            emit AutomationCompleted(automationId);
        }

        emit AutomationTriggered(automationId, success, auto_.executionCount);
    }

    function _cancelAutomation(uint256 automationId) internal {
        Automation storage auto_ = _automations[automationId];
        if (auto_.status != AutomationStatus.ACTIVE) revert AutomationNotActive(automationId);
        auto_.status = AutomationStatus.CANCELLED;
        try IExecutorHub(executorHub).removeTask(automationId) {} catch {}
        emit AutomationCancelled(automationId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Public Interface
    // ─────────────────────────────────────────────────────────────────────────

    function createAutomation(
        address strategy,
        bytes calldata params,
        uint256 maxExecutions
    ) external returns (uint256 id) {
        require(_canExecute(msg.sender), "Not authorized");
        _beforeExecution(msg.sender, strategy, params);
        return _createAutomation(strategy, params, maxExecutions);
    }

    function cancelAutomation(uint256 automationId) external {
        require(_canExecute(msg.sender), "Not authorized");
        _cancelAutomation(automationId);
    }

    function triggerAutomation(uint256 automationId)
        external
        onlyExecutorHub
        nonReentrant
        returns (bool)
    {
        return _triggerAutomation(automationId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
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

    receive() external payable {}
}

interface IExecutorHub {
    function registerTask(uint256 id, address strategy, bytes calldata params) external;
    function removeTask(uint256 id) external;
}
