# BaseVault is NOT a Vault — It's a Smart Account

## The Real Problem You're Solving

**Current AI Trading Model**:
```
User → gives private key to AI → AI signs txs → AI can:
  ✅ Trade
  ❌ Withdraw
  ❌ Drain account
  = Private key exposure = custody risk
```

**Your Model**:
```
User → deploys SmartAccount → grants AI execution role
  ✅ AI can execute ANY strategy on ANY protocol
  ❌ AI cannot withdraw funds (no transferToken/transferNative)
  ❌ AI cannot transfer ownership
  = AI has execution authority, not custody authority
  = Composable strategies = no need for AI-specific integrations
```

## Why This is Different

**Traditional Smart Accounts** (Argent, Gnosis):
- Multi-sig gates all actions
- Slow (needs approval from guardian)
- No native automation

**Your SmartAccount**:
- Native automation (automations trigger via permissionless keeper network)
- Composable execution (call ANY strategy, AI doesn't need protocol knowledge)
- Role-based (AI has execution role, not custody role)
- Execution still works even if AI goes down (keepers execute automations)

## Rename Everything

```
BaseVault        → SmartAccount
UserVault        → SingleUserAccount
ShareVault       → PooledAccount
SingleOwnerModule → OwnershipLayer
ExecutorHub       → AutomationExecutor (keeper network)
Strategy Adapter  → Protocol Bridge
```

The architecture stays the same. The naming reflects reality.

---

## SmartAccount Behavior

```solidity
contract SmartAccount is ReentrancyGuard {
    
    // Owned by a user
    address public owner;
    
    // AI agents with execution authority (NOT custody)
    struct ExecutionRole {
        bool canExecuteStrategies;
        bool canCreateAutomations;
        bool canCancelAutomations;
        uint256 maxValuePerExecution;  // rate limit on capital deployed
        uint256 maxValuePerDay;
        uint256 maxValueLifetime;
    }
    
    mapping(address => ExecutionRole) public agents;
    
    // Automations: native execution engine
    mapping(uint256 => Automation) public automations;
    
    // This account holds tokens. Keepers execute automations.
    // AI agents create automations + can execute immediate strategies.
    
    // === What AI Can Do ===
    
    function createAutomation(
        address protocolBridge,  // e.g., UniswapBridge, LidoBridge
        bytes calldata bridgeParams
    ) external onlyAgent {
        // AI creates automation: "When price dips 5%, execute swap"
        // This doesn't move funds. It just schedules execution.
        _automations[nextId] = Automation(...);
    }
    
    function executeStrategy(
        address protocolBridge,
        bytes calldata bridgeParams
    ) external onlyAgent returns (bool) {
        // AI executes immediately: "Swap now"
        // Bridge pulls tokens via approval, executes, returns output tokens
        // Bridge NEVER has withdrawal authority
        return _executeProtocol(protocolBridge, bridgeParams);
    }
    
    // === What AI CANNOT Do ===
    
    // transferToken(recipient, amount) — OWNER ONLY
    // transferOwnership(newOwner) — OWNER ONLY
    // setAgent permissions — OWNER ONLY (can revoke AI anytime)
    
    // === Keepers Execute Automations ===
    
    function triggerAutomation(uint256 automationId) external onlyKeeper {
        Automation storage auto_ = _automations[automationId];
        // Even if AI is down, this runs
        _executeProtocol(auto_.bridge, auto_.params);
    }
}
```

---

## The Composability Win (The Real Thesis)

**Without SmartAccount**:
```
User needs to trade on Uniswap, Aave, Curve, GMX
→ Needs AI with Uniswap knowledge
→ Needs AI with Aave knowledge
→ Needs AI with Curve knowledge
→ Needs AI with GMX knowledge
= N AI agents or 1 mega-AI with N protocol integrations

OR uses MEV router but:
  - MEV router controls the txs (custody)
  - MEV router charges fees (extraction)
  - MEV router is centralized (downtime)
```

**With SmartAccount + Composable Bridges**:
```
User deploys SmartAccount
User grants AI execution role
User registers Protocol Bridges: UniswapBridge, AaveBridge, CurveBridge, GMXBridge

AI says: "Execute UniswapBridge(USDC→ETH) + AaveBridge(supply ETH) + CurveBridge(LP stETH/ETH)"

SmartAccount.executeBatch([
  Call(UniswapBridge, params1),
  Call(AaveBridge, params2),
  Call(CurveBridge, params3)
])

All 3 execute in 1 transaction.
AI doesn't need to know HOW each protocol works.
AI just composes bridges like LEGO blocks.

Bridges are interchangeable:
  - Want to use 1inch instead of Uniswap? Swap UniswapBridge for 1inchBridge
  - AI doesn't change. Strategies are composable, not hardcoded.
```

---

## Keeper Network Purpose

**Not** "execute AI trades" (AI already does that via executeStrategy)

**Rather** "execute automations when conditions are met":

```
User creates automation:
  - Trigger: "When ETH price < $2000"
  - Action: "Execute UniswapBridge(USDC→ETH)"

Keepers watch this automation.
When ETH drops below $2000:
  - Any keeper can call triggerAutomation(id)
  - Keeper gets rewarded from account's native balance
  - Account still owns all tokens (keeper never touches them)

AI is offline? Doesn't matter.
Keeper network executes automations anyway.
That's native automation resilience.
```

---

## The Three Layers (Correct Framing)

```
Layer 1: SmartAccount (Execution Authority)
  - Holds tokens (owned by user, not AI)
  - Grants execution roles (AI can execute, not withdraw)
  - Composable strategy execution (call any bridge)
  - Native automation (schedule repeating trades)

Layer 2: Protocol Bridges (Adapters)
  - Uniswap, Aave, Curve, GMX, etc.
  - Each bridge is a "protocol translator"
  - AI doesn't learn protocols. It composes bridges.
  - No withdrawal authority. Only execution.

Layer 3: Keeper Network (Automation Executor)
  - Watches automations
  - Executes when conditions met
  - Permissionless (anyone can join, earn rewards)
  - Paid from account's native balance
  - Account always owns funds (keeper is just executor)
```

---

## Why This Wins (Reframed)

**For Users**:
- AI has execution authority, not custody authority
- Automations run even if AI goes down
- Can revoke AI access anytime
- Strategies are composable (no need to teach AI every protocol)

**For AI Builders**:
- Don't learn protocols. Compose bridges.
- Unlimited strategy combinations (bridge A + bridge B + bridge C)
- Automations are native (not "please call Gelato")
- Reputation system (users follow high-performing AI)

**For Keepers**:
- Permissionless (anyone executes automations)
- Rewards are transparent (from account balance)
- No credit risk (account must have funds to pay reward)

**For Arbitrum**:
- Smart account pattern scales (1 account = 1 user, or pooled)
- Keeper network = persistent demand for throughput
- Protocol bridges = ecosystem adoption loop

---

## The Rebranding

**Old Naming** → **New Naming**
```
BaseVault         → SmartAccount
UserVault         → SingleUserAccount
ShareVault        → PooledAccount
SingleOwnerModule → OwnershipLayer / AccessControl
Strategy Adapter  → ProtocolBridge
ExecutorHub       → AutomationExecutor
_canExecute()     → _hasExecutionRole()
_canWithdraw()    → _isOwner()
Automation        → ScheduledExecution
```

---

## Code Implication (SmartAccount, Not Vault)

```solidity
contract SmartAccount is ReentrancyGuard {
    
    // Owner holds keys. AI has execution role (not ownership).
    address public owner;
    
    struct ExecutionRole {
        address agent;
        bool active;
        bool canExecuteStrategies;
        bool canCreateAutomations;
        bool canCancelAutomations;
        uint256 maxPerExecution;
        uint256 maxPerDay;
        uint256 maxLifetime;
    }
    
    // This account holds tokens. Period.
    // No deposits/withdrawals from AI.
    // Only owner can withdraw (escape hatch).
    
    // ===== AI Can Do =====
    
    function executeStrategy(
        address protocolBridge,
        bytes calldata params
    ) external onlyAgent returns (bool success) {
        // AI executes immediately
        // Bridge pulls via approval, executes, returns output
        // This is "immediate execution"
    }
    
    function createAutomation(
        address protocolBridge,
        bytes calldata params,
        uint256 frequency
    ) external onlyAgent returns (uint256 id) {
        // AI schedules automation
        // "Execute this bridge every X blocks"
        // Keepers will execute when ready
        // This is "scheduled execution"
    }
    
    function cancelAutomation(uint256 id) external onlyAgent {
        // AI can cancel its own automations
        // Owner can override (safety valve)
    }
    
    // ===== Owner Can Do =====
    
    function grantExecutionRole(
        address agent,
        ExecutionRole calldata role
    ) external onlyOwner {
        // Owner decides: "This AI can execute"
        // Can revoke anytime
    }
    
    function withdrawToken(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        // Only escape hatch for owner
        // AI can never touch this
    }
    
    // ===== Keepers Execute Automations =====
    
    function triggerAutomation(uint256 id) external onlyKeeper {
        // Permissionless keeper executes scheduled automation
        // Gets reward from account balance
        // Account still owns all tokens
    }
}
```

---

## Why This Reframing Matters for Arbitrum

**Arbitrum Judges See**:
- Not "another vault" (boring)
- But "smart account pattern for AI-driven trading" (novel)
- Native automation (Arbitrum's throughput matters)
- Keeper network (decentralized execution, not centralized Gelato)
- Protocol bridges as composable blocks (ecosystem plays)

**The Narrative**:
"Current AI trading requires private key handoff = custody risk. We give AI execution authority, not custody authority. Automations are native (no API dependency). Strategies are composable (AI composes bridges, not code). Keepers execute automations permissionlessly (even if AI goes down)."

That's a product, not a vault.

---

## Next Steps

Rename:
- BaseVault → SmartAccount
- UserVault → SingleUserAccount
- Strategy Adapter → ProtocolBridge (in comments at least)
- ExecutorHub calls become "trigger automation" instead of "execute task"

The code stays the same. The framing is the story.

This is what wins Arbitrum.
