// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./AccessControlModule.sol";

/**
 * @title SharedAccountModule
 *
 * NAV = vault.balanceOf() + deployedCapital
 *
 * WHY deployedCapital:
 *   Strategies like Perps, lending, prediction markets take tokens OUT of the vault
 *   and hold them externally while the position is open. Without tracking this,
 *   NAV = 0 mid-position, share price crashes, and withdrawals are mispriced.
 *
 *   The AI manager calls updateDeployedCapital() to keep this number current.
 *   It is trusted input — the manager is trusted to report honestly (same trust
 *   model as a fund manager marking positions to market).
 *
 * WITHDRAWAL MODEL — two paths, always priced at current NAV:
 *
 *   Instant (Path A):
 *     liquidAssets() >= owed → transfer immediately, burn shares.
 *
 *   Queued (Path B):
 *     liquidAssets() < owed (capital deployed) → shares burned NOW at current
 *     NAV price (locking the exit price), request queued. Manager closes position,
 *     replenishes vault, user claims. Lock protects user from future moves.
 *
 * CAPITAL TRACKING:
 *   totalCapitalDeposited  — running principal baseline (deposits minus redeems)
 *   deployedCapital        — capital currently outside vault in open positions
 *   highWaterMark          — peak NAV for Phase 2 performance fee extraction
 */
