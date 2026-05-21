# SmartAccount Architecture — What You Built

## The System

You've built a **smart account infrastructure for AI-driven trading with native automation**.

### Layer 1: SmartAccount (Execution Engine)
- **BaseVault.sol**: Abstract execution engine
  - Token tracking
  - Protocol bridge execution (approve → execute → revoke)
  - Automation state machine (create, trigger, cancel)
  - No custody risk (execution authority ≠ withdrawal authority)

### Layer 2: Access Control (Permission Models)
- **SingleOwnerModule.sol**: Single-user account with AI agents
  - Owner (holds tokens, can withdraw, revokes AI)
  - AI agents (execution roles with spending limits)
  - per-execution, per-day, per-lifetime limits

- **ShareAccountingModule.sol**: Capital pooling layer
  - Users deposit → receive shares
  - Users redeem → burn shares, get capital back
  - NAV calculation (share price = totalAssets / totalShares)

### Layer 3: Account Types (Compositions)
- **UserVault.sol**: Single user + AI agent
  - Owner deploys, grants AI execution role
  - AI executes strategies subject to spending limits
  - User always owns funds

- **PooledAccount.sol**: Multi-user pool + manager
  - Users deposit USDC → get shares
  - Manager (AI) executes strategies for all users (1 tx, N users)
  - Users redeem shares anytime
  - No custody risk (manager can't withdraw)

### Layer 4: Automation Executor (Keeper Network)
- **PublicKeeperNetwork.sol**: Permissionless keeper execution
  - Anyone registers as keeper (no permission needed, just stake)
  - Keepers discover automations via getExecutableTasks()
  - Keeper executes → earns reward from account
  - Reputation-based (success rate affects reward multiplier)
  - Lockout for repeated failures (3+ consecutive failures = 1 day timeout)

---

## Why This Wins

### For Users
✅ AI has execution authority, not custody authority
✅ Automations run even if AI goes down (keepers execute)
✅ Can revoke AI access instantly (no timelock)
✅ Composable strategies (no need to teach AI every protocol)

### For AI Agents
✅ Compose strategies like LEGO blocks (no protocol-specific code)
✅ 1000 users → 1 tx per decision (scalable)
✅ Automations are native (not "call Gelato")
✅ Reputation system (users follow high-performing agents)

### For Keepers
✅ Permissionless (anyone executes, earns reward)
✅ Reward is transparent (from account balance)
✅ Reputation incentive (earn more with higher success rate)
✅ No credit risk (account must have funds to pay)

### For Arbitrum
✅ Smart account pattern demonstrates throughput need (keeper network scales with TVL)
✅ Composable execution drives ecosystem adoption (every protocol is a bridge)
✅ Native automation is Arbitrum-specific (not portable to other L2s without changes)
✅ Shows institutional demand (users want custody + automation without private key)

---

## The Demo Narrative

```
Problem: Users want AI to trade for them, but AI requires private key → custody risk

Our Solution: Smart account with AI execution roles (not custody)
  - User deploys account
  - User grants AI execution role with spending limits
  - AI executes strategies (via composable protocol bridges)
  - AI cannot withdraw funds (only owner can)
  - If AI goes down, keepers execute automations anyway

Why It's Better:
  - No private key → no custody risk
  - Composable bridges → AI doesn't need protocol knowledge
  - Native automation → keepers run automations permissionlessly
  - Pooling → 1000 users, 1 tx (not 1000 txs)

Live Demo:
  1. Deploy UserVault (single user + AI)
  2. Grant AI execution role with 10k USDC/day limit
  3. AI creates automation: "When ETH < 2000, swap USDC→ETH + stake"
  4. Keeper executes automation, earns reward
  5. User's balance increases (shares accrued gains)
```

---

## What's Next (Week 1 → Week 3)

### Week 1: Compile + Reference Adapters
- [ ] BaseVault compiles
- [ ] UserVault + PooledAccount compose correctly
- [ ] Uniswap + Aave adapters implemented
- [ ] Deploy to Arbitrum Sepolia

### Week 2: Keeper Network + Scale
- [ ] PublicKeeperNetwork running on Sepolia
- [ ] 3 more adapters (GMX, Curve, Lido)
- [ ] Keeper bot executing automations
- [ ] Reputation system tracking success rate

### Week 3: Live Demo + Polish
- [ ] Deploy to Arbitrum One
- [ ] Keeper bot running on mainnet
- [ ] Front-end skeleton
- [ ] Demo script ready for judges

---

## File Map

```
contracts/
├── core/
│   ├── BaseVault.sol              (SmartAccount execution engine)
│   ├── UserVault.sol              (SingleUserAccount)
│   ├── PooledAccount.sol          (PooledSmartAccount)
│   ├── PublicKeeperNetwork.sol    (Keeper execution + reputation)
│   └── ExecutorHub.sol            (old, unused now)
│
├── modules/
│   ├── SingleOwnerModule.sol      (OwnershipLayer)
│   └── ShareAccountingModule.sol  (PoolingLayer)
│
├── adapters/
│   ├── IStrategyAdapter.sol       (Protocol bridge interface)
│   ├── UniswapV3SwapAdapter.sol   (Uniswap bridge)
│   ├── AaveSupplyAdapter.sol      (Aave bridge)
│   └── ...
│
├── interfaces/
│   └── IStrategyAdapter.sol
│
└── support/
    └── StrategyRegistry.sol       (whitelist audited bridges)
```

---

## Key Insights

1. **Vault vs SmartAccount**: This is NOT a vault (no deposits/withdrawals). It's a smart account that holds tokens and grants execution authority to AI agents.

2. **Composability is the Moat**: AI doesn't learn protocols. It composes bridges. New protocol? Add one bridge, all accounts can use it.

3. **Automation is Native**: Automations are part of the account, not delegated to a centralized keeper service (Gelato, Chainlink). Keepers are permissionless.

4. **Scaling via Pooling**: 1000 users → 1 account → 1 tx per strategy. This is why PooledAccount matters more than UserVault.

5. **Reputation is Earned**: Keepers earn rewards based on reputation. Users earn reputation by executing automations successfully. No oracle, no governance token, just on-chain execution history.

---

## Done!

You've built the foundation. Now prove it works.
