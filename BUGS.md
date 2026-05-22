# SmartAccount Protocol — Bug Report & Fix Plan

**Scope:** `SharedAccountModule`, `AccessControlModule`, `RewardManager`, `ExecutorHub`, `BaseVault`, `UserAccount`, `PooledAccount`, `StrategyRegistry`, `VaultFactory`, all interfaces  
**Total Issues Found:** 32  
**Severity Breakdown:** 8 Critical · 10 High · 8 Medium · 6 Low

---

## Severity Definitions

| Level | Meaning |
|---|---|
| **Critical** | Contract is broken or funds can be stolen/locked. Fix before any other work. |
| **High** | Core feature does not work or produces wrong results. Blocks testing. |
| **Medium** | Logic is incorrect but doesn't break the main path. Will cause wrong behaviour in edge cases. |
| **Low** | Code smell, dead code, interface mismatch, or misleading comment. |

---

## CRITICAL — Fix First

---

### C-1: `PooledAccount.execute()` Always Reverts — Manager Cannot Execute Any Strategy

**File:** `contracts/vaults/PooledAccount.sol`  
**Function:** `execute()`

**The Bug:**  
`execute()` calls `_enforceSpendingLimit(msg.sender, amounts[i])`. `msg.sender` here is the manager (only the manager can call `execute()` due to the `OnlyManager` check). But `_enforceSpendingLimit()` checks `_executors[executor].active` first and reverts with `ExecutorNotActive` if the address is not registered. The manager is never registered as an executor — they are a separate address. So **every single call to `execute()` on a PooledAccount will revert.**

```solidity
// CURRENT — broken
function execute(address strategy, uint256 value, bytes calldata params) external nonReentrant {
    if (msg.sender != manager) revert OnlyManager();
    // ...
    _enforceSpendingLimit(msg.sender, amounts[i]); // ← reverts because manager not in _executors
}
```

**The Fix:**  
Remove `_enforceSpendingLimit` from `PooledAccount.execute()`. The PooledAccount manager's spending is bounded by the vault's available balance, not by the `AccessControlModule` executor system. The executor system in `AccessControlModule` is for AI agents delegated by individual users in `UserAccount`, not for pool managers. Remove it entirely from `PooledAccount` or replace it with a per-call capital cap stored separately.

```solidity
// FIXED
function execute(address strategy, uint256 value, bytes calldata params) external nonReentrant {
    if (msg.sender != manager) revert OnlyManager();
    if (circuitBreakerTripped) revert CircuitBreakerActive();
    _checkCircuitBreaker();
    if (circuitBreakerTripped) revert CircuitBreakerActive();
    _beforeExecution(msg.sender, strategy, params);
    nonce++;
    (success, result) = _executeStrategy(strategy, value, params);
    emit StrategyExecuted(strategy, success, nonce);
}
```

---

### C-2: Fair Value Not Locked at Withdrawal Request — Manager Can Pay Any Amount

**File:** `contracts/modules/SharedAccountingModule.sol`  
**Functions:** `_queueWithdrawal()`, `fulfillWithdrawal()`

**The Bug:**  
`WithdrawalRequest.assetAmount` is initialised to `0` when the request is created. `fulfillWithdrawal()` checks `if (assetAmount < req.assetAmount)` which is `if (assetAmount < 0)` — always false. The manager can call `fulfillWithdrawal(id, 1)` and pay 1 wei to a user who redeemed 10,000 shares. **The anti-skimming protection does not exist.**

The comment in `redeem()` says *"shares burned NOW at current NAV price (locking the exit price)"* — but the locked price is never stored.

```solidity
// CURRENT — broken
function _queueWithdrawal(address user, uint256 shares, uint256 lockedAssets) internal {
    withdrawalRequests[id] = WithdrawalRequest({
        shares: shares,
        assetAmount: lockedAssets, // ← this IS passed in correctly
        // ...
    });
}

// But redeem() path B calls: _queueWithdrawal(msg.sender, shares, assetsOut)
// assetsOut was just computed from current sharePrice — this IS correct
// However fulfillWithdrawal then OVERWRITES it:
req.assetAmount = assetAmount; // ← manager overwrites the locked value!
```

There are actually two separate issues here:
1. `redeem()` correctly computes `assetsOut` and passes it as `lockedAssets` — the locked value IS stored.
2. `fulfillWithdrawal()` then **overwrites** `req.assetAmount` with whatever the manager sends, destroying the lock.

**The Fix:**  
Remove the line `req.assetAmount = assetAmount` from `fulfillWithdrawal()`. The locked amount is set at request time and must be immutable. Add the `FulfillBelowFairValue` error and enforce the minimum correctly.

```solidity
// FIXED
error FulfillBelowFairValue(uint256 fairValue, uint256 provided);

function fulfillWithdrawal(uint256 id, uint256 assetAmount) external onlyPoolManager nonReentrant {
    WithdrawalRequest storage req = withdrawalRequests[id];
    if (req.status != WithdrawalStatus.PENDING) revert RequestNotPending();
    if (assetAmount < req.assetAmount) revert FulfillBelowFairValue(req.assetAmount, assetAmount);
    // DO NOT overwrite req.assetAmount — it was locked at request time
    req.status = WithdrawalStatus.FULFILLED;
    asset.safeTransferFrom(msg.sender, address(this), req.assetAmount); // use locked amount
    emit WithdrawalFulfilled(id, req.user, req.assetAmount);
}
```

