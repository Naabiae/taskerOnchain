# Arbitrum Open House: Composable Automation Infrastructure

## Executive Summary

**Project**: Composable Vault + Strategy + Keeper Network on Arbitrum

**Core Thesis**: DeFi composability today is async and fragile (swap contract, approve contract, bridge, check back later). What if execution could be atomic, parallel, and automated across any combination of strategies?

**Scope for 3 Weeks**:
1. BaseVault + Module System (composable vaults)
2. Strategy Adapter Framework (composable strategies)
3. Public Keeper Network + Executor Registry (decentralized automation)

AI agents naturally emerge as a use case, not the focus. Users (human or AI) deposit into vaults, strategies execute, keepers earn rewards.

---

## Why This Wins Arbitrum

### The Problem Arbitrum Solves
- 7-day fraud proof → fast finality
- 200M gas/sec throughput
- Stylus (WASM) + Solidity support
- Ecosystem: Uniswap, Lido, GMX, Aave

### The Problem We Solve
- **Composability gap**: Strategies are one-shots. "Swap on Uni → stake on Lido → LP on GMX" requires 3 separate txs, 3 opportunities for slippage, 3 times user must wait.
- **Automation gap**: Only centralized keepers. "Rebalance if price drops 5%" means relying on a single bot or paying Gelato $$$. No permissionless, transparent keeper network.
- **Vault fragmentation**: Every protocol needs its own vault (Aave's vault, Lido's vault, GMX vault). No composable execution across protocols.

**Our Solution**: Atomic execution of multi-step strategies via a permissionless keeper network.

### Demo Flow
```
User deposits 1000 USDC into ComposableVault on Arbitrum

ComposableVault:
  Automation 1: "Every hour, if ETH price dips 3%, execute SwapStrategy"
    → UniswapV3Adapter.execute(USDC → ETH)
  Automation 2: "When ETH position > 10 ETH, execute SupplyStrategy"
    → AaveAdapter.execute(supply ETH as collateral)
  Automation 3: "When collateral > 50K, execute BorrowStrategy"
    → AaveAdapter.execute(borrow against collateral, get USDC back)
  AutomationWatcher: (Automation 3 complete) → trigger Automation 1

Keeper sees Automation 1 executable, calls executeAutomation(vault, automationId=1)
  → All 4 steps happen in ONE transaction
  → Keeper earns reward from vault's protocol revenue
  → User's position rebalances automatically

No waiting. No manual approval. Composable execution.
```

---

## 3-Week Build Plan

### Week 1: Core Infrastructure

**Deliverables**:
- BaseVault (abstract, shared execution engine)
- SingleOwnerModule (for UserVault testing)
- IStrategyAdapter interface + 2 reference adapters (Uniswap swap, Aave supply)
- ExecutorHub (keeper registry + task coordinator)

**Why This Week**:
- ExecutorHub is the keeper network infra. Get it right early.
- BaseVault is the foundation. All vault types inherit it.
- 2 adapters prove the pattern works before strategy explosion.

**Deployment**: Arbitrum Sepolia (testnet for fast iteration)

**Code Structure**:
```
contracts/
├── core/
│   ├── BaseVault.sol           (150 lines)
│   ├── ExecutorHub.sol         (300 lines, from existing codebase)
│   └── UserVaultFactory.sol    (60 lines)
├── modules/
│   ├── SingleOwnerModule.sol   (80 lines)
│   └── AIExecutionModule.sol   (60 lines)
├── adapters/
│   ├── IStrategyAdapter.sol    (interface)
│   ├── UniswapV3SwapAdapter.sol (reference impl)
│   └── AaveSupplyAdapter.sol   (reference impl)
└── test/
    └── integration.test.sol
```

**Milestones**:
- Day 2: BaseVault compiles, tests pass
- Day 4: ExecutorHub + UserVault composition works
- Day 6: UniswapV3 adapter tested on fork
- End of Week: Aave adapter tested on fork, full integration test passing

---

### Week 2: Extensibility + Public Keepers

**Deliverables**:
- ShareAccountingModule (for pooled vaults)
- StrategyRegistry (governance over adapter whitelist)
- AutomationModule (public automation surface)
- PublicKeeperNetwork (anyone can register as keeper)
- 3 more adapters (GMX, Curve, Lido stake)

**Why This Week**:
- Prove modularity works by composing ShareVault = BaseVault + ShareAccounting + AIExecution
- Prove keeper network scales by having public registrations + reward distribution
- Prove strategy composability by chaining 5 adapters in one automation

