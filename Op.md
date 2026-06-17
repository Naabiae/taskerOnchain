Write AutomationWatcher contract
Write AutomationWatcher contract

Write AutomationWatcher contract
bash

cat > /home/claude/tasker-v3/contracts/reactive/AutomationWatcher.sol << 'SOLIDITY'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IUserVault.sol";
import "../interfaces/IStrategyAdapter.sol";
import "../interfaces/IExecutorHub.sol";

/**
 * @title AutomationWatcher
 * @notice Keepers watch this contract. It reads automation state from vaults
 *         and triggers follow-up automations based on execution status.
 *
 * @dev HOW IT WORKS
 *      A "Watch" is: 
 *        "watch automationA on vault X — when it has been executed,
 *         trigger automationB on the same vault"
 *
 *      Keeper loop (off-chain):
 *        1. Call getExecutableWatches() → returns list of watchIds ready to act
 *        2. Call actOnWatch(watchId) for each
 *        3. Done — watcher reads vault state, triggers downstream automation
 *
 *      The condition is NOT about events. It's about reading the automation's
 *      executionCount / lastExecutionTime directly from the vault and asking:
 *        - "Has it run at least once since I last checked?"
 *        - "Has it run exactly N times total?"  
 *        - "Has it NOT run in the last X seconds (missed execution)?"
 *        - "Has it completed (status = COMPLETED)?"
 *
 *      EXAMPLE FLOWS:
 *
 *      1. Self-compounding yield:
 *         Watch: automation 0 (DCA: USDC→ETH) executed
 *         Act:   trigger automation 1 (deposit ETH into Aave)
 *
 *      2. Missed execution alert / fallback:
 *         Watch: automation 0 has NOT run in 8 days (DCA should run weekly)
 *         Act:   trigger automation 2 (fallback: buy ETH directly from reserve)
 *
 *      3. Milestone-based:
 *         Watch: automation 0 has run exactly 10 times (10 DCA rounds done)
 *         Act:   trigger automation 3 (rotate all ETH to Aave for compounding)
 *
 *      4. Completion handler:
 *         Watch: automation 0 status = COMPLETED
 *         Act:   trigger automation 4 (final rebalance)
 *
 * GUARDRAILS:
 *   - Each watch has a cooldown (prevents keeper from acting twice in same window)
 *   - Max acts per watch (so a watch doesn't fire infinitely)
 *   - Owner can pause/cancel watches
 *   - Watcher never touches funds directly — it only calls triggerAutomation
 */
