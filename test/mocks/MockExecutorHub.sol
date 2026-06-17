// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IStrategyAdapter.sol";

interface IVault {
    function triggerAutomation(uint256 id) external returns (bool);
}

contract MockExecutorHub {
    event Registered(uint256 id, address strategy);
    event Removed(uint256 id);

    function registerTask(uint256 id, address strategy, bytes calldata params) external {
        emit Registered(id, strategy);
    }

    function removeTask(uint256 id) external {
        emit Removed(id);
    }

    function callTrigger(address vault, uint256 id) external returns (bool) {
        return IVault(vault).triggerAutomation(id);
    }
}