abstract contract SharedAccountModule is AccessControlModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    enum WithdrawalStatus { PENDING, FULFILLED, CLAIMED }

    struct WithdrawalRequest {
        address user;
        uint256 shares;       // already burned at request time
        uint256 assetAmount;  // NAV value locked at request time
        uint256 requestTime;
        WithdrawalStatus status;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    IERC20 public asset;

    // shares
    uint256 public totalShares;
    mapping(address => uint256) internal _shares;

    // capital tracking
    uint256 public totalCapitalDeposited;
    uint256 public deployedCapital;
    uint256 public highWaterMark;

    // withdrawal queue
    uint256 public withdrawalRequestCount;
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;
    mapping(address => uint256[]) internal _userRequests;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Deposit(address indexed user, uint256 assets, uint256 shares, uint256 sharePrice);
    event Redeem(address indexed user, uint256 shares, uint256 assets);
    event WithdrawalQueued(uint256 indexed id, address indexed user, uint256 shares, uint256 lockedAssets);
    event WithdrawalFulfilled(uint256 indexed id, address indexed user, uint256 assets);
    event WithdrawalClaimed(uint256 indexed id, address indexed user, uint256 assets);
    event DeployedCapitalUpdated(uint256 oldAmount, uint256 newAmount);
    event ManagerSet(address indexed manager);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error ZeroAmount();
    error InsufficientShares();
    error NotRequestOwner();
    error RequestNotFulfilled();
    error RequestAlreadyClaimed();
    error FulfillAmountTooLow(uint256 needed, uint256 provided);
    error RequestNotPending();

    // ─────────────────────────────────────────────────────────────────────────
    // NAV — single source of truth for share pricing
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice True NAV: liquid tokens in vault + capital deployed to strategies.
     * Share price is always derived from this, never just balanceOf().
     */
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this)) + deployedCapital;
    }

    /**
     * @notice Tokens physically present and immediately payable.
     */
    function liquidAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Share price in asset units, scaled 1e18.
     */
    function sharePrice() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalAssets() * 1e18) / totalShares;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deposit
    // ─────────────────────────────────────────────────────────────────────────

    function deposit(uint256 amount) external nonReentrant returns (uint256 sharesToIssue) {
        if (amount == 0) revert ZeroAmount();

        uint256 price = sharePrice();
        asset.safeTransferFrom(msg.sender, address(this), amount);

        // first depositor: 1 share per asset unit (price = 1e18)
        // subsequent: shares = amount / price (scaled)
        sharesToIssue = (amount * 1e18) / price;

        _shares[msg.sender] += sharesToIssue;
        totalShares += sharesToIssue;
        totalCapitalDeposited += amount;

        uint256 nav = totalAssets();
        if (nav > highWaterMark) highWaterMark = nav;

        emit Deposit(msg.sender, amount, sharesToIssue, price);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Redeem — instant if liquid, queued if not
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Burn shares and receive assets.
     *
     * Shares are burned immediately at current NAV price regardless of path.
     * This locks the exit price — if the position later moves against the vault,
     * the user is protected because their price was already fixed.
     *
     * Path A (liquid): assets transferred now.
     * Path B (illiquid): request created; manager closes position, user claims.
     */
    function redeem(uint256 shares) external nonReentrant returns (uint256 assetsOut) {
        if (shares == 0) revert ZeroAmount();
        if (_shares[msg.sender] < shares) revert InsufficientShares();

        uint256 price = sharePrice();
        assetsOut = (shares * price) / 1e18;

        // proportional capital reduction
        uint256 capitalShare = totalShares > 0
            ? (totalCapitalDeposited * shares) / totalShares
            : 0;

        // burn shares now — price is locked here
        _shares[msg.sender] -= shares;
        totalShares -= shares;
        if (capitalShare <= totalCapitalDeposited) {
            totalCapitalDeposited -= capitalShare;
        }

        if (liquidAssets() >= assetsOut) {
            // PATH A: enough liquid
            asset.safeTransfer(msg.sender, assetsOut);
            emit Redeem(msg.sender, shares, assetsOut);
        } else {
            // PATH B: insufficient liquid — queue at locked price
            _queueWithdrawal(msg.sender, shares, assetsOut);
            assetsOut = 0;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Withdrawal queue
    // ─────────────────────────────────────────────────────────────────────────

    function _queueWithdrawal(address user, uint256 shares, uint256 lockedAssets) internal {
        uint256 id = ++withdrawalRequestCount;
        withdrawalRequests[id] = WithdrawalRequest({
            user: user,
            shares: shares,
            assetAmount: lockedAssets,
            requestTime: block.timestamp,
            status: WithdrawalStatus.PENDING
        });
        _userRequests[user].push(id);
        emit WithdrawalQueued(id, user, shares, lockedAssets);
    }

    /**
     * @notice Manager fulfills a queued withdrawal after closing position.
     * Transfers owed assets into vault; user then calls claimWithdrawal.
     * Manager may send more than locked amount (position closed at a gain).
     */
    function fulfillWithdrawal(uint256 id, uint256 assetAmount)
        external
        onlyPoolManager
        nonReentrant
    {
        WithdrawalRequest storage req = withdrawalRequests[id];
        if (req.status != WithdrawalStatus.PENDING) revert RequestNotPending();
        if (assetAmount < req.assetAmount) revert FulfillAmountTooLow(req.assetAmount, assetAmount);

        // if position closed at a gain, honour the full return
        req.assetAmount = assetAmount;
        req.status = WithdrawalStatus.FULFILLED;

        asset.safeTransferFrom(msg.sender, address(this), assetAmount);
        emit WithdrawalFulfilled(id, req.user, assetAmount);
    }

    /**
     * @notice User claims a fulfilled withdrawal.
     */
    function claimWithdrawal(uint256 id) external nonReentrant {
        WithdrawalRequest storage req = withdrawalRequests[id];
        if (req.user != msg.sender) revert NotRequestOwner();
        if (req.status != WithdrawalStatus.FULFILLED) revert RequestNotFulfilled();

        uint256 amount = req.assetAmount;
        req.status = WithdrawalStatus.CLAIMED;
        asset.safeTransfer(msg.sender, amount);
        emit WithdrawalClaimed(id, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // deployedCapital — manager keeps this honest
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Manager reports how much capital is currently deployed to strategies.
     * Called when opening a position (set higher) or closing one (set lower).
     * This is the trusted input that keeps NAV correct during open positions.
     */
    function updateDeployedCapital(uint256 newAmount) external onlyPoolManager {
        uint256 old = deployedCapital;
        deployedCapital = newAmount;
        emit DeployedCapitalUpdated(old, newAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Capital tracking views
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice NAV minus total principal deposited.
     * Positive = pool is up. Negative = pool is down (loss).
     * Used by Phase 2 performance fee extraction.
     */
    function realizedGains() external view returns (int256) {
        return int256(totalAssets()) - int256(totalCapitalDeposited);
    }

    function balanceOf(address user) external view returns (uint256) {
        return _shares[user];
    }

    function balanceOfAssets(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (_shares[user] * sharePrice()) / 1e18;
    }

    function getUserRequests(address user) external view returns (uint256[] memory) {
        return _userRequests[user];
    }

    function getRequest(uint256 id) external view returns (
        address user,
        uint256 shares,
        uint256 assetAmount,
        uint256 requestTime,
        WithdrawalStatus status
    ) {
        WithdrawalRequest storage r = withdrawalRequests[id];
        return (r.user, r.shares, r.assetAmount, r.requestTime, r.status);
    }

    function getUserPosition(address user) external view returns (
        uint256 shares,
        uint256 currentValue,
        uint256 pendingClaims
    ) {
        shares = _shares[user];
        currentValue = (shares * sharePrice()) / 1e18;
        uint256[] memory ids = _userRequests[user];
        for (uint256 i = 0; i < ids.length; i++) {
            if (withdrawalRequests[ids[i]].status == WithdrawalStatus.PENDING) {
                pendingClaims += withdrawalRequests[ids[i]].assetAmount;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal share math helpers (kept for any overrides)
    // ─────────────────────────────────────────────────────────────────────────

    function _previewDeposit(uint256 amount) internal view returns (uint256) {
        uint256 price = sharePrice();
        return (amount * 1e18) / price;
    }

    function _previewRedeem(uint256 shares) internal view returns (uint256) {
        return (shares * sharePrice()) / 1e18;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Access control hooks (implemented by PooledAccount)
    // ─────────────────────────────────────────────────────────────────────────

    function _canExecute(address caller) internal view virtual returns (bool) {
        return _isExecutorActive(caller);
    }

    function _canWithdraw(address caller) internal view virtual returns (bool) {
        return false;
    }

    function _isOwner(address caller) internal view override returns (bool) {
        return false;
    }

    modifier onlyPoolManager() virtual {
        // overridden in PooledAccount to use manager address
        revert("Not implemented");
        _;
    }
}