---

### C-3: Keeper Rewards Are Permanently Locked — No Keeper Can Ever Be Paid

**File:** `contracts/core/RewardManager.sol`  
**Functions:** `distributeReward()`, `claimKeeperRewards()`

**The Bug:**  
`distributeReward()` stores rewards as `keeperRewards[executor][address(0)] += baseReward`. The key `address(0)` means "the zero address token". `claimKeeperRewards(address(0))` then calls `IERC20(address(0)).safeTransfer(msg.sender, amount)` which calls the zero address as an ERC20 contract — this will always revert. **Every keeper reward ever accumulated is permanently locked.** No keeper has ever been or can ever be paid with this code.

Additionally, `baseReward` is `0.0001 ether` — an ETH-denominated amount stored as if it were a token amount. The vault has no ETH stored for this purpose.

**The Fix:**  
Keepers should be paid in the vault's native asset (ETH for gas reimbursement) or in a designated ERC20. The cleanest design for this protocol: the vault pays ETH directly to the keeper at execution time, inside `ExecutorHub.executeAutomation()`, not via a separate accumulation-and-claim flow.

```solidity
// FIXED — in ExecutorHub.executeAutomation()
uint256 gasBefore = gasleft();
bool success = IVault(vault).triggerAutomation(automationId);
uint256 gasUsed = gasBefore - gasleft();

if (success) {
    executor.successfulExecutions++;
    // Pay keeper directly in ETH from the hub's balance
    // Hub is funded by protocol or by vaults paying a small ETH fee on automation creation
    uint256 reward = baseRewardPerExecution;
    if (address(this).balance >= reward) {
        (bool paid,) = msg.sender.call{value: reward}("");
        if (paid) emit KeeperPaid(msg.sender, reward);
    }
}
```

Alternatively, if rewards are ERC20, fix `distributeReward()` to accept a `rewardToken` parameter and store under that key, never under `address(0)`.

---

### C-4: `BaseVault._executeStrategy()` Does Not Decode Adapter Return Value

**File:** `contracts/core/BaseVault.sol`  
**Function:** `_executeStrategy()`

**The Bug:**  
Strategy adapters return `(bool success, bytes memory result)` ABI-encoded. The low-level `.call()` returns `(bool callSuccess, bytes memory rawResult)` where `rawResult` is the ABI encoding of `(bool, bytes)`. Without decoding, `success` reflects whether the call reverted at the EVM level, not whether the adapter reported success. An adapter that returns `(false, "insufficient balance")` will be treated as a success by `BaseVault`. Failed strategies will increment execution counters and be reported as successful.

```solidity
// CURRENT — missing decode
(success, result) = strategy.call{value: value}(
    abi.encodeWithSelector(IStrategyAdapter.execute.selector, address(this), params)
);
// success here = "did the call not revert?" not "did the strategy succeed?"
```

**The Fix:**
```solidity
// FIXED
(bool callSuccess, bytes memory rawResult) = strategy.call{value: value}(
    abi.encodeWithSelector(IStrategyAdapter.execute.selector, address(this), params)
);

if (callSuccess && rawResult.length > 0) {
    (success, result) = abi.decode(rawResult, (bool, bytes));
} else {
    success = false;
    result = rawResult; // raw revert data
}
```

---

### C-5: `BaseVault._triggerAutomation()` Increments `executionCount` on Failure

**File:** `contracts/core/BaseVault.sol`  
**Function:** `_triggerAutomation()`

**The Bug:**  
`executionCount` is incremented unconditionally after `_executeStrategy()` regardless of `success`. If a strategy fails on every call, the automation will exhaust its `maxExecutions` counter without ever successfully executing, then auto-complete. An automation set for 10 DCA rounds will "complete" after 10 failed attempts, never having bought anything.

```solidity
// CURRENT — wrong
(success,) = _executeStrategy(auto_.strategy, 0, auto_.params);
auto_.executionCount++;  // ← increments even if success = false
if (success) {
    auto_.lastExecutionTime = block.timestamp;
}
```

**The Fix:**
```solidity
// FIXED
(success,) = _executeStrategy(auto_.strategy, 0, auto_.params);
if (success) {
    auto_.executionCount++;
    auto_.lastExecutionTime = block.timestamp;
}
// Failed execution: log it but don't count against maxExecutions
```

---

### C-6: Withdrawal Model Inconsistency — `redeem()` vs `requestWithdrawal()` Does Not Exist

**File:** `contracts/modules/SharedAccountingModule.sol`, `test/01_unit/ShareAccounting.test.ts`

**The Bug:**  
All tests call `pool.requestWithdrawal(shares)` but the contract exposes `redeem(shares)`. These are not the same function. The contract's `redeem()` attempts an instant transfer first (Path A), and only queues if there's insufficient liquidity (Path B). The tests describe a **pure queue model** where every withdrawal is queued regardless of liquidity, shares are burned immediately, and claims happen separately.

