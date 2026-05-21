// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract VaultFactory {

    address public owner;
    address public strategyRegistry;
    address public executorHub;

    address[] public vaults;
    mapping(address => address[]) public userVaults;

    event VaultCreated(address indexed user, address indexed vault);

    error NotOwner();
    error ZeroAddress();

    constructor(address _owner, address _strategyRegistry, address _executorHub) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        strategyRegistry = _strategyRegistry;
        executorHub = _executorHub;
    }

    function createVault(address _user) external returns (address) {
        // Factory doesn't deploy UserVault directly
        // Users deploy UserVault themselves or via separate script
        revert("Use UserVault directly");
    }

    function registerVault(address vault) external {
        vaults.push(vault);
        userVaults[msg.sender].push(vault);
        emit VaultCreated(msg.sender, vault);
    }

    function getUserVaults(address user) external view returns (address[] memory) {
        return userVaults[user];
    }

    function getAllVaults() external view returns (address[] memory) {
        return vaults;
    }

    function getVaultCount() external view returns (uint256) {
        return vaults.length;
    }
}
