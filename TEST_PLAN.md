# Test Strategy for UARC Smart Accounts

## Architecture Overview

UARC is a modular smart account system with:
1. **BaseVault** - Execution engine with automation state machine
2. **ExecutorHub** - Permissionless keeper registry & execution coordinator  
3. **StrategyRegistry** - Whitelisted strategies for composable execution
4. **AccessControlModule** - Executor roles with granular spending limits
5. **UserAccount** - SingleOwner + Executors (BaseVault + SingleOwnerModule)
6. **PooledAccount** - Multi-user pooled funds (BaseVault + SharedAccountModule)

---

## Test Layers

### Layer 1: Core Infrastructure (Unit Tests)

#### 1.1 StrategyRegistry
- **Registry Operations**
  - ✓ Register strategy adapter with name
  - ✓ Activate/deactivate strategies
  - ✓ Prevent zero-address registration
  - ✓ Query active/inactive strategies
  - ✓ Only owner can modify (access control)

- **Strategy Queries**
  - ✓ Get strategy info by address
  - ✓ Get all strategies
  - ✓ Count total registered strategies
  - ✓ Handle unknown strategy queries

#### 1.2 ExecutorHub (Keeper Network)
- **Executor Management**
  - ✓ Register keeper executor (executor should have an admin for adding and removing executors)
  - ✓ Deactivate executor
  - ✓ Prevent duplicate registrations
  - ✓ Prevent non-executors from calling actions
  - ✓ Track executor stats (total, successful, failed executions) (we dont need to do this because unsuccesful will revert )

- **Task Registration**
  - ✓ Register automation task for vault
  - ✓ Prevent duplicate task registration
  - ✓ Deactivate task
  - ✓ Query task metadata

- **Executor Rewards**
  - ✓ Base reward per execution
  - ✓ Reward manager can adjust rates
  - ✓ Only owner can set reward manager

#### 1.3 AccessControlModule (Spending Limits)
- **Executor Roles**
  - ✓ Add executor with spending limits (per-execution, per-day, max-total)
  - ✓ Revoke executor (disable access)
  - ✓ Check if executor is active
  - ✓ Prevent zero-address executors

- **Spending Limit Enforcement**
  - ✓ Per-execution limit enforced
  - ✓ Daily limit enforced (resets per 24h)
  - ✓ Lifetime limit enforced
  - ✓ Day reset logic works correctly (reset on day boundary)
  - ✓ Multiple spends tracked correctly in same day
  - ✓ Revert on limit exceeded

---

### Layer 2: Vault Mechanics (Unit Tests)

#### 2.1 UserAccount (Single Owner + Executors)
- **Ownership & Access**
  - ✓ Owner is set at deployment
  - ✓ Owner can execute any strategy
  - ✓ Owner can add/revoke executors
  - ✓ Owner can withdraw all funds
  - ✓ Non-owner cannot execute without executor role

- **Executor Execution**
  - ✓ Registered executor can execute strategy
  - ✓ Revoked executor cannot execute
  - ✓ Executor respects spending limits
  - ✓ Executor cannot withdraw (only execute)
  - ✓ Inactive executor rejected

- **Token Tracking**
  - ✓ ERC20 tokens deposited are tracked
  - ✓ New tokens added to held list
  - ✓ Duplicate token tracking avoided
  - ✓ Get all held tokens

#### 2.2 PooledAccount (Multi-User Pooled)
- **Pooled Membership**
  - ✓ Manager set at deployment
  - ✓ Manager can execute strategies
  - ✓ Manager can deposit on behalf of users
  - ✓ Non-manager cannot execute
  - ✓ Only manager can change manager

- **Share Accounting**
  - ✓ User can deposit ERC20 (1 token per share)
  - ✓ User can redeem shares for tokens
  - ✓ Share balance tracks correctly
  - ✓ Cannot redeem more than owned
  - ✓ Multiple users' shares tracked separately

- **Pooled Execution**
  - ✓ Single execution tx affects all user balances
  - ✓ 1000 users = 1 pool execution (not 1000 individual txs)
  - ✓ Strategy profit/loss distributed proportionally

---

### Layer 3: Composable Strategies (Integration Tests)

