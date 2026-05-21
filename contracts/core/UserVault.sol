// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseVault.sol";
import "../modules/SingleOwnerModule.sol";

/**
 * @title UserVault
 * @notice Single-owner vault with AI operator permissions.
 *
 * Composition:
 * - BaseVault: execution engine
 * - SingleOwnerModule: owner + operators + spending rules
 *
 * Owner: full control (create, execute, withdraw)
 * Operator: limited control (execute + create/update automations, subject to spending rules)
 */
contract UserVault is BaseVault, SingleOwnerModule {
    
    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address _owner,
        address _strategyRegistry,
        address _executorHub
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_strategyRegistry == address(0)) revert ZeroAddress();
        if (_executorHub == address(0)) revert ZeroAddress();

        owner = _owner;
        strategyRegistry = _strategyRegistry;
        executorHub = _executorHub;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Public Interface — Owner and Operator
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Execute a strategy immediately
    /// @dev Owner: unrestricted. Operator: must have canExecuteImmediate + spending rules
    function execute(
        address strategy,
        uint256 value,
        bytes calldata params
    )
        external
        onlyRegistered(strategy)
        nonReentrant
        returns (bool success, bytes memory result)
    {
        // Check permissions
        if (msg.sender != owner) {
            if (!_operators[msg.sender].canExecuteImmediate)
                revert OperatorNotPermitted(msg.sender, "execute");
        }

        // Owner bypasses spending checks
        _beforeExecution(msg.sender, strategy, params);

        nonce++;
        (success, result) = _executeStrategy(strategy, value, params);
        emit StrategyExecuted(strategy, success, nonce);
    }

    /// @notice Execute multiple strategies atomically
    function executeBatch(
        Call[] calldata calls
    )
        external
        nonReentrant
        returns (bool[] memory successes)
    {
        // Check permissions
        if (msg.sender != owner) {
            if (!_operators[msg.sender].canExecuteImmediate)
                revert OperatorNotPermitted(msg.sender, "executeBatch");
        }

        successes = new bool[](calls.length);
        nonce++;

        for (uint256 i = 0; i < calls.length; i++) {
            address strategy = calls[i].strategy;
            if (!strategyRegistry.isStrategyActive(strategy))
                revert StrategyNotRegistered(strategy);

            // Check spending rules for operators
            if (msg.sender != owner) {
                _beforeExecution(msg.sender, strategy, calls[i].params);
            }

            (bool ok, bytes memory result) = _executeStrategy(
                strategy,
                calls[i].value,
                calls[i].params
            );

            successes[i] = ok;
            emit StrategyExecuted(strategy, ok, nonce);
        }
    }

    /// @notice Create automation
    /// @dev Owner: unrestricted. Operator: must have canCreateAutomation
    function createAutomation(
        address strategy,
        bytes calldata params,
        uint256 maxExecutions,
        string calldata label
    )
        external
        onlyRegistered(strategy)
        returns (uint256 automationId)
    {
        // Check permissions
        if (msg.sender != owner) {
            if (!_operators[msg.sender].canCreateAutomation)
                revert OperatorNotPermitted(msg.sender, "createAutomation");
        }

        // Owner bypasses spending checks
        _beforeExecution(msg.sender, strategy, params);

        return _createAutomation(strategy, params, maxExecutions, label);
    }

    /// @notice Cancel automation
    /// @dev Owner: unrestricted. Operator: must have canCancelAutomation
    function cancelAutomation(uint256 automationId) external {
        // Check permissions
        if (msg.sender != owner) {
            if (!_operators[msg.sender].canCancelAutomation)
                revert OperatorNotPermitted(msg.sender, "cancelAutomation");
        }

        _cancelAutomation(automationId);
    }

    /// @notice Update automation
    /// @dev Owner: unrestricted. Operator: must have canUpdateAutomation
    function updateAutomation(uint256 automationId, bytes calldata newParams) external {
        // Check permissions
        if (msg.sender != owner) {
            if (!_operators[msg.sender].canUpdateAutomation)
                revert OperatorNotPermitted(msg.sender, "updateAutomation");
        }

        Automation storage auto_ = _automations[automationId];
        _beforeExecution(msg.sender, auto_.strategy, newParams);

        _updateAutomation(automationId, newParams);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Types (for batch execution)
    // ─────────────────────────────────────────────────────────────────────────

    struct Call {
        address strategy;
        uint256 value;
        bytes params;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IStrategyRegistry Interface Check
    // ─────────────────────────────────────────────────────────────────────────

    // Helper to avoid interface issues in modules
    function isStrategyActive(address strategy) internal view returns (bool) {
        return strategyRegistry.isStrategyActive(strategy);
    }
}

// Interface helper
interface IStrategyRegistry {
    function isStrategyActive(address adapter) external view returns (bool);
}
