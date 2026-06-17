// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AccessControlModule.sol";

abstract contract SingleOwnerModule is AccessControlModule {
    using SafeERC20 for IERC20;

    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Withdrawn(address indexed token, uint256 amount);

    error NotOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function _isOwner(address caller) internal view override returns (bool) {
        return caller == owner;
    }

    function _canExecute(address caller) internal view virtual returns (bool) {
        return caller == owner || _isExecutorActive(caller);
    }

    function _canWithdraw(address caller) internal view virtual returns (bool) {
        return caller == owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    function setExecutor(
        address executor,
        uint256 maxPerExecution,
        uint256 maxPerDay,
        uint256 maxTotal
    ) external onlyOwner {
        _setExecutor(executor, maxPerExecution, maxPerDay, maxTotal);
    }

    function revokeExecutor(address executor) external onlyOwner {
        _revokeExecutor(executor);
    }

    function transferToken(address token, address recipient, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(recipient, amount);
        emit Withdrawn(token, amount);
    }

    function transferNative(address payable recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "Transfer failed");
        emit Withdrawn(address(0), amount);
    }
}