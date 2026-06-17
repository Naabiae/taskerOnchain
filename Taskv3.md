This is a sharp architectural insight. You're describing a **capability registry model** — the vault doesn't own strategies, it *discovers* them.

Let me map out what you're actually proposing:Let me just lay this out clearly in text since the diagram tool is unresponsive.

---

## What You're Actually Describing

The current TaskerOnchain model is **task-centric**: user creates a task → deploys a vault → vault is scoped to that task → done.

What you want is **account-centric**: user has **one persistent smart vault** → strategies are global singletons → vault automatically inherits access to every verified strategy.

---

## The Core Architecture Shift

**Current (task-centric):**
```
User → TaskFactory → [TaskCore + TaskVault] per task
                         ↓
                     Adapter (deployed per integration)
```

**Proposed (account-centric):**
```
User → one UserVault (permanent, upgradeable permissions)
              ↓
       StrategyRegistry (protocol-owned, audited)
       ├── GMXTradingStrategy (singleton)
       ├── UniswapDCAStrategy (singleton)
       ├── AutomationStrategy (singleton → keepers execute)
       └── CurveLPStrategy (singleton)

UserVault delegates execution TO strategies,
strategies can never pull funds without user-defined limits.
```

---

## The Key Security Constraint You Already Named

> *"making sure they cannot remove user funds"*

This is the hard part. Strategies need **spend authority** but not **ownership**. The pattern for this is:

```solidity
struct StrategyAllowance {
    address strategy;
    address token;
    uint256 maxAmount;       // hard cap per execution
    uint256 dailyLimit;      // rolling 24h cap
    bool isActive;
}

mapping(address => mapping(address => StrategyAllowance)) public allowances;
// user → strategy → limits
```

The vault never gives blanket approval — it gives **scoped, revocable, rate-limited** execution rights per strategy. The strategy calls `vault.executeWith(strategyAddr, token, amount, calldata)` and the vault enforces the limits before forwarding.

---

## Two Strategy Classes You Correctly Identified

**Class 1 — Immediate execution strategies** (GMX trade, swap, LP deposit):
- User triggers directly or via frontend
- Vault checks allowance → calls strategy → strategy interacts with protocol
- No keeper needed

**Class 2 — Automation strategies** (DCA, stop-loss, recurring transfer):
- User sets parameters + allowances
- Keeper network monitors `canExecute()` on the strategy
- When true, keeper calls `vault.executeAutomation(strategyId, params)`
- Vault verifies keeper is authorized + allowance is valid → executes

---

## What the Protocol's Job Becomes

You nailed this: you're not an adapter marketplace, you're a **strategy auditor and registry**.

Your protocol loop:
1. Strategy submitted → audit (no fund-draining vectors, correct `canExecute` logic, no selfdestruct, no delegatecall abuse)
2. Strategy verified → added to `StrategyRegistry` with a `strategyType` tag (IMMEDIATE or AUTOMATED)
3. UserVault automatically can call any verified strategy — user just sets allowances
4. If a strategy is compromised → protocol pauses it in the registry → **all vaults immediately lose access**, no individual updates needed

That last point is the real power of this model. One registry update protects every user simultaneously.

---

## What This Means for TaskerOnchain V3

The contracts that survive:
- **TaskVault** → becomes **UserVault** (persistent, not per-task)
- **ActionRegistry** → becomes **StrategyRegistry** (same idea, broader scope)
- **ExecutorHub** → survives as keeper registry for automation strategies
- **RewardManager** → survives for keeper incentives

What gets rethought:
- **TaskFactory** → no longer needed (no per-task deployment)
- **TaskCore** → replaced by per-strategy **UserStrategyConfig** (user's params + allowances for a given strategy, stored in their vault)
- EIP-1167 clone pattern → still useful but for UserVaults, not tasks

---

This is a materially cleaner architecture. Want to start designing the `UserVault` interface and the `StrategyRegistry` allowance model in detail? That's the core that everything else hangs off.