**Key Implementation**:
```solidity
// PublicKeeperNetwork — anyone can execute
contract PublicKeeperNetwork is ExecutorHub {
    // Different from private ExecutorHub:
    // - No admin addExecutor() needed
    // - Register yourself: registerAsKeeper()
    // - Reputation stake: must lock 10 ARB to register
    // - Slashing: fail 3 times in a day → unstake and timeout
    
    function registerAsKeeper(address payable rewardAddress) external {
        require(msg.sender.balance >= 10 ether, "Insufficient stake");
        keepers[msg.sender] = KeeperRecord({
            active: true,
            rewardAddress: rewardAddress,
            successfulExecutions: 0,
            failedExecutions: 0,
            stakeAmount: 10 ether,
            registeredAt: block.timestamp
        });
    }
}
```

**Strategy Composability Test**:
```solidity
// Chain: USDC → ETH (Uniswap) → stake ETH (Lido) → LP stETH/ETH (Curve)
Automation[] automations = [
    Automation({ strategy: UniswapV3Adapter, params: encodeSwap(...) }),
    Automation({ strategy: LidoStakeAdapter, params: encodeStake(...) }),
    Automation({ strategy: CurvePoolAdapter, params: encodeLPAdd(...) }),
];

// All three execute in one transaction when keeper triggers
vault.executeAutomationBatch(automations);
```

**Milestones**:
- Day 1: ShareAccountingModule compiles, tests pass
- Day 2: ShareVault composition works (BaseVault + ShareAccounting + AIExecution)
- Day 3: StrategyRegistry governance interface works
- Day 5: PublicKeeperNetwork registration + reward payout tested
- Day 7: All 5 adapters deployed, cross-adapter chaining tested

---

### Week 3: Polish + Testnet Demo

**Deliverables**:
- Full testnet deployment (Arbitrum Sepolia)
- Live keeper bot running on testnet
- Front-end skeleton (read-only vault state, list adapters)
- Documentation + demo script
- Audit checklist (for post-buildathon)

**Why This Week**:
- Judges need to see working keeper network, not just code
- Live testnet means "real" transactions, gas metering, actual automation
- Skeleton UI proves the UX story works (users browse vaults, deposit, watch automations execute)

**Demo Flow for Judges**:
```
1. Show Arbitrum Sepolia deployment
   - 5 adapters live
   - 10 public keepers registered
   - 50 test vaults with automations

2. Trigger one automation
   - Keeper bot picks it up
   - Executes composite strategy (swap + stake + LP)
   - Keeper earns reward from vault balance
   - Show on-chain events proving execution

3. Show ShareVault (pooled vault)
   - 5 test users deposited USDC
   - Manager AI executed strategy
   - All 5 users' shares accrued gains in one tx

4. Show adapter composability
   - User creates custom automation mixing 3 adapters
   - System prevents invalid combinations (e.g., no staking unstaked tokens)
   - Automation executes without error

5. Show reputation system
   - Keeper1: 150 successful, 0 failed → high reputation
   - Keeper2: 50 successful, 3 failed → lower reputation
   - Rewards are reputation-weighted
```

**Front-End Skeleton** (React/Next.js):
```typescript
// pages/vaults.tsx
- List all vaults on Arbitrum Sepolia
- Filter by adapter type
- Show NAV, manager, YTD PnL

// pages/vault/[address].tsx
- Vault details
- Automation state + next execution time
- Execution history (events)
- Deposit form (ERC20 approval + deposit call)

// pages/keepers.tsx
- List all registered public keepers
- Sort by reputation
- Show reward payouts over time

// pages/adapters.tsx
- List all whitelisted adapters
- Drag-and-drop automation builder (conceptual)
```

**Milestones**:
- Day 1: Fix integration issues from Week 2
- Day 2: Deploy to Arbitrum Sepolia (real network)
- Day 3: Keeper bot running, executing automations
- Day 4: Front-end skeleton deployed (read-only)
- Day 5: Documentation complete, demo script working
- Day 6-7: Buffer for last-minute fixes, rehearse demo

---

## Technical Decisions for Arbitrum

### 1. Use Solidity, Not Stylus (Yet)
**Why**: 3 weeks isn't enough to learn Rust + Stylus + debug gas metering. Solidity gives you 100% ecosystem compatibility (Uniswap, Aave, Lido all have Solidity interfaces). Stylus is a stretch goal post-buildathon.

### 2. Deploy on Arbitrum One (Mainnet), Not Orbit Chain
**Why**: Judges care about real economy. Testnet for safety, but live demo on One shows real keepers, real rewards, real users can participate. Orbit chain adds ops overhead (rollup validation, custom sequencer config).

### 3. Keep Keeper Network Public But Stake-Protected
**Why**: Permissionless = community keepers. Stake = prevents Sybil attacks. 10 ARB = ~$30 at current prices, low enough for amateur keepers, high enough to deter spam.

### 4. Use Existing StrategyRegistry Pattern
**Why**: You already have the code. Governance can whitelist adapters post-launch. Saves a week of governance design.

---

