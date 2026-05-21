# Execution Strategy: Arbitrum Open House Buildathon

## TL;DR

**What**: Composable vaults + strategies + keeper network on Arbitrum
**Why**: Solves fragmented DeFi (1000 manual txs → 1 automated tx)
**How**: BaseVault (execution engine) + Modules (composition layers) + Adapters (strategies)
**Timeline**: 3 weeks, 5 adapters, 2 vault types, public keepers
**Success**: Live keeper bot executing automations on Arbitrum One

---

## Winning Thesis

**Current DeFi** is stuck in a transactional loop:
- User wants: "Swap USDC → ETH → Stake → LP"
- Reality: 4 separate txs, 4 approvals, 4 chances to fail, 4x gas
- Keepers are centralized (Gelato, Chainlink) or don't exist
- Vaults are siloed (Aave vault can't talk to Uniswap vault)

**Our Solution**:
- 1 atomic transaction = Swap + Stake + LP (via composable adapters)
- Public keeper network (anyone can earn, permissionless)
- Composable vaults (BaseVault + any module combo)

**Why Arbitrum Wins**:
- 200M gas/sec throughput = can handle keeper network traffic
- Fraud proof finality = composable settlement across protocols
- Existing ecosystem (Uni, Aave, GMX, Lido) = instant adapter targets

---

## Core Architecture (Minimal Viable Version)

```
BaseVault (abstract)
  ├── Token tracking
  ├── Strategy execution (_executeStrategy)
  ├── Automation state machine (_createAutomation, _triggerAutomation)
  └── Abstract hooks (_canExecute, _canWithdraw)

SingleOwnerModule (implements access control)
  ├── Owner management
  ├── Operator registry
  └── Spending rules (mandate for AI agents)

ShareAccountingModule (implements pooling)
  ├── ERC4626-style shares
  ├── Deposit/Redeem
  └── NAV calculation

UserVault = BaseVault + SingleOwnerModule (single user + AI operator)
ShareVault = BaseVault + ShareAccountingModule (pooled capital, N users)

ExecutorHub (keeper coordinator)
  ├── Keeper registration
  ├── Task discovery
  ├── Reward distribution
  └── Reputation tracking

IStrategyAdapter (pluggable strategies)
  ├── execute (do the work)
  ├── canExecute (check conditions)
  ├── getTokenRequirements (how much to approve)
  └── validateParams (catch encoding errors early)
```

---

## Why This Architecture Wins Arbitrum Judges

### Technical Innovation
✅ **Composable vaults** — mix modules to create new vault types
✅ **Composable strategies** — chain adapters in automations
✅ **Public keepers** — permissionless network, transparent rewards
✅ **Atomic execution** — 1 tx = multi-step strategy across protocols

### Arbitrum Native
✅ Leverages Arbitrum's throughput (keeper network scales)
✅ Leverages Arbitrum's finality (settlement is composable)
✅ Integrates existing Arbitrum ecosystem (Uni, Aave, Curve, GMX, Lido)
✅ Could scale to Arbitrum Orbit chains (pluggable strategy ecosystem)

### Demo Quality
✅ Live keeper bot executing real automations
✅ Real rewards paid from vault balance
✅ Composable automation (3+ adapters in 1 tx)
✅ Multiple keeper reputation tiers

---

## Scope Boundaries (What We're NOT Doing)

❌ Governance token (out of scope)
❌ Advanced risk management (out of scope)
❌ Cross-chain execution (out of scope, but architecture allows it)
❌ Portfolio tracking UI (out of scope, skeleton is enough)
❌ Rust/Stylus implementation (Solidity only, 3 weeks)

We're focused on **core composability + public keepers**.

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Keeper network is complex | Week 1 uses existing ExecutorHub code; Week 2 adds public registration layer |
| Adapter bugs cascade | 2 adapters Week 1 (battle-tested Uni + Aave), 3 more Week 2 |
| Integration issues | Sepolia testnet all week; deploy to One only Week 3 |
| Front-end unfinished | Front-end is lowest priority; read-only Etherscan view is acceptable |
| Automation state machine has edge cases | Use existing UserVault code as reference; focus on composition, not reimplementation |

---

## Week-by-Week Deliverables

### Week 1: Core Infrastructure
```
✅ BaseVault compiles, tests pass
✅ ExecutorHub integrated with BaseVault
✅ UserVault (BaseVault + SingleOwnerModule) works
✅ UniswapV3 adapter tested on Sepolia fork
✅ AaveSupply adapter tested on Sepolia fork
✅ All contracts deployed to Arbitrum Sepolia
```

### Week 2: Composability + Public Keepers
```
✅ ShareVault (BaseVault + ShareAccounting) works
✅ PublicKeeperNetwork allows registration + rewards
✅ 5 total adapters (Uni, Aave, GMX, Curve, Lido)
✅ Automation chaining tested (3+ adapters in 1 tx)
✅ Keeper bot continuously executing automations
✅ All contracts deployed to Arbitrum Sepolia
```

### Week 3: Polish + Live Demo
```
✅ All contracts deployed to Arbitrum One
✅ Keeper bot running on One, earning real rewards
✅ Front-end skeleton deployed (list vaults, deposit form)
✅ Documentation complete
✅ Demo script proven on live Arbitrum One
✅ Video recorded for judges
```

---

## Daily Standup Template

**Monday-Friday, 15 min async or sync**:

```
Date: [DATE]
Completed:
  - [TASK] completed in [TIME]
  - [TASK] completed in [TIME]

Blockers:
  - [ISSUE]: [ROOT CAUSE], ETA to fix [TIME]

Next:
  - [TASK] — estimate [TIME]
  - [TASK] — estimate [TIME]

Confidence: [0-10] on weekly milestone
```

---

## Arbitrum One Deployment Addresses (Track Here)

```
WEEK 3 — Deploy to Arbitrum One
================================
BaseVault: 0x...
ExecutorHub: 0x...
UserVault: 0x...
ShareVault: 0x...
PublicKeeperNetwork: 0x...

Adapters:
  UniswapV3Swap: 0x...
  AaveSupply: 0x...
  GMX: 0x...
  Curve: 0x...
  Lido: 0x...

Factory: 0x...
StrategyRegistry: 0x...
```

---

## Demo Script (For Judges)

**Total time: 30 minutes**
- 5 min: Architecture overview (slides)
- 10 min: Live execution (keeper bot → automation → multi-step strategy)
- 10 min: Composability demo (user creates custom automation)
- 5 min: Q&A

**Talking points**:
1. **Problem**: Current DeFi is transactional. "Swap → Stake → LP" = 3 txs, 3 failures, 3x gas.
2. **Solution**: Composable vaults + strategies + keeper network.
3. **Architecture**: BaseVault (execution engine) + Modules (composition) + Adapters (strategies).
4. **Live demo**: Keeper executes automation, earns reward, multiple adapters run in 1 tx.
5. **Why Arbitrum**: Throughput for keeper network, finality for composability.

---

## After Buildathon (If You Place)

**Immediate** (Weeks 1-4):
- Security audit (critical bug fixes only)
- Gas optimization (especially getExecutableAutomations)
- Testnet hardening

**Phase 1** (Month 2):
- Governance token (DAO controls adapter whitelist)
- Reputation scoring on-chain (for leaderboard)
- Multi-chain deployment (Optimism, Base, Polygon)

**Phase 2** (Month 3):
- Stylus port (Rust adapters for speed)
- Cross-chain automation
- Institutional vaults (multi-sig approval)

**Phase 3** (Month 4-6):
- Portfolio tracking
- Advanced analytics (Sharpe, attribution)
- Partnerships (with protocols for native integrations)

---

## File Organization

```
project-root/
├── ARBITRUM_BUILD_PLAN.md         (this file + strategy)
├── ARCHITECTURE_ANALYSIS.md       (technical deep-dive)
├── WEEKLY_CHECKLIST.md            (daily standup tracking)
├── ADAPTER_DEV_GUIDE.md           (how to write adapters)
│
├── contracts/
│   ├── core/
│   │   ├── BaseVault.sol
│   │   ├── ExecutorHub.sol
│   │   ├── UserVaultFactory.sol
│   │   └── StrategyRegistry.sol
│   │
│   ├── modules/
│   │   ├── SingleOwnerModule.sol
│   │   ├── ShareAccountingModule.sol
│   │   ├── AIExecutionModule.sol
│   │   └── AutomationModule.sol
│   │
│   ├── adapters/
│   │   ├── IStrategyAdapter.sol
│   │   ├── UniswapV3SwapAdapter.sol
│   │   ├── AaveSupplyAdapter.sol
│   │   ├── GMXAdapter.sol
│   │   ├── CurvePoolAdapter.sol
│   │   └── LidoStakeAdapter.sol
│   │
│   └── test/
│       ├── BaseVault.test.sol
│       ├── ExecutorHub.test.sol
│       ├── adapters/
│       │   ├── UniswapV3.fork.test.sol
│       │   └── Aave.fork.test.sol
│       └── integration.test.sol
│
├── frontend/
│   ├── pages/
│   │   ├── vaults.tsx
│   │   ├── vault/[address].tsx
│   │   ├── keepers.tsx
│   │   └── adapters.tsx
│   └── lib/
│       └── contracts.ts
│
├── keeper-bot/
│   └── executor.ts
│
└── docs/
    ├── TECHNICAL.md
    ├── KEEPER_GUIDE.md
    └── DEMO_SCRIPT.md
```

---

## Success Metrics (Judging Rubric)

### Must-Haves
- [ ] BaseVault + modules compose correctly (no code duplication)
- [ ] All 5 adapters deployed and tested
- [ ] ExecutorHub allows public keeper registration
- [ ] Keeper bot executing automations on live Arbitrum (Sepolia or One)
- [ ] Composable automation works (3+ adapters in 1 tx)

### Nice-to-Haves
- [ ] Front-end deployed (even if skeleton)
- [ ] Automation chaining (automation A triggers automation B)
- [ ] Reputation scoring (keeper reputation affects reward)
- [ ] Multi-sig vault type (DAO control)
- [ ] Video demo recorded

### Bonus
- [ ] Stylus proof-of-concept (even if not production-ready)
- [ ] Cross-chain automation (deposit on One, execute on Optimism)
- [ ] Automated market-making adapter (Curve LP + rebalancing)

---

## Go/No-Go Decision Points

### End of Week 1
**Go?** BaseVault + ExecutorHub + 2 adapters deployed to Sepolia, tests passing
**No-Go?** Stop, pivot to simpler architecture (single vault type only)

### End of Week 2
**Go?** ShareVault + PublicKeeperNetwork + 5 adapters deployed, keeper bot executing
**No-Go?** Drop public keeper network, ship private keeper version instead

### End of Week 3
**Go?** Live on Arbitrum One, keeper bot running, demo working
**No-Go?** Ship on Sepolia instead, document testnet addresses, focus on demo quality

---

## Communication & Updates

**Daily standup**: 15 min (async via Slack/Discord)
**Weekly review** (Sunday): What worked? What surprised us? Scope adjustments?
**Pre-demo** (Day before): Full run-through on Arbitrum One, record video

Document everything. Judges want to see process, not just product.

---

## Final Thought

This is a **3-week execution sprint**, not a research project. You know what you're building. You have working code from prior sessions. Focus on:

1. **Composability** (module system works, no code duplication)
2. **Keepers** (public registration, transparent rewards, live on Arbitrum)
3. **Strategies** (5 adapters, proof of multi-step atomic execution)

Ship working code. Judges care about architecture + demo quality + live execution.

You've got this. 🚀
