// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BaseVault.sol";
import "../modules/ShareAccountingModule.sol";

/**
 * @title PooledAccount
 * @notice Multi-user smart account with pooled capital and AI manager.
 *
 * Composition:
 * - SmartAccount (BaseVault): execution engine
 * - ShareAccountingModule: pooling + share tokens
 * - Manager role: AI agent executing strategies for all users
 *
 * Properties:
 * - Users: deposit USDC, receive shares, redeem shares to get USDC back
 * - Manager: AI agent with execution role, subject to spending mandate
 * - Native Automation: manager creates automations, keepers execute them
 * - Composable Strategies: any protocol bridge can be called
 * - Scaling: 1000 users, 1 account, 1 tx per strategy (not 1000 txs)
 *
 * Example Flow:
 * 1. Owner deploys PooledAccount with manager = AI agent, asset = USDC
 * 2. User A deposits 100 USDC → gets 100 shares (share price = 1.0)
 * 3. User B deposits 100 USDC → gets 100 shares (total = 200 USDC, 200 shares)
 * 4. Manager creates automation: "Every day, swap USDC→ETH + stake ETH"
 * 5. Keeper executes automation: manager calls executeBatch([swap, stake])
 *    - 200 USDC → 0.1 ETH (at 2000 USD/ETH)
 *    - 0.1 ETH → 0.1 stETH
 * 6. Account now holds: 100 USDC + 0.1 stETH (= 200 USDC value + gains)
 * 7. User A redeems 100 shares → gets 105 USDC (captured their share of gains)
 * 8. User B redeems 100 shares → gets 105 USDC
 *
 * Manager cannot:
 * - Withdraw user funds to external addresses
 * - Transfer ownership
 * - Exceed spending mandate (managed by owner via spending rules)
 * - Execute unapproved strategies (StrategyRegistry gates them)
 *
 * This is the "swarm of AI agents" model:
 * - Each manager runs one PooledAccount (one strategy focus)
 * - Users diversify across multiple managers
 * - No custody risk (users can redeem anytime)
 * - Composable execution (all strategies available to each manager)
 */
