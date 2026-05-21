// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract StrategyRegistry is Ownable {

    struct StrategyInfo {
        address adapter;
        bool isActive;
        string name;
    }

    mapping(address => StrategyInfo) private _strategies;
    address[] private _strategyList;

    event StrategyRegistered(address indexed adapter, string name);
    event StrategyDeactivated(address indexed adapter);
    event StrategyActivated(address indexed adapter);

    error InvalidAdapter();
    error StrategyNotFound();

    constructor(address _owner) Ownable(_owner) {}

    function registerStrategy(address adapter, string calldata name) external onlyOwner {
        if (adapter == address(0)) revert InvalidAdapter();

        StrategyInfo memory info = StrategyInfo({
            adapter: adapter,
            isActive: true,
            name: name
        });

        _strategies[adapter] = info;
        _strategyList.push(adapter);

        emit StrategyRegistered(adapter, name);
    }

    function deactivateStrategy(address adapter) external onlyOwner {
        if (_strategies[adapter].adapter == address(0)) revert StrategyNotFound();
        _strategies[adapter].isActive = false;
        emit StrategyDeactivated(adapter);
    }

    function activateStrategy(address adapter) external onlyOwner {
        if (_strategies[adapter].adapter == address(0)) revert StrategyNotFound();
        _strategies[adapter].isActive = true;
        emit StrategyActivated(adapter);
    }

    function isStrategyActive(address adapter) external view returns (bool) {
        StrategyInfo storage info = _strategies[adapter];
        return info.adapter != address(0) && info.isActive;
    }

    function getStrategy(address adapter) external view returns (StrategyInfo memory) {
        if (_strategies[adapter].adapter == address(0)) revert StrategyNotFound();
        return _strategies[adapter];
    }

    function getAllStrategies() external view returns (address[] memory) {
        return _strategyList;
    }

    function getStrategyCount() external view returns (uint256) {
        return _strategyList.length;
    }
}