The two models are architecturally incompatible. The hybrid model (instant if liquid) creates a race condition where two users redeeming simultaneously might get different treatment despite identical positions. The pure queue model is simpler, safer, and what the tests describe.

**The Fix:**  
Adopt the pure queue model. Rename `redeem()` to `requestWithdrawal()`. Remove Path A entirely. Every withdrawal is queued. Shares are burned at current NAV price (the lock). Manager fulfills. User claims.

```solidity
// FIXED — rename and simplify
function requestWithdrawal(uint256 shares) external nonReentrant returns (uint256 id) {
    if (shares == 0) revert ZeroAmount();
    if (_shares[msg.sender] < shares) revert InsufficientShares();

    // Lock the fair value at current NAV — this price is immutable after this point
    uint256 lockedAssets = (shares * sharePrice()) / 1e18;

    // Burn shares immediately — price is locked
    _shares[msg.sender] -= shares;
    totalShares -= shares;
    // Reduce capital baseline proportionally
    if (totalShares + shares > 0) {
        totalCapitalDeposited = totalCapitalDeposited * totalShares / (totalShares + shares);
    }

    id = _queueWithdrawal(msg.sender, shares, lockedAssets);
}
```

---

### C-7: Serial Fulfillment Breaks NAV — First User Gets All Assets

**File:** `contracts/modules/SharedAccountingModule.sol`  
**Function:** `fulfillWithdrawal()`  
**Related:** C-2, C-6

**The Bug:**  
When multiple users request withdrawal simultaneously and the manager fulfills them one by one, `totalAssets()` changes after each claim because shares are already burned but deployed capital is unchanged. If users A, B, C each have 1/3 of shares and all request withdrawal at NAV=3000:

- A's fairValue locked at request = 1000 ✓ (if C-2 is fixed)
- B's fairValue locked at request = 1000 ✓
- C's fairValue locked at request = 1000 ✓
- Manager fulfills A: sends 1000, vault liquid = original + 1000
- Manager fulfills B: sends 1000
- Manager fulfills C: sends 1000
- Total paid = 3000 ✓

This is actually correct **if** C-2 is fixed (fair value locked at request time). The test's concern about serial fulfillment is only a problem when `assetAmount` is computed at fulfillment time using `totalAssets()` and remaining `totalShares`. Since fixing C-2 locks the value at request time, C-7 resolves as a consequence.

**The Fix:** Fix C-2. The serial fulfillment problem disappears because each user's payout is pre-computed and immutable.

---

### C-8: `VaultFactory` Is Non-Functional — Always Reverts

**File:** `contracts/core/VaultFactory.sol`  
**Function:** `createVault()`

**The Bug:**  
`createVault()` contains `revert("Use UserVault directly")` as its entire body. The factory cannot deploy any vault. There is no EIP-1167 clone deployment. The `registerVault()` function allows anyone to register any address as their vault with no validation.

**The Fix:**  
Implement proper EIP-1167 minimal proxy clone deployment.

```solidity
import "@openzeppelin/contracts/proxy/Clones.sol";

contract VaultFactory is Ownable {
    using Clones for address;

    address public immutable userAccountImpl;
    address public immutable pooledAccountImpl;
    address public strategyRegistry;
    address public executorHub;

    mapping(address => address[]) public userAccounts;
    address[] public allAccounts;

    function deployUserAccount() external returns (address account) {
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, userAccounts[msg.sender].length));
        account = userAccountImpl.cloneDeterministic(salt);
        IUserAccount(account).initialize(msg.sender, strategyRegistry, executorHub);
        userAccounts[msg.sender].push(account);
        allAccounts.push(account);
        emit AccountDeployed(msg.sender, account, AccountType.USER);
    }

    function deployPooledAccount(address asset, uint256 feePercentage) external returns (address account) {
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        account = pooledAccountImpl.cloneDeterministic(salt);
        IPooledAccount(account).initialize(asset, msg.sender, strategyRegistry, executorHub, feePercentage);
        allAccounts.push(account);
        emit AccountDeployed(msg.sender, account, AccountType.POOLED);
    }
}
```

---

## HIGH — Fix Before Core Testing

---

### H-1: `deployedCapital` Accounting Creates Phantom NAV

**File:** `contracts/modules/SharedAccountingModule.sol`  
**Function:** `updateDeployedCapital()`, `totalAssets()`

**The Bug:**  
`totalAssets() = asset.balanceOf(address(this)) + deployedCapital`. When the manager calls `updateDeployedCapital(800)` **without any tokens leaving the vault**, the vault's physical balance is still the original amount. NAV becomes `vaultBalance + 800` — double-counting the 800 that was never actually deployed.

The intent is: "800 tokens left the vault to a strategy, and are temporarily outside." But there is no mechanism enforcing that tokens actually left. The manager calls a trusted setter. This means:

1. Manager calls `updateDeployedCapital(1000000e6)` with no tokens deployed → NAV inflates by $1M
2. New users deposit at inflated share price, getting fewer shares than fair
3. Manager calls `updateDeployedCapital(0)` → NAV collapses
4. New users' shares are worth far less than they paid

