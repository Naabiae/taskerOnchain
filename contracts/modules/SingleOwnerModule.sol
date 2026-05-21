// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OwnershipLayer (SingleOwnerModule)
 * @notice Access control layer for single-owner smart accounts with AI agent execution roles.
 *
 * Provides:
 * - Owner management (user who owns the account)
 * - Execution role registry (AI agents with limited permissions)
 * - Spending limits (rate-limit AI execution: per-tx, per-day, per-lifetime)
 * - Escape hatch (owner-only fund withdrawal, AI cannot access)
 *
 * Key Property:
 * - Owner can always withdraw funds (escape hatch)
 * - AI agents can NEVER transfer funds (no transferToken, no transferNative)
 * - AI agents can execute strategies and create automations (subject to spending limits)
 * - Owner can revoke AI access anytime (instant, no timelock)
 *
 * Composable with SmartAccount via:
 * - _canExecute: owner + active AI agents
 * - _canWithdraw: owner only
 * - _beforeExecution: enforce spending limits on AI agents (not owner)
 *
 * This is NOT a permission system for fund transfers.
 * This is an execution role system: AI can execute, not custody.
 */
abstract contract SingleOwnerModule {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    struct Operator {
        address account;
        bool active;
        bool canCreateAutomation;
        bool canCancelAutomation;
        bool canUpdateAutomation;
        bool canExecuteImmediate;
    }

    struct SpendingRule {
        address token;
        uint256 maxPerExecution;
        uint256 maxPerDay;
        uint256 maxTotal;
        uint256 spentToday;
        uint256 spentTotal;
        uint256 lastDayReset;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    address public owner;
    mapping(address => Operator) internal _operators;
    address[] internal _operatorList;
    mapping(address => mapping(address => SpendingRule)) internal _spendingRules;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorSet(
        address indexed operator,
        bool canCreate,
        bool canCancel,
        bool canUpdate,
        bool canExecute
    );
    event OperatorRemoved(address indexed operator);
    event SpendingRuleSet(
        address indexed operator,
        address indexed token,
        uint256 maxPerExecution,
        uint256 maxPerDay,
        uint256 maxTotal
    );
    event Withdrawn(address indexed token, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotOwner();
    error NotOperator();
    error OperatorNotPermitted(address operator, string action);
    error SpendingLimitExceeded(address token, uint256 amount, uint256 limit);
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Hook Implementations for BaseVault
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Who can execute? Owner or active operators
    function _canExecute(address caller) internal view virtual returns (bool) {
        return caller == owner || _operators[caller].active;
    }

    /// @notice Who can withdraw? Owner only
    function _canWithdraw(address caller) internal view virtual returns (bool) {
        return caller == owner;
    }

    /// @notice Enforce spending rules on operators
    function _beforeExecution(
        address caller,
        address strategy,
        bytes memory params
    ) internal virtual {
        // Owner is unrestricted
        if (caller == owner) return;

        // Operator: enforce spending rules
        if (_operators[caller].active) {
            _enforceSpendingRules(caller, strategy, params);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner Management
    // ─────────────────────────────────────────────────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Escape Hatch (Owner Only)
    // ─────────────────────────────────────────────────────────────────────────

    function transferToken(address token, address recipient, uint256 amount)
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(recipient, amount);
        emit Withdrawn(token, amount);
    }

    function transferNative(address payable recipient, uint256 amount)
        external
        onlyOwner
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert ZeroAmount();
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(address(0), amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Operator Management
    // ─────────────────────────────────────────────────────────────────────────

    function setOperator(
        address operator,
        bool canCreateAutomation,
        bool canCancelAutomation,
        bool canUpdateAutomation,
        bool canExecuteImmediate
    ) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();

        bool wasActive = _operators[operator].active;

        _operators[operator] = Operator({
            account: operator,
            canCreateAutomation: canCreateAutomation,
            canCancelAutomation: canCancelAutomation,
            canUpdateAutomation: canUpdateAutomation,
            canExecuteImmediate: canExecuteImmediate,
            active: true
        });

        if (!wasActive) {
            _operatorList.push(operator);
        }

        emit OperatorSet(
            operator,
            canCreateAutomation,
            canCancelAutomation,
            canUpdateAutomation,
            canExecuteImmediate
        );
    }

    function removeOperator(address operator) external onlyOwner {
        if (!_operators[operator].active) revert NotOperator();
        _operators[operator].active = false;
        emit OperatorRemoved(operator);
    }

    function getOperator(address operator) external view returns (Operator memory) {
        return _operators[operator];
    }

    function getOperators() external view returns (Operator[] memory) {
        Operator[] memory result = new Operator[](_operatorList.length);
        for (uint256 i = 0; i < _operatorList.length; i++) {
            result[i] = _operators[_operatorList[i]];
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Spending Rules
    // ─────────────────────────────────────────────────────────────────────────

    function setSpendingRule(
        address operator,
        address token,
        uint256 maxPerExecution,
        uint256 maxPerDay,
        uint256 maxTotal
    ) external onlyOwner {
        if (!_operators[operator].active) revert NotOperator();

        SpendingRule storage rule = _spendingRules[operator][token];
        rule.token = token;
        rule.maxPerExecution = maxPerExecution;
        rule.maxPerDay = maxPerDay;
        rule.maxTotal = maxTotal;
        rule.lastDayReset = block.timestamp;

        emit SpendingRuleSet(operator, token, maxPerExecution, maxPerDay, maxTotal);
    }

    function getSpendingRule(address operator, address token)
        external
        view
        returns (SpendingRule memory)
    {
        return _spendingRules[operator][token];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Spending Rule Enforcement
    // ─────────────────────────────────────────────────────────────────────────

    function _enforceSpendingRules(
        address operator,
        address strategy,
        bytes memory params
    ) internal {
        // Get token requirements from adapter
        (address[] memory tokens, uint256[] memory amounts) =
            _getTokenRequirements(strategy, params);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0) || amounts[i] == 0) continue;

            SpendingRule storage rule = _spendingRules[operator][tokens[i]];

            // No rule set = operator can't spend this token
            if (rule.maxTotal == 0) revert SpendingLimitExceeded(tokens[i], amounts[i], 0);

            // Reset daily counter if 24h has elapsed
            if (block.timestamp >= rule.lastDayReset + 1 days) {
                rule.spentToday = 0;
                rule.lastDayReset = block.timestamp;
            }

            // Check per-execution limit
            if (amounts[i] > rule.maxPerExecution)
                revert SpendingLimitExceeded(tokens[i], amounts[i], rule.maxPerExecution);

            // Check per-day limit
            if (rule.spentToday + amounts[i] > rule.maxPerDay)
                revert SpendingLimitExceeded(
                    tokens[i],
                    amounts[i],
                    rule.maxPerDay - rule.spentToday
                );

            // Check per-total limit
            if (rule.spentTotal + amounts[i] > rule.maxTotal)
                revert SpendingLimitExceeded(
                    tokens[i],
                    amounts[i],
                    rule.maxTotal - rule.spentTotal
                );

            // Update tracking
            rule.spentToday += amounts[i];
            rule.spentTotal += amounts[i];
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _getTokenRequirements(address strategy, bytes memory params)
        internal
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        // Import IStrategyAdapter for this call
        // This is a helper used by _beforeExecution
        (tokens, amounts) = _strategyAdapterCall(strategy, params);
    }

    /// @dev Helper to call getTokenRequirements on strategy adapter
    function _strategyAdapterCall(address strategy, bytes memory params)
        internal
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        // Use low-level call to avoid import in module
        bytes memory callData = abi.encodeWithSignature(
            "getTokenRequirements(bytes)",
            params
        );
        (bool success, bytes memory result) = strategy.staticcall(callData);

        if (success) {
            (tokens, amounts) = abi.decode(result, (address[], uint256[]));
        } else {
            // Return empty if call fails
            tokens = new address[](0);
            amounts = new uint256[](0);
        }
    }
}
