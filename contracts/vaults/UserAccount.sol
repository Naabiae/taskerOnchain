// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/BaseVault.sol";
import "../modules/SingleOwnerModule.sol";

contract UserAccount is BaseVault, SingleOwnerModule {

    constructor(
        address _owner,
        address _strategyRegistry,
        address _executorHub
    ) {
        if (_owner == address(0)) revert("Zero address");
        owner = _owner;
        strategyRegistry = _strategyRegistry;
        executorHub = _executorHub;
    }

    function execute(
        address strategy,
        uint256 value,
        bytes calldata params
    ) external nonReentrant returns (bool success, bytes memory result) {
        require(_canExecute(msg.sender), "Not authorized");

        if (msg.sender != owner) {
            (address[] memory tokens, uint256[] memory amounts) =
                _getTokenRequirements(strategy, params);
            for (uint256 i = 0; i < tokens.length; i++) {
                if (tokens[i] != address(0) && amounts[i] > 0) {
                    _enforceSpendingLimit(msg.sender, amounts[i]);
                }
            }
        }

        _beforeExecution(msg.sender, strategy, params);
        nonce++;
        (success, result) = _executeStrategy(strategy, value, params);
        emit StrategyExecuted(strategy, success, nonce);
    }

    function _beforeExecution(
        address caller,
        address strategy,
        bytes memory params
    ) internal override {}

    function _canExecute(address caller) internal view override(BaseVault, SingleOwnerModule) returns (bool) {
        return caller == owner || _isExecutorActive(caller);
    }

    function _canWithdraw(address caller) internal view override(BaseVault, SingleOwnerModule) returns (bool) {
        return caller == owner;
    }

    function _getTokenRequirements(address strategy, bytes memory params)
        internal
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        // call getTokenRequirements(address vault, bytes params) if available; fallback to older signature
        bytes memory callDataNew = abi.encodeWithSignature("getTokenRequirements(address,bytes)", address(this), params);
        (bool success, bytes memory result) = strategy.staticcall(callDataNew);
        if (!success) {
            bytes memory callData = abi.encodeWithSignature("getTokenRequirements(bytes)", params);
            (success, result) = strategy.staticcall(callData);
        }
        if (success) {
            (tokens, amounts) = abi.decode(result, (address[], uint256[]));
        } else {
            tokens = new address[](0);
            amounts = new uint256[](0);
        }
    }
}
