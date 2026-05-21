// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseVault.sol";
import "../modules/SingleOwnerModule.sol";

/**
 * @title SingleUserAccount (UserVault)
 * @notice AI-driven smart account for a single user with native automation.
 *
 * Composition:
 * - SmartAccount (BaseVault): execution engine
 * - OwnershipLayer (SingleOwnerModule): owner + AI execution roles + spending limits
 *
 * Properties:
 * - Owner: holds tokens, can withdraw, can grant/revoke AI access
 * - AI Agent: can execute strategies and create automations, subject to spending limits
 * - Native Automation: owner/AI can schedule automations, keepers execute them
 * - Composable Strategies: any protocol bridge can be called in any combination
 *
 * Example Flow:
 * 1. User deploys SingleUserAccount
 * 2. User grants AI agent execution role with limits (max 10k USDC/day)
 * 3. AI creates automation: "When ETH < $2000, swap USDC→ETH"
 * 4. Keepers watch the automation
 * 5. When ETH drops: keeper executes, AI earns reward from account balance
 * 6. User always owns the funds. Can revoke AI anytime.
 *
 * This is: Smart Account + AI Agent Access + Native Automation
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
