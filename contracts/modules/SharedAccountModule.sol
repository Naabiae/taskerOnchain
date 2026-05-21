// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AccessControlModule.sol";

abstract contract SharedAccountModule is AccessControlModule {
    using SafeERC20 for IERC20;

    uint256 public totalShares;
    mapping(address => uint256) internal _shares;
    IERC20 public asset;

    event Deposit(address indexed user, uint256 amount, uint256 sharesIssued);
    event Redeem(address indexed user, uint256 sharesBurned, uint256 assetReturned);
    event ManagerSet(address indexed manager);

    error ZeroAmount();
    error InsufficientShares();

    function _canExecute(address caller) internal view virtual returns (bool) {
        return _isExecutorActive(caller);
    }

    function _canWithdraw(address caller) internal view virtual returns (bool) {
        return false;
    }

    function _isOwner(address caller) internal view override returns (bool) {
        return false;
    }

    function deposit(uint256 amount) external returns (uint256 sharesToIssue) {
        if (amount == 0) revert ZeroAmount();

        asset.safeTransferFrom(msg.sender, address(this), amount);

        sharesToIssue = _previewDeposit(amount);

        _shares[msg.sender] += sharesToIssue;
        totalShares += sharesToIssue;

        emit Deposit(msg.sender, amount, sharesToIssue);
    }

    function redeem(uint256 shares) external returns (uint256 assetAmount) {
        if (shares == 0) revert ZeroAmount();
        if (_shares[msg.sender] < shares) revert InsufficientShares();

        assetAmount = _previewRedeem(shares);

        _shares[msg.sender] -= shares;
        totalShares -= shares;

        asset.safeTransfer(msg.sender, assetAmount);

        emit Redeem(msg.sender, shares, assetAmount);
    }

    function _previewDeposit(uint256 amount) internal view returns (uint256) {
        if (totalShares == 0) return amount;
        return (amount * totalShares) / asset.balanceOf(address(this));
    }

    function _previewRedeem(uint256 shares) internal view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares * asset.balanceOf(address(this))) / totalShares;
    }

    function balanceOf(address user) external view returns (uint256) {
        return _shares[user];
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function sharePrice() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalAssets() * 1e18) / totalShares;
    }
}