contract PooledAccount is BaseVault, ShareAccountingModule {

    // ─────────────────────────────────────────────────────────────────────────
    // Additional State
    // ─────────────────────────────────────────────────────────────────────────

    address public owner;  // Deployer who sets up the account, can revoke manager

    struct ManagerMandate {
        bool active;
        uint256 maxPerExecution;      // Max value deployed per strategy execution
        uint256 maxPerDay;
        uint256 maxLifetime;
        uint256 spentToday;
        uint256 spentTotal;
        uint256 lastDayReset;
    }

    mapping(address => ManagerMandate) public managerMandates;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ManagerSet(address indexed manager, uint256 maxPerExecution, uint256 maxPerDay, uint256 maxLifetime);
    event ManagerRevoked(address indexed manager);
    event MandateViolation(address indexed manager, uint256 attempted, uint256 limit);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotOwner();
    error NotManager();
    error ZeroAddress();
    error MandateExceeded(uint256 amount, uint256 limit);
    error ManagerNotActive();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address _owner,
        address _asset,
        address _manager,
        uint256 _maxPerExecution,
        uint256 _maxPerDay,
        uint256 _maxLifetime,
        address _strategyRegistry,
        address _executorHub
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_asset == address(0)) revert ZeroAddress();
        if (_strategyRegistry == address(0)) revert ZeroAddress();
        if (_executorHub == address(0)) revert ZeroAddress();

        owner = _owner;
        asset = IERC20(_asset);
        manager = _manager;
        strategyRegistry = _strategyRegistry;
        executorHub = _executorHub;

        // Set manager mandate
        if (_manager != address(0)) {
            _setManagerMandate(_manager, _maxPerExecution, _maxPerDay, _maxLifetime);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyManager() {
        if (msg.sender != manager || !managerMandates[manager].active) revert NotManager();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Override SmartAccount Hooks
    // ─────────────────────────────────────────────────────────────────────────

    function _canExecute(address caller) internal view override returns (bool) {
        return caller == manager && managerMandates[manager].active;
    }

    function _canWithdraw(address caller) internal view override returns (bool) {
        // No escape hatch in pooled accounts
        // Users withdraw via redeem()
        return false;
    }

    function _beforeExecution(
        address caller,
        address strategy,
        bytes memory params
    ) internal override {
        // Only manager can execute, and must respect mandate
        if (caller != manager || !managerMandates[caller].active) {
            revert NotManager();
        }

        _enforceMandateLimit(caller, strategy, params);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Manager Execution (Like SingleUserAccount, but with mandate checks)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Execute a strategy immediately (manager only)
    function execute(
        address strategy,
        uint256 value,
        bytes calldata params
    )
        external
        onlyManager
        onlyRegistered(strategy)
        nonReentrant
        returns (bool success, bytes memory result)
    {
        _beforeExecution(msg.sender, strategy, params);

        nonce++;
        (success, result) = _executeStrategy(strategy, value, params);
        emit StrategyExecuted(strategy, success, nonce);
    }

    /// @notice Execute multiple strategies atomically (manager only)
    function executeBatch(
        Call[] calldata calls
    )
        external
        onlyManager
        nonReentrant
        returns (bool[] memory successes)
    {
        successes = new bool[](calls.length);
        nonce++;

        for (uint256 i = 0; i < calls.length; i++) {
            address strategy = calls[i].strategy;
            if (!strategyRegistry.isStrategyActive(strategy))
                revert StrategyNotRegistered(strategy);

            _beforeExecution(msg.sender, strategy, calls[i].params);

            (bool ok, bytes memory result) = _executeStrategy(
                strategy,
                calls[i].value,
                calls[i].params
            );

            successes[i] = ok;
            emit StrategyExecuted(strategy, ok, nonce);
        }
    }

    /// @notice Create automation (manager only)
    function createAutomation(
        address strategy,
        bytes calldata params,
        uint256 maxExecutions,
        string calldata label
    )
        external
        onlyManager
        onlyRegistered(strategy)
        returns (uint256 automationId)
    {
        _beforeExecution(msg.sender, strategy, params);
        return _createAutomation(strategy, params, maxExecutions, label);
    }

    /// @notice Cancel automation (manager only)
    function cancelAutomation(uint256 automationId) external onlyManager {
        _cancelAutomation(automationId);
    }

    /// @notice Update automation (manager only)
    function updateAutomation(uint256 automationId, bytes calldata newParams) external onlyManager {
        Automation storage auto_ = _automations[automationId];
        _beforeExecution(msg.sender, auto_.strategy, newParams);
        _updateAutomation(automationId, newParams);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner Management (Only Owner Can Do These)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set or update manager mandate
    function setManagerMandate(
        address newManager,
        uint256 maxPerExecution,
        uint256 maxPerDay,
        uint256 maxLifetime
    ) external onlyOwner {
        manager = newManager;
        _setManagerMandate(newManager, maxPerExecution, maxPerDay, maxLifetime);
    }

    /// @notice Revoke manager access
    function revokeManager() external onlyOwner {
        if (manager != address(0)) {
            managerMandates[manager].active = false;
            emit ManagerRevoked(manager);
        }
        manager = address(0);
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mandate Enforcement
    // ─────────────────────────────────────────────────────────────────────────

    function _setManagerMandate(
        address _manager,
        uint256 maxPerExecution,
        uint256 maxPerDay,
        uint256 maxLifetime
    ) internal {
        ManagerMandate storage mandate = managerMandates[_manager];
        mandate.active = true;
        mandate.maxPerExecution = maxPerExecution;
        mandate.maxPerDay = maxPerDay;
        mandate.maxLifetime = maxLifetime;
        mandate.lastDayReset = block.timestamp;

        emit ManagerSet(_manager, maxPerExecution, maxPerDay, maxLifetime);
    }

    function _enforceMandateLimit(
        address _manager,
        address strategy,
        bytes memory params
    ) internal {
        // Get token requirements from adapter
        (address[] memory tokens, uint256[] memory amounts) =
            _getTokenRequirements(strategy, params);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0) || amounts[i] == 0) continue;

            // Only enforce limit if it's the asset token (main capital)
            if (tokens[i] != address(asset)) continue;

            ManagerMandate storage mandate = managerMandates[_manager];
            if (!mandate.active) revert ManagerNotActive();

            // Reset daily counter if 24h elapsed
            if (block.timestamp >= mandate.lastDayReset + 1 days) {
                mandate.spentToday = 0;
                mandate.lastDayReset = block.timestamp;
            }

            // Check per-execution limit
            if (amounts[i] > mandate.maxPerExecution) {
                revert MandateExceeded(amounts[i], mandate.maxPerExecution);
            }

            // Check per-day limit
            if (mandate.spentToday + amounts[i] > mandate.maxPerDay) {
                revert MandateExceeded(amounts[i], mandate.maxPerDay - mandate.spentToday);
            }

            // Check per-lifetime limit
            if (mandate.spentTotal + amounts[i] > mandate.maxLifetime) {
                revert MandateExceeded(amounts[i], mandate.maxLifetime - mandate.spentTotal);
            }

            // Update tracking
            mandate.spentToday += amounts[i];
            mandate.spentTotal += amounts[i];
        }
    }

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

    // ─────────────────────────────────────────────────────────────────────────
    // Types (For batch execution)
    // ─────────────────────────────────────────────────────────────────────────

    struct Call {
        address strategy;
        uint256 value;
        bytes params;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View: Manager Info
    // ─────────────────────────────────────────────────────────────────────────

    function getManagerMandate(address _manager) external view returns (ManagerMandate memory) {
        return managerMandates[_manager];
    }

    function getManagerStatus() external view returns (address, bool, uint256, uint256) {
        ManagerMandate memory m = managerMandates[manager];
        return (manager, m.active, m.maxPerExecution, m.spentTotal);
    }
}