**The Fix:**  
Two options:

**Option A (Trustless):** Remove `deployedCapital` entirely. NAV = `balanceOf(this)`. Strategies that take tokens out of the vault are tracked by the vault's actual balance decreasing. Positions that hold value outside the vault (perps, prediction markets) must return to the vault before NAV reflects the gain. This is the safe model.

**Option B (Trusted with constraints):** Keep `deployedCapital` but add validation: `updateDeployedCapital(newAmount)` should only increase by the difference between last known balance and current balance (tokens that actually left). Add a `_lastKnownBalance` state variable and enforce it.

Option A is strongly recommended for this protocol stage.

---

### H-2: `AccessControlModule` Spending Limits Are Token-Agnostic — Wrong Magnitude

**File:** `contracts/modules/AccessControlModule.sol`  
**Function:** `_enforceSpendingLimit()`

**The Bug:**  
Spending limits (`maxPerExecution`, `maxPerDay`, `maxTotal`) are raw uint256 numbers with no token or decimal context. When `UserAccount.execute()` calls `_enforceSpendingLimit(executor, amounts[i])`, `amounts[i]` comes from `getTokenRequirements()` which returns token-native amounts. A USDC amount of 1000 USDC = `1000e6 = 1,000,000,000`. An ETH amount of 1 ETH = `1e18`. A limit of `1000` means nothing without knowing the token's decimals. An executor set with `maxPerExecution = 1000` can trade 1000 USDC (essentially nothing) OR 1000 wei of ETH (also nothing) — or interpreted wrongly, 1000 units without decimals.

**The Fix:**  
Add a `token` parameter to the spending rule and track limits per token with decimal-normalised amounts, or require limits to be specified in the same decimal precision as the token. The cleanest fix:

```solidity
struct SpendingRule {
    address token;        // which token this limit applies to
    uint256 maxPerExecution; // in token's native units (e.g. 100e6 for 100 USDC)
    uint256 maxPerDay;
    uint256 maxTotal;
    // ... tracking fields
}

mapping(address => mapping(address => SpendingRule)) internal _spendingRules; // executor => token => rule

function _enforceSpendingLimitForToken(address executor, address token, uint256 amount) internal { ... }
```

---

### H-3: `RewardManager.distributeReward()` Always Records Executions as Failed

**File:** `contracts/core/RewardManager.sol`  
**Function:** `distributeReward()`

**The Bug:**  
Success vs failure is determined by `if (gasUsed > 0)`. `ExecutorHub` always passes `gasUsed = 0`. Therefore `keeperFailedExecutions[executor]++` runs on every single execution regardless of whether it succeeded. The reputation system (even if it were used) is permanently recording every execution as a failure.

**The Fix:**  
Pass an explicit `success` boolean from `ExecutorHub`.

```solidity
// ExecutorHub
function executeAutomation(address vault, uint256 automationId) external onlyExecutor {
    bool success = IVault(vault).triggerAutomation(automationId);
    if (rewardManager != address(0)) {
        IRewardManager(rewardManager).distributeReward(vault, msg.sender, baseRewardPerExecution, success);
    }
}

// RewardManager
function distributeReward(address vault, address executor, uint256 baseReward, bool success)
    external onlyExecutorHub returns (uint256)
{
    if (success) {
        keeperSuccessfulExecutions[executor]++;
    } else {
        keeperFailedExecutions[executor]++;
    }
    // ... reward distribution
}
```

---

### H-4: `IExecutorHub` Interface Not Implemented by `ExecutorHub.sol`

**File:** `contracts/core/ExecutorHub.sol`, `contracts/interfaces/IExecutorHub.sol`

**The Bug:**  
The interface declares 5 functions that `ExecutorHub.sol` does not implement:

| Function | In Interface | In Implementation |
|---|---|---|
| `executeAutomationBatch()` | ✓ | ✗ |
| `canExecute(address, uint256)` | ✓ | ✗ |
| `getTasksByVault()` | ✓ | ✗ |
| `getExecutableTasks()` | ✓ | ✗ |
| `updateTaskParams()` | ✓ | ✗ |

`ExecutorHub` cannot be cast to `IExecutorHub`. Any code that imports and uses `IExecutorHub` to interact with `ExecutorHub` will fail at runtime.

**The Fix:**  
Implement all missing functions. `getExecutableTasks()` is particularly important for the keeper bot discovery loop.

```solidity
function getExecutableTasks() external view returns (Task[] memory) {
    Task[] memory temp = new Task[](_taskKeys.length);
    uint256 count;
    for (uint256 i = 0; i < _taskKeys.length; i++) {
        TaskKey memory key = _taskKeys[i];
        Task storage task = _tasks[key.vault][key.automationId];
        if (!task.active) continue;
        try IStrategyAdapter(task.strategy).canExecute(key.vault, task.params)
            returns (bool canExec, string memory)
        {
            if (canExec) { temp[count++] = task; }
        } catch {}
    }
    Task[] memory result = new Task[](count);
    for (uint256 i = 0; i < count; i++) result[i] = temp[i];
    return result;
}
```

---

