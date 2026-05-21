// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract AccessControlModule {

    struct ExecutorRole {
        address executor;
        bool active;
        uint256 maxPerExecution;
        uint256 maxPerDay;
        uint256 maxTotal;
        uint256 spentToday;
        uint256 spentTotal;
        uint256 lastDayReset;
    }

    mapping(address => ExecutorRole) internal _executors;
    address[] internal _executorList;

    event ExecutorAdded(address indexed executor, uint256 maxPerExecution, uint256 maxPerDay, uint256 maxTotal);
    event ExecutorRemoved(address indexed executor);
    event ExecutorRevoked(address indexed executor);
    event SpendingLimitUpdated(address indexed executor, uint256 maxPerExecution, uint256 maxPerDay, uint256 maxTotal);

    error NotOwner();
    error ExecutorNotActive();
    error SpendingLimitExceeded(uint256 amount, uint256 limit);
    error ZeroAddress();

    function _isOwner(address caller) internal view virtual returns (bool);

    function _setExecutor(
        address executor,
        uint256 maxPerExecution,
        uint256 maxPerDay,
        uint256 maxTotal
    ) internal {
        if (executor == address(0)) revert ZeroAddress();

        bool existed = _executors[executor].active;

        _executors[executor] = ExecutorRole({
            executor: executor,
            active: true,
            maxPerExecution: maxPerExecution,
            maxPerDay: maxPerDay,
            maxTotal: maxTotal,
            spentToday: 0,
            spentTotal: 0,
            lastDayReset: block.timestamp
        });

        if (!existed) {
            _executorList.push(executor);
        }

        emit ExecutorAdded(executor, maxPerExecution, maxPerDay, maxTotal);
    }

    function _revokeExecutor(address executor) internal {
        if (!_executors[executor].active) revert ExecutorNotActive();
        _executors[executor].active = false;
        emit ExecutorRevoked(executor);
    }

    function _enforceSpendingLimit(address executor, uint256 amount) internal {
        ExecutorRole storage role = _executors[executor];
        if (!role.active) revert ExecutorNotActive();

        // Reset daily if needed
        if (block.timestamp >= role.lastDayReset + 1 days) {
            role.spentToday = 0;
            role.lastDayReset = block.timestamp;
        }

        // Check limits
        if (amount > role.maxPerExecution) revert SpendingLimitExceeded(amount, role.maxPerExecution);
        if (role.spentToday + amount > role.maxPerDay) revert SpendingLimitExceeded(amount, role.maxPerDay - role.spentToday);
        if (role.spentTotal + amount > role.maxTotal) revert SpendingLimitExceeded(amount, role.maxTotal - role.spentTotal);

        role.spentToday += amount;
        role.spentTotal += amount;
    }

    function _isExecutorActive(address executor) internal view returns (bool) {
        return _executors[executor].active;
    }

    function getExecutor(address executor) external view returns (ExecutorRole memory) {
        return _executors[executor];
    }

    function getAllExecutors() external view returns (address[] memory) {
        return _executorList;
    }
}