contract AutomationWatcher is Ownable, ReentrancyGuard {

    // ─────────────────────────────────────────────────────────────────────────
    // Enums
    // ─────────────────────────────────────────────────────────────────────────

    enum WatchCondition {
        EXECUTED_ONCE,        // watchedAutomation has run at least once since last check
        EXECUTED_N_TIMES,     // watchedAutomation.executionCount >= targetCount
        NOT_EXECUTED_IN,      // watchedAutomation has NOT run within stalePeriod seconds
        COMPLETED             // watchedAutomation.status == COMPLETED
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────────────

    struct Watch {
        uint256 id;
        address vault;

        // What to watch
        uint256 watchedAutomationId;      // The automation whose state we monitor
        WatchCondition condition;
        uint256 targetCount;              // Used with EXECUTED_N_TIMES
        uint256 stalePeriod;              // Used with NOT_EXECUTED_IN (seconds)

        // What to do when condition is met
        uint256 actAutomationId;          // Automation to trigger on the vault

        // Control
        bool active;
        uint256 cooldown;                 // Min seconds between acts
        uint256 maxActs;                  // 0 = unlimited
        uint256 actCount;                 // How many times this watch has acted
        uint256 lastActTime;              // Timestamp of last act
        uint256 lastSeenExecutionCount;   // Snapshot at last act (for EXECUTED_ONCE)

        string label;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    address public executorHub;

    uint256 private _nextWatchId;

    mapping(uint256 => Watch) private _watches;
    uint256[] private _watchIds;                           // active only (swap-and-pop)
    mapping(address => uint256[]) private _vaultWatches;  // vault → watchIds

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event WatchCreated(
        uint256 indexed watchId,
        address indexed vault,
        uint256 watchedAutomationId,
        uint256 actAutomationId,
        WatchCondition condition
    );

    event WatchActed(
        uint256 indexed watchId,
        address indexed vault,
        uint256 watchedAutomationId,
        uint256 actAutomationId,
        uint256 actCount
    );

    event WatchCancelled(uint256 indexed watchId);
    event WatchCompleted(uint256 indexed watchId);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error WatchNotFound(uint256 watchId);
    error NotVaultOwner();
    error WatchNotReady(uint256 watchId, string reason);
    error WatchAlreadyInactive(uint256 watchId);
    error SelfWatch(uint256 automationId);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _executorHub, address _owner) Ownable(_owner) {
        require(_executorHub != address(0), "Invalid hub");
        executorHub = _executorHub;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Create / Cancel Watches (vault owner only)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a watch on an automation.
     *
     * @param vault               Vault that owns both automations
     * @param watchedAutomationId Automation whose execution state we monitor
     * @param condition           What state change triggers the act
     * @param targetCount         For EXECUTED_N_TIMES: act when count reaches this
     * @param stalePeriod         For NOT_EXECUTED_IN: act if no run in this many seconds
     * @param actAutomationId     Automation to trigger when condition is met
     * @param cooldown            Min seconds between consecutive acts (0 = no cooldown)
     * @param maxActs             Max times to act (0 = unlimited)
     * @param label               Human-readable name
     */
    function createWatch(
        address vault,
        uint256 watchedAutomationId,
        WatchCondition condition,
        uint256 targetCount,
        uint256 stalePeriod,
        uint256 actAutomationId,
        uint256 cooldown,
        uint256 maxActs,
        string calldata label
    ) external returns (uint256 watchId) {
        // Only vault owner can create watches for their vault
        if (IUserVault(vault).owner() != msg.sender) revert NotVaultOwner();

        // No self-watching (A watches A and triggers A = infinite loop)
        if (watchedAutomationId == actAutomationId) revert SelfWatch(watchedAutomationId);

        // Validate condition-specific params
        if (condition == WatchCondition.EXECUTED_N_TIMES) {
            require(targetCount > 0, "targetCount must be > 0");
        }
        if (condition == WatchCondition.NOT_EXECUTED_IN) {
            require(stalePeriod > 0, "stalePeriod must be > 0");
        }

        // Verify both automations exist on this vault
        IUserVault.Automation memory watched = IUserVault(vault).getAutomation(watchedAutomationId);
        IUserVault.Automation memory act = IUserVault(vault).getAutomation(actAutomationId);
        require(watched.id == watchedAutomationId, "Watched automation not found");
        require(act.id == actAutomationId, "Act automation not found");
        require(
            act.status == IUserVault.AutomationStatus.ACTIVE,
            "Act automation not active"
        );

        watchId = _nextWatchId++;

        _watches[watchId] = Watch({
            id: watchId,
            vault: vault,
            watchedAutomationId: watchedAutomationId,
            condition: condition,
            targetCount: targetCount,
            stalePeriod: stalePeriod,
            actAutomationId: actAutomationId,
            active: true,
            cooldown: cooldown,
            maxActs: maxActs,
            actCount: 0,
            lastActTime: 0,
            // Snapshot current execution count so EXECUTED_ONCE
            // only fires on NEW executions after watch creation
            lastSeenExecutionCount: watched.executionCount,
            label: label
        });

        _watchIds.push(watchId);
        _vaultWatches[vault].push(watchId);

        emit WatchCreated(watchId, vault, watchedAutomationId, actAutomationId, condition);
    }

    /**
     * @notice Cancel a watch — vault owner only.
     */
    function cancelWatch(uint256 watchId) external {
        Watch storage w = _watches[watchId];
        if (w.vault == address(0)) revert WatchNotFound(watchId);
        if (!w.active) revert WatchAlreadyInactive(watchId);
        if (IUserVault(w.vault).owner() != msg.sender) revert NotVaultOwner();

        w.active = false;
        _removeWatchId(watchId);

        emit WatchCancelled(watchId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Act on Watch (keeper-called)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Keeper calls this when a watch is ready.
     *         Reads automation state from vault, checks condition, triggers act.
     *
     * @dev Steps:
     *      1. Load watch
     *      2. Check condition against live vault state (executionCount, lastExecutionTime, status)
     *      3. Check cooldown and maxActs
     *      4. Call ExecutorHub.executeAutomation(vault, actAutomationId)
     *      5. Update watch state
     */
    function actOnWatch(uint256 watchId) external nonReentrant {
        Watch storage w = _watches[watchId];
        if (w.vault == address(0)) revert WatchNotFound(watchId);
        if (!w.active) revert WatchAlreadyInactive(watchId);

        // Check cooldown
        if (w.cooldown > 0 && block.timestamp < w.lastActTime + w.cooldown) {
            revert WatchNotReady(watchId, "Cooldown active");
        }

        // Check max acts
        if (w.maxActs > 0 && w.actCount >= w.maxActs) {
            // Auto-deactivate
            w.active = false;
            _removeWatchId(watchId);
            emit WatchCompleted(watchId);
            revert WatchNotReady(watchId, "Max acts reached");
        }

        // Read live automation state from vault
        IUserVault.Automation memory watched = IUserVault(w.vault).getAutomation(w.watchedAutomationId);

        // Check condition
        (bool ready, string memory reason) = _checkCondition(w, watched);
        if (!ready) revert WatchNotReady(watchId, reason);

        // Snapshot before acting
        uint256 prevExecutionCount = w.lastSeenExecutionCount;

        // Update watch state
        w.actCount++;
        w.lastActTime = block.timestamp;
        w.lastSeenExecutionCount = watched.executionCount;

        // Trigger the act automation via ExecutorHub
        // ExecutorHub will call vault.triggerAutomation() which checks canExecute()
        IExecutorHub(executorHub).executeAutomation(w.vault, w.actAutomationId);

        emit WatchActed(
            watchId,
            w.vault,
            w.watchedAutomationId,
            w.actAutomationId,
            w.actCount
        );

        // Auto-deactivate if max acts reached after this one
        if (w.maxActs > 0 && w.actCount >= w.maxActs) {
            w.active = false;
            _removeWatchId(watchId);
            emit WatchCompleted(watchId);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Condition Check
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Read live automation state and evaluate the watch condition.
     *      Pure state read — no external calls except the vault getter.
     */
    function _checkCondition(
        Watch storage w,
        IUserVault.Automation memory watched
    ) internal view returns (bool ready, string memory reason) {

        if (w.condition == WatchCondition.EXECUTED_ONCE) {
            // Has it run at least once MORE since we last checked?
            if (watched.executionCount > w.lastSeenExecutionCount) {
                return (true, "");
            }
            return (false, "Not executed since last check");
        }

        if (w.condition == WatchCondition.EXECUTED_N_TIMES) {
            // Has total execution count reached the target?
            if (watched.executionCount >= w.targetCount) {
                return (true, "");
            }
            return (false, "Target execution count not reached");
        }

        if (w.condition == WatchCondition.NOT_EXECUTED_IN) {
            // Has it been more than stalePeriod since the last run?
            // Edge case: never run at all — check createdAt instead
            uint256 lastRun = watched.lastExecutionTime > 0
                ? watched.lastExecutionTime
                : watched.createdAt;

            if (block.timestamp > lastRun + w.stalePeriod) {
                return (true, "");
            }
            return (false, "Automation ran recently, not stale");
        }

        if (w.condition == WatchCondition.COMPLETED) {
            if (watched.status == IUserVault.AutomationStatus.COMPLETED) {
                return (true, "");
            }
            return (false, "Automation not yet completed");
        }

        return (false, "Unknown condition");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Functions (keeper discovery)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Check if a single watch is ready to act.
     *         Keepers call this before actOnWatch() to avoid wasting gas.
     */
    function isWatchReady(uint256 watchId)
        external view returns (bool ready, string memory reason)
    {
        Watch storage w = _watches[watchId];
        if (w.vault == address(0)) return (false, "Watch not found");
        if (!w.active) return (false, "Watch inactive");

        if (w.cooldown > 0 && block.timestamp < w.lastActTime + w.cooldown) {
            return (false, "Cooldown active");
        }
        if (w.maxActs > 0 && w.actCount >= w.maxActs) {
            return (false, "Max acts reached");
        }

        IUserVault.Automation memory watched = IUserVault(w.vault).getAutomation(w.watchedAutomationId);
        return _checkCondition(w, watched);
    }

    /**
     * @notice Get all watchIds that are currently ready to act.
     *         Keepers call this to build their execution list for the sweep.
     *
     * @dev Single pass — collects ready watches into candidates array, then trims.
     *      Makes one external view call per active watch (the vault getter).
     *      Intended for off-chain keeper bots, not on-chain use.
     */
    function getReadyWatches() external view returns (uint256[] memory readyIds) {
        uint256[] memory candidates = new uint256[](_watchIds.length);
        uint256 count;

        for (uint256 i = 0; i < _watchIds.length; i++) {
            uint256 watchId = _watchIds[i];
            Watch storage w = _watches[watchId];

            if (!w.active) continue;
            if (w.cooldown > 0 && block.timestamp < w.lastActTime + w.cooldown) continue;
            if (w.maxActs > 0 && w.actCount >= w.maxActs) continue;

            // Read vault state
            IUserVault.Automation memory watched;
            try IUserVault(w.vault).getAutomation(w.watchedAutomationId)
                returns (IUserVault.Automation memory a)
            {
                watched = a;
            } catch {
                continue; // vault call failed, skip
            }

            (bool ready,) = _checkCondition(w, watched);
            if (ready) {
                candidates[count++] = watchId;
            }
        }

        readyIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            readyIds[i] = candidates[i];
        }
    }

    /**
     * @notice Get all watches for a vault.
     */
    function getVaultWatches(address vault) external view returns (Watch[] memory) {
        uint256[] storage ids = _vaultWatches[vault];
        Watch[] memory result = new Watch[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = _watches[ids[i]];
        }
        return result;
    }

    /**
     * @notice Get all active watches.
     */
    function getAllActiveWatches() external view returns (Watch[] memory) {
        Watch[] memory result = new Watch[](_watchIds.length);
        for (uint256 i = 0; i < _watchIds.length; i++) {
            result[i] = _watches[_watchIds[i]];
        }
        return result;
    }

    /**
     * @notice Get a single watch.
     */
    function getWatch(uint256 watchId) external view returns (Watch memory) {
        if (_watches[watchId].vault == address(0)) revert WatchNotFound(watchId);
        return _watches[watchId];
    }

    function getWatchCount() external view returns (uint256) {
        return _watchIds.length;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: Array Management (swap-and-pop)
    // ─────────────────────────────────────────────────────────────────────────

    function _removeWatchId(uint256 watchId) internal {
        uint256 len = _watchIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (_watchIds[i] == watchId) {
                _watchIds[i] = _watchIds[len - 1];
                _watchIds.pop();
                return;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function setExecutorHub(address newHub) external onlyOwner {
        require(newHub != address(0), "Invalid hub");
        executorHub = newHub;
    }
}
SOLIDITY
echo "done"
Output

done
Done