### H-5: `BaseVault._triggerAutomation()` Has Broken `canExecute()` Fallback

**File:** `contracts/core/BaseVault.sol`  
**Function:** `_triggerAutomation()`

**The Bug:**  
The fallback for adapters that don't implement the new `canExecute(address, bytes)` signature uses `staticcall` with `"canExecute(bytes)"`. But every adapter in the codebase now uses `canExecute(address, bytes)` (the new signature per `IStrategyAdapter.sol`). The fallback will never match any existing adapter. If the primary `try` fails for any reason, the fallback also fails, and the automation reverts with a confusing `InvalidParams("canExecute failed")` error.

**The Fix:**  
Remove the fallback entirely. All adapters must implement `canExecute(address, bytes)` as per the interface. Document this as a breaking change.

```solidity
// FIXED — no fallback
(bool canExec, string memory reason) = IStrategyAdapter(auto_.strategy)
    .canExecute(address(this), auto_.params);
if (!canExec) revert ConditionsNotMet(automationId, reason);
```

---

### H-6: `BaseVault` Defines a Local `IExecutorHub` That Shadows the Real Interface

**File:** `contracts/core/BaseVault.sol` (bottom of file)

**The Bug:**  
```solidity
interface IExecutorHub {
    function registerTask(uint256 id, address strategy, bytes calldata params) external;
    function removeTask(uint256 id) external;
}
```
This is a stripped-down local interface defined at the bottom of `BaseVault.sol`. It shadows the full `IExecutorHub` from `contracts/interfaces/IExecutorHub.sol`. `BaseVault` never imports the real interface. Missing from the local interface: `updateTaskParams()` — so automations updated via `updateAutomation()` cannot push parameter changes to the hub.

**The Fix:**  
Delete the local `IExecutorHub` from `BaseVault.sol`. Add the import:
```solidity
import "../interfaces/IExecutorHub.sol";
```

---

### H-7: `BaseVault.createAutomation()` Signature Mismatches `IUserVault`

**File:** `contracts/core/BaseVault.sol`, `contracts/interfaces/IUserVault.sol`

**The Bug:**  
```solidity
// IUserVault
function createAutomation(address strategy, bytes calldata params, uint256 maxExecutions, string calldata label) external returns (uint256);

// BaseVault (actual implementation)
function createAutomation(address strategy, bytes calldata params, uint256 maxExecutions) external returns (uint256);
```
The `label` parameter is missing from `BaseVault` and from the `Automation` struct in `BaseVault`. The interface, the `IUserVault.Automation` struct, and the tests all include labels. Any code using `IUserVault` to call `createAutomation` with a label will fail.

**The Fix:**  
Add `label` to the `Automation` struct in `BaseVault` and to `_createAutomation()` and `createAutomation()` signatures.

---

### H-8: `IUserVault` Functions Not Implemented in `UserAccount` or `BaseVault`

**File:** `contracts/vaults/UserAccount.sol`, `contracts/interfaces/IUserVault.sol`

**The Bug:**  
`IUserVault` defines these functions that have no implementation anywhere:

| Function | Status |
|---|---|
| `setRewardManager()` | Not implemented |
| `releaseReward()` | Not implemented |
| `getAvailableForRewards()` | Not implemented |
| `getExecutableAutomations()` | Not implemented |
| `executeBatch()` | Not implemented |
| `updateAutomation()` | Not implemented |
| `setOperator()` | Replaced by `setExecutor()` — different naming |
| `removeOperator()` | Replaced by `revokeExecutor()` — different naming |

`UserAccount` cannot be used as an `IUserVault`. Any integration code using the interface will fail.

**The Fix:**  
Either implement all missing functions or clean up the interface to match what's actually implemented. Since `releaseReward()` / `setRewardManager()` are part of the reward flow (see C-3), implementing the reward flow correctly will bring these in. The others need explicit implementation.

---

### H-9: `highWaterMark` Only Updates on Deposit — Misses NAV Increases from Strategy Gains

**File:** `contracts/modules/SharedAccountingModule.sol`  
**Function:** `deposit()`, `updateDeployedCapital()`, `extractPerformanceFee()`

**The Bug:**  
`highWaterMark` is updated in `deposit()`:
```solidity
uint256 nav = totalAssets();
if (nav > highWaterMark) highWaterMark = nav;
```
But NAV can increase without a deposit (strategy returns profits, `deployedCapital` increases after a win). The HWM will be stale, causing `extractPerformanceFee()` to use the wrong baseline. Profits above the actual HWM will be missed until the next deposit triggers a HWM update.

Additionally, `extractPerformanceFee()` does:
```solidity
lastFeeExtractionNAV = nav - feeAmount;
```
This should be `lastFeeExtractionNAV = nav` (after the fee is extracted, the new baseline is the post-fee NAV). Setting it to `nav - feeAmount` means the next extraction will see `nav - feeAmount` as the baseline and charge fees on already-taxed gains.

**The Fix:**
```solidity
function updateDeployedCapital(uint256 newAmount) external onlyPoolManager {
    uint256 old = deployedCapital;
    deployedCapital = newAmount;
    // Update HWM if NAV increased
    uint256 currentNAV = totalAssets();
    if (currentNAV > highWaterMark) highWaterMark = currentNAV;
    emit DeployedCapitalUpdated(old, newAmount);
}

// In extractPerformanceFee():
lastFeeExtractionNAV = nav; // not nav - feeAmount
```