#### 3.1 Strategy Composition Model
- **Strategy Adapter Interface**
  - ✓ IStrategyAdapter.canExecute(params) checks preconditions
  - ✓ IStrategyAdapter.execute(params) returns (success, result)
  - ✓ IStrategyAdapter.getTokenRequirements() returns (tokens[], amounts[])

- **Multi-Strategy Execution**
  - ✓ Single vault holds N strategies
  - ✓ Strategies executed independently or chained
  - ✓ Each strategy verified in StrategyRegistry
  - ✓ Unregistered strategy rejected

#### 3.2 Mock Strategy Adapters
- **SimpleSwap Adapter**
  - Input: {tokenIn: address, tokenOut: address, amountIn: uint256}
  - Logic: Transfer tokenIn, mock-swap, transfer tokenOut to vault
  - Verify: Token transfer in, token transfer out, nonce increment

- **LendingProtocol Adapter**
  - Input: {asset: address, amount: uint256}
  - Logic: Deposit asset to protocol, receive LP token
  - Verify: Asset deducted, LP token minted

- **CompoundStrategy Adapter**
  - Input: {action: "supply"|"withdraw", token: address, amount: uint256}
  - Logic: Compose lending + swapping
  - Verify: Multi-step execution atomic

---

### Layer 4: Automation & Keeper Execution (Integration Tests)

#### 4.1 Automation Lifecycle
- **Automation Creation**
  - ✓ Owner creates automation with strategy + params
  - ✓ Automation assigned unique ID
  - ✓ Automation status = ACTIVE
  - ✓ Store execution count, timestamps, max executions

- **Automation Triggers**
  - ✓ Keeper calls executeAutomation(vaultAddress, automationId)
  - ✓ Vault checks automation is active
  - ✓ Keeper's spending limits enforced
  - ✓ ExecutorHub tracks execution stats

- **Automation Terminal States**
  - ✓ COMPLETED: executionCount >= maxExecutions
  - ✓ CANCELLED: owner cancels active automation
  - ✓ ACTIVE: still running

- **Automation Query**
  - ✓ Get automation details (id, strategy, params, status, count)
  - ✓ Get all vaults automations
  - ✓ Count active automations

#### 4.2 Keeper Reputation (ExecutorHub)
- **Execution Tracking**
  - ✓ Track total executions per keeper
  - ✓ Track successful executions
  - ✓ Track failed executions
  - ✓ Calculate success rate

- **Permissionless Execution**
  - ✓ Any registered keeper can execute any automation
  - ✓ No special privileges per keeper
  - ✓ Reputation is queryable but doesn't restrict

---

### Layer 5: Access Control Policies (Unit Tests)

#### 5.1 Owner-Only Operations
- **UserAccount**
  - ✓ addExecutor() → only owner
  - ✓ revokeExecutor() → only owner
  - ✓ withdraw() → only owner
  - ✓ createAutomation() → only owner

- **PooledAccount**
  - ✓ setManager() → only manager
  - ✓ deposit() → any user
  - ✓ redeem() → share owner
  - ✓ execute() → only manager

#### 5.2 Executor Boundaries
- **What Executors CAN do**
  - ✓ Call vault.execute(strategy, value, params)
  - ✓ Execute any registered strategy
  - ✓ Respects spending limits
  - ✓ Trigger automations (for keepers)

- **What Executors CANNOT do**
  - ✓ Withdraw funds
  - ✓ Add/revoke other executors
  - ✓ Modify spending limits
  - ✓ Disable/enable automations
  - ✓ Change vault owner/manager

#### 5.3 Spend Limit Enforcement
- **Per-Execution Limits**
  - Executor: maxPerExecution = 100 tokens
  - ✓ Execute 50 tokens → pass
  - ✓ Execute 100 tokens → pass
  - ✓ Execute 101 tokens → revert

- **Daily Limits**
  - Executor: maxPerDay = 200 tokens
  - Day 1: execute 100 → remaining 100
  - Execute 50 → remaining 50
  - Execute 51 → revert (over daily limit)
  - Day 2: execute 100 → remaining 100 (reset)

- **Lifetime Limits**
  - Executor: maxTotal = 500 tokens
  - Execute 300 → spentTotal = 300
  - Execute 200 → spentTotal = 500
  - Execute 1 → revert (lifetime exceeded)