## Success Criteria (Judging)

### Technical Innovation
✅ Composable vaults (BaseVault + modular mixins)
✅ Composable strategies (adapters are pluggable, can chain in automations)
✅ Public keeper network (permissionless, transparent, reputation-based)
✅ Atomic execution across multiple protocols (one tx = Uni + Aave + Curve)

### Real Arbitrum Integration
✅ Live on testnet with working keeper bot
✅ 5+ adapters (Uni, Aave, Curve, GMX, Lido)
✅ Public keepers can register and earn rewards
✅ Gas metering shows benefit over manual multi-tx approach

### Ecosystem Play
✅ Could integrate with Arbitrum protocols (Uniswap, Aave, Curve already in scope)
✅ Keepers are decentralized (anyone joins network)
✅ Vaults are composable (users can mix strategies)

### Demo Quality
✅ Live keeper execution (not mocked, real tx on testnet)
✅ Keeper earning rewards (wallet shows incoming transfers)
✅ Composable automation (show swap + stake + LP in one tx)
✅ Vault state tracking (show users' share growth over automations)

---

## Risk Mitigation

### Risk 1: Keeper Network Too Complex
**Mitigation**: Week 1 focuses on ExecutorHub (you already have working code). Week 2 adds public registration layer. Worst case, end with private keeper network (still wins on composition + strategies).

### Risk 2: Strategy Adapter Bugs
**Mitigation**: 2 adapters in Week 1 (Uni + Aave, battle-tested). 3 more in Week 2 (GMX, Curve, Lido). Only add untested adapters if time permits. Better to have 3 perfect adapters than 10 buggy ones.

### Risk 3: Integration Issues Cascade
**Mitigation**: Use Arbitrum Sepolia all week, deploy to One only on Day 2 of Week 3. Testnet catches bugs before real network.

### Risk 4: Front-End Unfinished
**Mitigation**: Front-end is lowest priority. Judges care about contract logic + live keeper execution. Even a basic read-only Etherscan view of contract state is acceptable.

---

## Post-Buildathon Roadmap

If you win (or place high):

**Immediate** (Weeks 1-4):
- Production security audit
- Add emergency pause mechanism
- Optimize gas (especially getExecutableAutomations)

**Phase 1** (Month 2):
- Stylus port (Rust adapters for additional speed)
- Multi-chain deployment (Polygon, Optimism, Base)
- Reputation scoring on-chain (for UI leaderboard)

**Phase 2** (Month 3):
- Governance token (DAO controls adapter whitelist)
- Granular permissions (operator can execute Uni but not Aave)
- Cross-chain automation (deposit on One, execute on Optimism)

**Phase 3** (Month 4-6):
- Institutional vaults (team member approval requirements)
- Portfolio tracking (aggregate across vaults)
- Advanced analytics (attribution, Sharpe ratio, etc.)

---

## Files to Create Now

```
baseVault/
├── ARBITRUM_BUILD_PLAN.md        (this file)
├── ARCHITECTURE_ANALYSIS.md      (from prior session)
├── WEEKLY_CHECKLIST.md           (tracking)
├── adapters/ADAPTER_SPEC.md      (how to write adapters)
└── keeper-network/KEEPER_SPEC.md (how keeper network works)
```

---

## Execution Velocity

**Week 1 Cadence**:
- Mon: BaseVault done
- Tue: ExecutorHub integrated
- Wed: SingleOwnerModule + UserVault working
- Thu: UniswapV3 adapter implemented
- Fri: Aave adapter implemented + integration test passing
- Weekend: Fix integration issues, prepare for Week 2

**Week 2 Cadence**:
- Mon: ShareAccountingModule done, ShareVault composes
- Tue: StrategyRegistry working
- Wed: PublicKeeperNetwork registration live
- Thu: 3 new adapters (GMX, Curve, Lido)
- Fri: Full integration test (all 5 adapters + keeper reward)
- Weekend: Deploy to Arbitrum Sepolia, fix real-network bugs

**Week 3 Cadence**:
- Mon: Fix any Sepolia issues
- Tue: Deploy to Arbitrum One
- Wed: Keeper bot running continuously
- Thu: Front-end skeleton
- Fri: Documentation + demo script
- Weekend: Final polish + demo rehearsal

---

## Why This Wins

**Judges Care About**:
1. ✅ Real utility (automation gap is real)
2. ✅ Composability (adapters + modules show it works)
3. ✅ Decentralization (public keeper network)
4. ✅ Arbitrum native (not just "Solidity on any L2")
5. ✅ Live demo (working keeper bot, real automations)

**You're Positioned Well**:
- Existing ExecutorHub code (saves 1 week)
- Architecture figured out (no design churn)
- Clear module pattern (dev velocity is high)
- Focused scope (3 weeks, not 3 months)

Ship it.