---

### H-10: `realizedGains()` Creates Phantom Gains After Partial Withdrawals

**File:** `contracts/modules/SharedAccountingModule.sol`  
**Function:** `realizedGains()`

**The Bug:**  
`realizedGains() = totalAssets() - totalCapitalDeposited`. When a user withdraws, `totalCapitalDeposited` is reduced proportionally. But if the pool made zero gains and half the users withdraw, `totalCapitalDeposited` drops by 50% while `totalAssets()` also drops by the same amount. So far correct. But if users withdraw at a time when the pool is up (NAV > cost basis), `totalCapitalDeposited` drops by the proportional cost basis, not the proportional NAV value. The remaining `totalCapitalDeposited` becomes artificially low relative to remaining `totalAssets()`, creating phantom gains that trigger performance fee extraction.

**The Fix:**  
Track `totalCapitalDeposited` as a per-share cost basis, not an aggregate. Or use a running `costBasisPerShare` metric:
```solidity
uint256 public costBasisPerShare; // updated on deposit, immutable on withdrawal

function deposit(uint256 amount) external nonReentrant {
    uint256 sharesToIssue = _previewDeposit(amount);
    // Update weighted average cost basis
    costBasisPerShare = ((costBasisPerShare * totalShares) + (amount * 1e18 / sharesToIssue * sharesToIssue))
        / (totalShares + sharesToIssue);
    // ... rest of deposit
}

function realizedGains() external view returns (int256) {
    uint256 currentNAVPerShare = sharePrice();
    return int256(currentNAVPerShare) - int256(costBasisPerShare);
}
```

---

## MEDIUM — Fix Before Production

---

### M-1: Reputation System Is Dead Code — Remove It

**File:** `contracts/core/RewardManager.sol`

**The Bug:**  
The contract tracks `keeperSuccessfulExecutions` and `keeperFailedExecutions` but these are never read. The `calculateReward()` function ignores them and returns a flat multiplier. The `getReputationMultiplier()` function from the old interface is gone. Reputation data is accumulated but never used for anything. It wastes gas on every execution.

**The Fix:**  
Delete `keeperSuccessfulExecutions`, `keeperFailedExecutions`, and all related tracking. Keep only what's used for reward calculation.

---

### M-2: `RewardManager` Has Duplicate Functions — `setPlatformFee()` and `setPlatformFeePercentage()`

**File:** `contracts/core/RewardManager.sol`

**The Bug:**  
Two public functions do identical things:
- `setPlatformFeePercentage(uint256)` — primary implementation
- `setPlatformFee(uint256)` — secondary, identical logic

Two withdrawal functions with different signatures:
- `collectPlatformFees(address token, address recipient)` — actual implementation
- `collectFees(address recipient)` — reverts with "Use collectPlatformFees instead"

The interface `IRewardManager` defines `setPlatformFee()` and `collectFees()`. The contract implements the other names primarily. This inconsistency means any code using the interface gets the stub that reverts.

**The Fix:**  
Pick one name for each. Match the interface. Delete the duplicate/stub.

---

### M-3: `IRewardManager` Interface Mismatch with `RewardManager` Implementation

**File:** `contracts/interfaces/IRewardManager.sol`, `contracts/core/RewardManager.sol`

**The Bug:**  
```solidity
// Interface
function distributeReward(address vault, address executor, uint256 baseReward, uint256 gasUsed) external returns (uint256);
function collectFees(address recipient) external returns (uint256);

// Implementation  
function distributeReward(address vault, address executor, uint256 baseReward, uint256 gasUsed) external returns (uint256); // signature matches but logic is broken (see C-3, H-3)
function collectPlatformFees(address token, address recipient) external returns (uint256); // different signature
function collectFees(address recipient) external returns (uint256); // reverts
```

**The Fix:**  
After fixing C-3 and H-3, align the implementation signature to match the interface exactly. Remove the stub `collectFees()`.

---

### M-4: `PooledAccount` Exposes `AccessControlModule` Executor Functions That Do Nothing

**File:** `contracts/vaults/PooledAccount.sol`

**The Bug:**  
`PooledAccount` inherits `SharedAccountModule` which inherits `AccessControlModule`. This means `PooledAccount` exposes `setExecutor()`, `revokeExecutor()`, `getExecutor()`, `getAllExecutors()` — all from `AccessControlModule`. Since `_canExecute()` in `PooledAccount` only checks `caller == manager`, these executor registrations have zero effect on execution permissions. Users or the manager could call `setExecutor()`, see it succeed, and believe they've granted execution access — but no execution is possible for that address.

**The Fix:**  
Override and revert these functions in `PooledAccount`:
```solidity
function setExecutor(address, uint256, uint256, uint256) external pure override {
    revert("Not supported on PooledAccount — only manager can execute");
}
```
Or restructure the inheritance so `PooledAccount` does not inherit `AccessControlModule` at all.

---