- **Day Boundary Logic**
  - Execute at block.timestamp = T
  - Execute again at T + 12h → same day, limits stack
  - Execute at T + 25h → new day, daily reset

---

### Layer 6: Security & Edge Cases (Regression Tests)

#### 6.1 Reentrancy
- ✓ Calls with nonReentrant guards cannot reenter
- ✓ External calls inside execution guarded

#### 6.2 Zero-Address Checks
- ✓ Cannot deploy vault with zero strategy registry
- ✓ Cannot deploy vault with zero executor hub
- ✓ Cannot add zero-address executor
- ✓ Cannot set zero-address manager (PooledAccount)

#### 6.3 Double-Spend Prevention
- ✓ Same automation not executed twice in same block
- ✓ Nonce increments prevent replay

#### 6.4 Token Safety
- ✓ SafeERC20 handles return-false transfers
- ✓ Insufficient balance reverts with clear error
- ✓ Transfer failures caught (TransferFailed)

#### 6.5 State Consistency
- ✓ Failed executions don't corrupt automations
- ✓ Reverted limit checks don't partially consume limit
- ✓ Task deregistration doesn't orphan automations

---

## Test File Organization

```
test/
├── 01_unit/
│   ├── StrategyRegistry.test.js
│   ├── ExecutorHub.test.js
│   ├── AccessControl.test.js
│   ├── UserAccount.test.js
│   └── PooledAccount.test.js
├── 02_integration/
│   ├── ComposableStrategies.test.js
│   ├── AutomationLifecycle.test.js
│   ├── KeeperExecution.test.js
│   └── SpendingLimits.test.js
├── 03_security/
│   ├── Reentrancy.test.js
│   ├── AccessControl.test.js
│   └── EdgeCases.test.js
└── mocks/
    ├── MockERC20.sol
    ├── MockStrategyAdapter.sol
    └── MockLendingProtocol.sol
```

---

## Test Data & Fixtures

### Common Setup
```javascript
// Users
owner = account[0]
executor1 = account[1]
executor2 = account[2]
keeper = account[3]
user1 = account[4]
user2 = account[5]

// Contracts
strategyRegistry = deploy(StrategyRegistry, owner)
executorHub = deploy(ExecutorHub, owner)
userAccount = deploy(UserAccount, owner, strategyRegistry, executorHub)
pooledAccount = deploy(PooledAccount, DAI, keeper, strategyRegistry, executorHub)

// Mock tokens
DAI = deploy(MockERC20, "DAI", 18)
USDC = deploy(MockERC20, "USDC", 6)

// Mock strategies
swapAdapter = deploy(MockSwapAdapter)
lendingAdapter = deploy(MockLendingAdapter)
```

### Spending Limit Scenarios
```javascript
// Role 1: Conservative executor
{executor: executor1, maxPerExecution: 10, maxPerDay: 50, maxTotal: 100}

// Role 2: High-volume keeper
{executor: keeper, maxPerExecution: 1000, maxPerDay: 10000, maxTotal: 50000}

// Role 3: No limits (owner)
{executor: owner, maxPerExecution: MAX_UINT, maxPerDay: MAX_UINT, maxTotal: MAX_UINT}
```

---

## Success Metrics

- ✓ All 100+ unit tests pass
- ✓ Integration tests prove composability (N strategies × 2 account types)
- ✓ Automation executes end-to-end (create → trigger → complete)
- ✓ Spending limits enforced correctly in all scenarios
- ✓ Access control verified (owner-only, executor boundaries, pooled permissions)
- ✓ No security findings (reentrancy, replay, overflow)
- ✓ Code coverage ≥90% on core contracts
- ✓ Gas optimization validated (1000 users = 1 tx not 1000)

---

## Priority Order

1. **Phase 1 (Unit - Blocking)**
   - StrategyRegistry operations
   - AccessControlModule spending limits
   - ExecutorHub executor management

2. **Phase 2 (Vault - Core)**
   - UserAccount access control
   - PooledAccount pooling mechanics
   - Token tracking

3. **Phase 3 (Integration - Feature)**
   - Composable strategies execution
   - Automation lifecycle
   - Keeper execution

4. **Phase 4 (Security - Audit)**
   - Reentrancy guards
   - Access control edge cases
   - Token safety

