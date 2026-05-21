// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseVault.sol";
import "../modules/SharedAccountModule.sol";

contract PooledAccount is BaseVault, SharedAccountModule {

    address public manager;

    event ManagerSet(address indexed manager);

    error NotManager();
    error ZeroAddress();

    constructor(
        address _asset,
        address _manager,
        address _strategyRegistry,
        address _executorHub
    ) {
        if (_asset == address(0)) revert ZeroAddress();
        if (_strategyRegistry == address(0)) revert ZeroAddress();
        if (_executorHub == address(0)) revert ZeroAddress();

        asset = IERC20(_asset);
        manager = _manager;
        strategyRegistry = _strategyRegistry;
        executorHub = _executorHub;
    }

    function setManager(address _manager) external {
        require(msg.sender == manager || manager == address(0), "Not authorized");
        if (_manager == address(0)) revert ZeroAddress();
        manager = _manager;
        emit ManagerSet(_manager);
    }

    function execute(
        address strategy,
        uint256 value,
        bytes calldata params
    ) external nonReentrant returns (bool success, bytes memory result) {
        require(msg.sender == manager, "Only manager");

        (address[] memory tokens, uint256[] memory amounts) =
            _getTokenRequirements(strategy, params);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(0) && amounts[i] > 0) {
                _enforceSpendingLimit(msg.sender, amounts[i]);
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

    function _getTokenRequirements(address strategy, bytes memory params)
        internal
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        bytes memory callData = abi.encodeWithSignature(
            "getTokenRequirements(bytes)",
            params
        );
        (bool success, bytes memory result) = strategy.staticcall(callData);
        if (success) {
            (tokens, amounts) = abi.decode(result, (address[], uint256[]));
        } else {
            tokens = new address[](0);
            amounts = new uint256[](0);
        }
    }
}