### M-5: `BaseVault` Missing `updateAutomation()` — Params Cannot Be Changed Post-Creation

**File:** `contracts/core/BaseVault.sol`

**The Bug:**  
`IUserVault` defines `updateAutomation(uint256 automationId, bytes calldata newParams)`. `BaseVault` has no `_updateAutomation()` internal or public surface. Once an automation is created, its params are immutable. For strategies that need parameter updates (e.g., changing a DCA target price, adjusting a Predict position size), there is no path.

**The Fix:**  
Add to `BaseVault`:
```solidity
function _updateAutomation(uint256 automationId, bytes calldata newParams) internal {
    Automation storage auto_ = _automations[automationId];
    if (auto_.status != AutomationStatus.ACTIVE) revert AutomationNotActive(automationId);
    (bool valid, string memory err) = IStrategyAdapter(auto_.strategy).validateParams(newParams);
    if (!valid) revert InvalidParams(err);
    auto_.params = newParams;
    try IExecutorHub(executorHub).updateTaskParams(automationId, newParams) {} catch {}
    emit AutomationUpdated(automationId, newParams);
}
```

---

### M-6: `PooledAccount` Does Not Call `super` on Diamond Inheritance Overrides

**File:** `contracts/vaults/PooledAccount.sol`

**The Bug:**  
`PooledAccount` overrides `_canExecute()` and `_canWithdraw()` from two parent classes (`BaseVault` and `SharedAccountModule`). The overrides use `override(BaseVault, SharedAccountModule)` correctly in terms of syntax, but the `_canExecute` in `SharedAccountModule` contains useful logic (`_isExecutorActive(caller)`) that is completely bypassed. While this is intentional for `PooledAccount` (only manager executes), the pattern means that if someone adds logic to the base class methods later, it will silently not apply.

**The Fix:**  
Document clearly that `PooledAccount._canExecute` intentionally overrides all parent logic and is the single source of truth for execution access.

---

### M-7: `AccessControlModule.getExecutor()` Name Conflicts with `ExecutorHub.getExecutor()`

**File:** `contracts/modules/AccessControlModule.sol`, `contracts/core/ExecutorHub.sol`

**The Bug:**  
Both expose `getExecutor(address)` as a public function but return completely different structs (`ExecutorRole` vs `Executor`). Since `UserAccount` inherits `AccessControlModule`, calling `userAccount.getExecutor(address)` returns an `ExecutorRole` (the vault-level spending-limited executor), not the hub-level `Executor`. This is confusing and will cause ABI encoding issues if any code tries to use the hub interface against the vault.

**The Fix:**  
Rename `AccessControlModule.getExecutor()` to `getVaultExecutor()` or `getSpendingRole()` to differentiate.

---

### M-8: `VaultFactory.registerVault()` Has No Access Control or Validation

**File:** `contracts/core/VaultFactory.sol`  
**Function:** `registerVault()`

**The Bug:**  
```solidity
function registerVault(address vault) external {
    vaults.push(vault);
    userVaults[msg.sender].push(vault);
    emit VaultCreated(msg.sender, vault);
}
```
Anyone can register any address as a vault, including contracts that are not `UserAccount` instances, EOAs, or malicious contracts. The `vaults` array will contain arbitrary addresses that will fail silently or maliciously when the keeper loop tries to call `triggerAutomation()` on them.

**The Fix:**  
This function should be removed entirely once the factory properly deploys clones (C-8). If a registration path is needed, validate via interface check:
```solidity
function registerVault(address vault) external {
    // Verify it's a real vault with a valid owner
    require(IUserAccount(vault).owner() == msg.sender, "Not your vault");
    // ...
}
```

---

## LOW — Clean Up

---

### L-1: `BaseVault_UserAccount.test.ts` Has an Incomplete Test That Will Fail

**File:** `test/01_unit/BaseVault_UserAccount.test.ts`

The test `"should enforce spend limits for executors"` ends mid-way:
```typescript
it("should enforce spend limits for executors", async function () {
    await userVault.setExecutor(executor.address, 100, 1000, 10000); // <-- doesn't exist on UserAccount
});
```
`UserAccount` does not expose `setExecutor()` in the way this test calls it. The test will fail at runtime. Either complete the test against the correct interface or delete it.

---

### L-2: `BaseVault` Has No `label` in `Automation` Struct Despite Interface Requiring It

**File:** `contracts/core/BaseVault.sol`

The `Automation` struct in `BaseVault` is missing the `label` field that `IUserVault.Automation` has. Events like `AutomationCreated` in `IUserVault` include a label parameter. The `BaseVault` event does not. This inconsistency will cause ABI decoding failures in any frontend or indexer using the `IUserVault` ABI.

---

### L-3: `RewardManager.totalFeesCollected()` Always Returns Zero

**File:** `contracts/core/RewardManager.sol`

```solidity
function totalFeesCollected() external view returns (uint256) {
    return 0; // For simplicity...
}
```
`accumulatedFees` mapping exists but is never incremented anywhere in the contract. The view function is hardcoded to return 0. Any analytics or frontend showing total fees collected will always show $0 regardless of actual fees.

---

