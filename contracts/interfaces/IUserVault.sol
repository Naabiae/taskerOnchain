// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUserVault
 * @notice Interface for UserVault — persistent smart account per user
 */
interface IUserVault {

    // ============ Enums ============

    enum AutomationStatus { ACTIVE, COMPLETED, CANCELLED }

    // ============ Structs ============

    struct Automation {
        uint256 id;
        address strategy;
        bytes params;
        AutomationStatus status;
        uint256 createdAt;
        uint256 executionCount;
        uint256 lastExecutionTime;
        uint256 maxExecutions;   // 0 = unlimited
        string label;
    }

    struct Call {
        address strategy;
        uint256 value;
        bytes params;
    }

    struct Operator {
        address account;
        bool canCreateAutomation;
        bool canCancelAutomation;
        bool canUpdateAutomation;
        bool canExecuteImmediate;
        bool active;
    }

    struct SpendingRule {
        address token;
        uint256 maxPerExecution;
        uint256 maxPerDay;
        uint256 maxTotal;
        uint256 spentToday;
        uint256 spentTotal;
        uint256 lastDayReset;
    }

    // ============ Events ============

    event Deposited(address indexed token, uint256 amount);
    event Withdrawn(address indexed token, uint256 amount);
    event StrategyExecuted(address indexed strategy, bool success, uint256 nonce);

    event AutomationCreated(uint256 indexed id, address indexed strategy, string label);
    event AutomationUpdated(uint256 indexed id, bytes newParams);
    event AutomationCancelled(uint256 indexed id);
    event AutomationCompleted(uint256 indexed id);
    event AutomationTriggered(uint256 indexed id, bool success, uint256 executionNumber);

    event OperatorSet(address indexed operator, bool canCreate, bool canCancel, bool canUpdate, bool canExecute);
    event OperatorRemoved(address indexed operator);
    event SpendingRuleSet(address indexed operator, address indexed token, uint256 maxPerExec, uint256 maxPerDay, uint256 maxTotal);

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event ExecutorHubUpdated(address indexed oldHub, address indexed newHub);
    event RewardReleased(address indexed executor, uint256 amount);
    event RewardManagerUpdated(address indexed oldManager, address indexed newManager);

    // ============ Errors ============

    error NotOwner();
    error NotOperator();
    error NotExecutorHub();
    error NotRewardManager();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error StrategyNotRegistered(address strategy);
    error InvalidParams(string reason);
    error AutomationNotActive(uint256 id);
    error ConditionsNotMet(uint256 id, string reason);
    error InsufficientBalance(address token, uint256 amount);
    error TransferFailed();
    error BatchStrategyFailed(uint256 index, bytes reason);
    error SpendingLimitExceeded(address token, uint256 requested, uint256 remaining);
    error OperatorNotPermitted(address operator, string action);

    // ============ Functions ============

    /// @notice Initialize vault (called by factory)
    function initialize(address _owner, address _strategyRegistry, address _executorHub) external;

    // ── Owner: Transfer ──

    function transferToken(address token, address recipient, uint256 amount) external;
    function transferNative(address recipient, uint256 amount) external;

    // ── Owner OR Operator: Strategy Execution ──

    function execute(address strategy, uint256 value, bytes calldata params)
        external returns (bool success, bytes memory result);
    function executeBatch(Call[] calldata calls)
        external returns (bool[] memory successes);

    // ── Owner OR Operator: Automation Management ──

    function createAutomation(address strategy, bytes calldata params, uint256 maxExecutions, string calldata label)
        external returns (uint256 automationId);
    function updateAutomation(uint256 automationId, bytes calldata newParams) external;
    function cancelAutomation(uint256 automationId) external;

    // ── ExecutorHub only: Trigger Automation ──

    function triggerAutomation(uint256 automationId) external returns (bool success);

    // ── Owner only: Operator Management ──

    function setOperator(address operator, bool canCreateAutomation, bool canCancelAutomation, bool canUpdateAutomation, bool canExecuteImmediate) external;
    function removeOperator(address operator) external;
    function setSpendingRule(address operator, address token, uint256 maxPerExecution, uint256 maxPerDay, uint256 maxTotal) external;

    // ── Owner only: Admin ──

    function transferOwnership(address newOwner) external;
    function setExecutorHub(address newHub) external;
    function setRewardManager(address newManager) external;

    // ── RewardManager only: Reward ──

    function releaseReward(address executor, uint256 amount) external;
    function getAvailableForRewards() external view returns (uint256);

    // ── Views ──

    function getPortfolio() external view returns (
        address[] memory tokens,
        uint256[] memory balances,
        uint256 nativeBalance
    );
    function getActiveAutomations() external view returns (Automation[] memory);
    function getAutomation(uint256 id) external view returns (Automation memory);
    function getExecutableAutomations() external view returns (uint256[] memory ids);
    function getOperator(address operator) external view returns (Operator memory);
    function getSpendingRule(address operator, address token) external view returns (SpendingRule memory);
    function getVaultInfo() external view returns (
        address vaultOwner,
        address registry,
        address hub,
        uint256 automationCount,
        uint256 currentNonce
    );
}