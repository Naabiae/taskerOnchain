// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./modules/AccessControlModule.sol";

contract TestAccessControlVault is AccessControlModule {
  address public owner;
  
  constructor(address _owner) {
    owner = _owner;
  }
  
  function _isOwner(address caller) internal view override returns (bool) {
    return caller == owner;
  }
  
  function setExecutor(address executor, uint256 maxPerExecution, uint256 maxPerDay, uint256 maxTotal) external {
    require(_isOwner(msg.sender), "Not owner");
    _setExecutor(executor, maxPerExecution, maxPerDay, maxTotal);
  }
  
  function revokeExecutor(address executor) external {
    require(_isOwner(msg.sender), "Not owner");
    _revokeExecutor(executor);
  }
  
  function enforceSpendingLimit(address executor, uint256 amount) external {
    _enforceSpendingLimit(executor, amount);
  }
  
  function getExecutorInfo(address executor) external view returns (ExecutorRole memory) {
    return _executors[executor];
  }
  
  function isExecutorActive(address executor) external view returns (bool) {
    return _isExecutorActive(executor);
  }
}
