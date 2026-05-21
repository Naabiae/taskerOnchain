// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ShareAccountingModule (PooledAccountingLayer)
 * @notice Capital pooling layer for multi-user accounts with share tokens.
 *
 * Provides:
 * - Share token accounting (ERC4626-style, but not inheriting to avoid conflicts)
 * - Deposit/Redeem mechanics (users buy shares, account deploys capital)
 * - NAV calculation (total assets / total shares = share price)
 * - Withdrawals only via redeem (share burning, asset return)
 *
 * Use Case:
 * - Multiple users deposit USDC into PooledAccount
 * - Each user gets shares (proportional to deposit)
 * - AI manager executes strategies (same strategies as SingleUserAccount)
 * - All users' capital compounds together (1 tx for N users)
 * - Users can redeem anytime (burn shares, get USDC back)
 *
 * Key Property:
 * - User A deposits 100 USDC → gets 100 shares (when share price = 1.0)
 * - User B deposits 100 USDC → gets 100 shares
 * - Manager executes strategy: 200 USDC → 220 USDC (10% gain)
 * - Share price now = 1.1 (220 total / 200 shares)
 * - User A redeems 100 shares → gets 110 USDC (captured their gains)
 * - User B redeems 100 shares → gets 110 USDC
 *
 * Composable with SmartAccount via:
 * - _canExecute: manager (AI agent)
 * - _canWithdraw: only via redeem() (no escape hatch for manager)
 * - _beforeExecution: enforce manager's mandate (spending limits)
 *
 * This is how you scale: 1000 users, 1 account, 1 tx per strategy execution
 */
abstract contract ShareAccountingModule {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    struct ShareState {
        uint256 totalShares;
        mapping(address => uint256) balanceOf;
        mapping(address => uint256) allowance;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    IERC20 public asset;  // Deposit token (e.g., USDC)
    uint256 public totalShares;
    mapping(address => uint256) internal _shares;

    // For share transfer (optional, if implementing ERC20-like interface)
    mapping(address => mapping(address => uint256)) internal _allowed;

    // Manager of this pooled account
    address public manager;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Deposit(address indexed user, uint256 assetAmount, uint256 sharesIssued);
    event Redeem(address indexed user, uint256 sharesBurned, uint256 assetReturned);
    event Transfer(address indexed from, address indexed to, uint256 shares);
    event Approval(address indexed owner, address indexed spender, uint256 shares);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(address token, uint256 amount);
    error InsufficientShares(uint256 needed, uint256 available);
    error InsufficientAllowance();

    // ─────────────────────────────────────────────────────────────────────────
    // Hook Implementations for SmartAccount
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Who can execute? Manager (AI agent) only
    function _canExecute(address caller) internal view virtual returns (bool) {
        return caller == manager && manager != address(0);
    }

    /// @notice Who can withdraw? Only via redeem() by shareholders
    function _canWithdraw(address caller) internal view virtual returns (bool) {
        // Pooled accounts: no escape hatch for manager
        // Users withdraw via redeem() by burning shares
        return false;
    }

    /// @notice Enforce manager's spending mandate
    function _beforeExecution(
        address caller,
        address strategy,
        bytes memory params
    ) internal virtual {
        // Manager execution is subject to their mandate
        // This would be implemented in subclass with actual spending checks
        // For now, just verify manager is executing
        require(caller == manager, "Only manager can execute");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core Mechanics: Deposit / Redeem
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit assets, receive shares
    /// @param assets Amount of asset token (e.g., USDC) to deposit
    /// @return sharesToIssue Amount of shares issued
    function deposit(uint256 assets) external returns (uint256 sharesToIssue) {
        if (assets == 0) revert ZeroAmount();

        // Pull tokens from user
        asset.safeTransferFrom(msg.sender, address(this), assets);

        // Calculate shares to issue
        sharesToIssue = _previewDeposit(assets);

        // Issue shares
        _shares[msg.sender] += sharesToIssue;
        totalShares += sharesToIssue;

        emit Deposit(msg.sender, assets, sharesToIssue);
        return sharesToIssue;
    }

    /// @notice Redeem shares, receive assets
    /// @param shares Amount of shares to burn
    /// @return assetsReturned Amount of asset tokens returned
    function redeem(uint256 shares) external returns (uint256 assetsReturned) {
        if (shares == 0) revert ZeroAmount();
        if (_shares[msg.sender] < shares) revert InsufficientShares(shares, _shares[msg.sender]);

        // Calculate assets to return
        assetsReturned = _previewRedeem(shares);

        // Burn shares
        _shares[msg.sender] -= shares;
        totalShares -= shares;

        // Return assets
        asset.safeTransfer(msg.sender, assetsReturned);

        emit Redeem(msg.sender, shares, assetsReturned);
        return assetsReturned;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NAV Calculation (Share Price)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total assets under management
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Convert assets to shares (deposit preview)
    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        uint256 assetTotal = totalAssets();

        // First deposit: 1:1 ratio
        if (totalShares == 0) {
            return assets;
        }

        // Subsequent deposits: share price = totalAssets / totalShares
        // sharesToIssue = assets * (totalShares / totalAssets)
        return (assets * totalShares) / assetTotal;
    }

    /// @notice Convert shares to assets (redeem preview)
    function _previewRedeem(uint256 shares) internal view returns (uint256) {
        uint256 assetTotal = totalAssets();

        if (totalShares == 0) {
            return 0;
        }

        // assetsReturned = shares * (totalAssets / totalShares)
        return (shares * assetTotal) / totalShares;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Share Balance Interface
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice User's share balance
    function balanceOf(address user) external view returns (uint256) {
        return _shares[user];
    }

    /// @notice User's share value in assets
    function balanceOfAssets(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        uint256 userShares = _shares[user];
        return _previewRedeem(userShares);
    }

    /// @notice Current share price (1 share = ??? assets)
    function sharePrice() external view returns (uint256) {
        if (totalShares == 0) return 1e18;  // Default 1:1

        // Price = totalAssets / totalShares (with 18 decimals)
        return (totalAssets() * 1e18) / totalShares;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Optional: Share Transfer (ERC20-like, but not inheriting)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Transfer shares to another user
    function transferShares(address recipient, uint256 shares) external {
        if (recipient == address(0)) revert ZeroAddress();
        if (_shares[msg.sender] < shares) revert InsufficientShares(shares, _shares[msg.sender]);

        _shares[msg.sender] -= shares;
        _shares[recipient] += shares;

        emit Transfer(msg.sender, recipient, shares);
    }

    /// @notice Approve another address to spend your shares (for transfers)
    function approveShares(address spender, uint256 shares) external {
        _allowed[msg.sender][spender] = shares;
        emit Approval(msg.sender, spender, shares);
    }

    /// @notice Transfer shares on behalf (requires approval)
    function transferSharesFrom(address from, address to, uint256 shares) external {
        if (_allowed[from][msg.sender] < shares) revert InsufficientAllowance();
        if (_shares[from] < shares) revert InsufficientShares(shares, _shares[from]);

        _allowed[from][msg.sender] -= shares;
        _shares[from] -= shares;
        _shares[to] += shares;

        emit Transfer(from, to, shares);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────

    function getTotalShares() external view returns (uint256) {
        return totalShares;
    }

    function getTotalAssets() external view returns (uint256) {
        return totalAssets();
    }
}