### L-4: `StrategyRegistry` Allows Re-registering an Existing Strategy Silently

**File:** `contracts/core/StrategyRegistry.sol`  
**Function:** `registerStrategy()`

If an already-registered strategy address is registered again, the mapping is overwritten and the address is pushed to `_strategyList` again, resulting in duplicate entries. `getAllStrategies()` will return the address twice.

**The Fix:**
```solidity
function registerStrategy(address adapter, string calldata name) external onlyOwner {
    if (adapter == address(0)) revert InvalidAdapter();
    if (_strategies[adapter].adapter != address(0)) revert StrategyAlreadyRegistered(); // add this
    // ...
}
```

---

### L-5: `BaseVault._ensureAllowance()` Has Unreachable Error Path

**File:** `contracts/core/BaseVault.sol`  
**Function:** `_ensureAllowance()`

The function does:
```solidity
(bool ok1,) = address(token).call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
if (!ok1) {
    // allowAfter check below will attempt forceApprove
}
uint256 allowAfter = token.allowance(address(this), spender);
if (allowAfter < amount) {
    revert AllowanceFailed(tokenAddr, spender, amount);
}
```
The comment says "attempt forceApprove" but no forceApprove call exists. If `ok1` is false, the code proceeds to check `allowAfter` which will still be below `amount`, and then correctly reverts. The comment is misleading.

---

### L-6: `SharedAccountModule` Comments Reference Features Not Yet Implemented

**File:** `contracts/modules/SharedAccountingModule.sol`

Comments reference "Phase 2 performance fee extraction" and "share transfers (fast exit)" as future features. Several function comments describe behaviours that differ from the implementation (particularly the withdrawal queue model). Update comments to reflect the actual implementation, and add `TODO:` markers for genuinely planned features.

---

## Fix Priority Order

Execute fixes in this sequence to avoid one fix breaking another:

```
Phase 1 — Unblock Core Functionality (C-1 through C-8)
  1. C-1  Remove _enforceSpendingLimit from PooledAccount.execute()
  2. C-4  Fix _executeStrategy() return value decoding
  3. C-5  Only increment executionCount on success
  4. C-6  Rename redeem() to requestWithdrawal(), adopt pure queue model
  5. C-2  Lock assetAmount at request time, remove manager override
  6. C-7  Verify serial fulfillment is correct after C-2 fix (it will be)
  7. C-3  Fix keeper reward payment — direct ETH or proper ERC20 flow
  8. C-8  Implement VaultFactory with EIP-1167 clone deployment

Phase 2 — Fix Accounting Logic (H-1 through H-10)
  1. H-2  Add token-aware spending limits to AccessControlModule
  2. H-1  Decide on deployedCapital model (remove or constrain)
  3. H-9  Fix highWaterMark update logic and lastFeeExtractionNAV
  4. H-10 Fix realizedGains() baseline calculation
  5. H-3  Pass success boolean through ExecutorHub to RewardManager
  6. H-4  Implement missing IExecutorHub functions
  7. H-5  Remove broken canExecute() fallback
  8. H-6  Delete local IExecutorHub from BaseVault, import real interface
  9. H-7  Add label to Automation struct and createAutomation signature
  10. H-8  Implement missing IUserVault functions

Phase 3 — Interface Cleanup and Dead Code Removal (M-1 through M-8)
  1. M-1  Remove reputation system dead code from RewardManager
  2. M-2  Deduplicate setPlatformFee / collectFees functions
  3. M-3  Align IRewardManager with RewardManager implementation
  4. M-4  Override and revert AccessControlModule methods on PooledAccount
  5. M-5  Add updateAutomation() to BaseVault
  6. M-6  Document PooledAccount inheritance override intent
  7. M-7  Rename AccessControlModule.getExecutor() to getVaultExecutor()
  8. M-8  Remove registerVault() or add validation

Phase 4 — Polish (L-1 through L-6)
  1. L-1  Fix or delete incomplete test
  2. L-2  Add label to BaseVault Automation struct
  3. L-3  Implement or remove totalFeesCollected()
  4. L-4  Add duplicate check to StrategyRegistry.registerStrategy()
  5. L-5  Fix misleading comment in _ensureAllowance()
  6. L-6  Update all comments to match implementation
```

---

## Test Coverage Gaps

After fixes, these scenarios have no test coverage and should be added:

| Scenario | Priority |
|---|---|
| Strategy returns `(false, reason)` — BaseVault treats as failed | High |
| Keeper tries to claim rewards — payment actually arrives in ETH | High |
| User requests withdrawal with open position, manager fulfills after close | High |
| Two users request withdrawal simultaneously, both get correct fair value | High |
| PooledAccount manager executes strategy, NAV updates correctly | High |
| Automation runs `maxExecutions` times, auto-cancels from hub | Medium |
| Executor spending limit exceeded mid-batch — correct rollback | Medium |
| Circuit breaker trips, manager resets, execution resumes | Medium |
| StrategyRegistry deactivated mid-automation — automation correctly blocked | Medium |
| Factory deploys clone, clone is initialized exactly once | Medium |

---

*Report generated from static analysis of commit state as of May 2026. All line numbers reference the documents provided.*