# Week-by-Week Execution Checklist

## Week 1: Core Infrastructure (BaseVault + ExecutorHub + Reference Adapters)

### Monday
- [ ] BaseVault scaffold (abstract contract, 150 lines)
  - [ ] Token tracking (_heldTokens, _isTracked)
  - [ ] Strategy execution primitives (_executeStrategy, approve/revoke pattern)
  - [ ] Automation state machine skeleton (_automations, nextAutomationId)
  - [ ] Abstract hooks (_canExecute, _canWithdraw, _beforeExecution)
  - [ ] Tests: unit tests for each method
- [ ] All tests passing

### Tuesday
- [ ] ExecutorHub integration with BaseVault
  - [ ] Verify ExecutorHub calls vault.triggerAutomation() correctly
  - [ ] Test keeper registration
  - [ ] Test task discovery (getTasks, getExecutableTasks)
  - [ ] Tests: keeper lifecycle, task registration, execution
- [ ] ExecutorHub tests passing

### Wednesday
- [ ] SingleOwnerModule implementation
  - [ ] Owner management (setOwner, onlyOwner)
  - [ ] Operator registry (setOperator, removeOperator)
  - [ ] Spending rules skeleton (maxPerExecution, maxPerDay)
  - [ ] Tests: owner perms, operator perms, permission errors
- [ ] UserVault composition (BaseVault + SingleOwnerModule)
  - [ ] Verify composition works (no compile errors)
  - [ ] Basic functionality test (owner can create automation)
- [ ] All tests passing

### Thursday
- [ ] UniswapV3SwapAdapter implementation
  - [ ] getTokenRequirements(USDC -> amount needed for swap)
  - [ ] canExecute(price slippage check?)
  - [ ] execute(call router.exactInputSingle)
  - [ ] validateParams(decode, verify USDC address, etc)
  - [ ] Tests: swap execution on fork (Uniswap Sepolia)
- [ ] Integration test: UserVault → UniswapV3Adapter
  - [ ] Vault calls execute → adapter executes swap → returns output

### Friday
- [ ] AaveSupplyAdapter implementation
  - [ ] getTokenRequirements(ETH → amount needed)
  - [ ] canExecute(collateral check?)
  - [ ] execute(call aToken.supply)
  - [ ] validateParams
  - [ ] Tests: supply execution on fork
- [ ] Integration test: UserVault → AaveSupplyAdapter
  - [ ] Full flow: approve → execute → check aToken balance
- [ ] All tests passing, deploy to Arbitrum Sepolia (testnet)
  - [ ] BaseVault, ExecutorHub, UserVault contracts deployed
  - [ ] Both adapters deployed
  - [ ] Verify contracts on Arbiscan

### Weekend
- [ ] Manual testing on Sepolia
  - [ ] User vault creation
  - [ ] Strategy execution via UI/web3.js
  - [ ] Keeper registration + task execution
  - [ ] Fix any bugs found

**End of Week 1 Milestone**: BaseVault + 2 adapters + ExecutorHub working on Sepolia, keeper can execute automations

---

## Week 2: Extensibility + Public Keepers (ShareVault + StrategyRegistry + 3 More Adapters)

### Monday
- [ ] ShareAccountingModule implementation
  - [ ] Share token accounting (totalShares, shares mapping)
  - [ ] Deposit function (pull USDC, mint shares, update NAV)
  - [ ] Redeem function (burn shares, push USDC, update NAV)
  - [ ] NAV calculation (_previewDeposit, _previewRedeem)
  - [ ] Tests: deposit/redeem math correct, share price invariant
- [ ] ShareVault composition (BaseVault + ShareAccounting + AIExecution)
  - [ ] Verify compiles and integrates correctly
  - [ ] Tests: user deposits, shares issued correctly

### Tuesday
- [ ] StrategyRegistry enhancement
  - [ ] Implement (if not already done in Week 1)
  - [ ] registerStrategy(adapter, gasLimit, requiresTokens, automationOnly)
  - [ ] deactivateStrategy / activateStrategy
  - [ ] isStrategyActive check
  - [ ] Tests: registration, activation, deactivation, registry checks in vault

### Wednesday
- [ ] AutomationModule implementation
  - [ ] Public interface: createAutomation, cancelAutomation, triggerAutomation
  - [ ] getExecutableAutomations (for keeper discovery)
  - [ ] Automation state: ACTIVE, COMPLETED, CANCELLED
  - [ ] Tests: automation lifecycle, executor-only triggerAutomation

### Wednesday-Thursday
- [ ] PublicKeeperNetwork (fork of ExecutorHub with public registration)
  - [ ] registerAsKeeper() (no admin, just caller registers themselves)
  - [ ] Reputation tracking (successful/failed execution counts)
  - [ ] Reward distribution (keeper earns from vault)
  - [ ] Optional: slashing (3 failed in a day → timeout)
  - [ ] Tests: registration, reward payouts, reputation updates

### Thursday
- [ ] GMX adapter
  - [ ] getTokenRequirements (position size)
  - [ ] canExecute (market conditions)
  - [ ] execute (open position on GMX)
  - [ ] Tests: GMX execution on fork
- [ ] Curve adapter
  - [ ] getTokenRequirements (token pair + liquidity)
  - [ ] canExecute (price conditions)
  - [ ] execute (add liquidity to pool)
  - [ ] Tests: LP add on fork

### Friday
- [ ] Lido adapter
  - [ ] getTokenRequirements (ETH amount)
  - [ ] canExecute (always executable)
  - [ ] execute (call stake() + receive stETH)
  - [ ] Tests: stake on fork
- [ ] Integration test: Automation chaining
  - [ ] Swap USDC → ETH (Uniswap)
  - [ ] Stake ETH → stETH (Lido)
  - [ ] LP stETH/ETH (Curve)
  - [ ] All 3 happen in one automation execution
  - [ ] Tests: full chain executes without error
- [ ] Deploy to Arbitrum Sepolia
  - [ ] All 5 adapters deployed
  - [ ] ShareVault deployed, test user deposits
  - [ ] PublicKeeperNetwork running
  - [ ] Verify on Arbiscan

### Weekend
- [ ] End-to-end testing on Sepolia
  - [ ] Register as public keeper
  - [ ] Execute automations, collect rewards
  - [ ] User deposits into ShareVault, watch automations execute
  - [ ] Fix integration bugs

**End of Week 2 Milestone**: ShareVault + 5 adapters + PublicKeeperNetwork live on Sepolia, multiple keepers can execute, composable automations working

---

## Week 3: Polish + Testnet Demo (Deploy One + Front-End + Documentation)

### Monday
- [ ] Fix any lingering Sepolia bugs
- [ ] Test keeper bot continuously running
  - [ ] Keeper picks up automations
  - [ ] Executes successfully
  - [ ] Earns rewards
  - [ ] No crashes over 4-hour period

### Tuesday
- [ ] Deploy to Arbitrum One (mainnet)
  - [ ] All contracts deployed
  - [ ] Gas optimization: check getExecutableAutomations() gas cost
  - [ ] Verify on Arbiscan
- [ ] Keeper bot switched to mainnet
  - [ ] Executing real automations
  - [ ] Earning real ETH/ARB

### Wednesday
- [ ] Front-end skeleton (React/Next.js)
  - [ ] pages/vaults.tsx (list vaults, filter by adapter)
  - [ ] pages/vault/[address].tsx (vault details, deposit form)
  - [ ] pages/keepers.tsx (list keepers, reputation)
  - [ ] pages/adapters.tsx (list whitelisted adapters)
  - [ ] Uses viem/wagmi for wallet connection + contract calls

### Thursday
- [ ] Documentation
  - [ ] README (what is this, why it matters)
  - [ ] TECHNICAL.md (architecture, modules, adapters)
  - [ ] KEEPER_GUIDE.md (how to register, earn rewards)
  - [ ] ADAPTER_DEV.md (how to write a new adapter)
  - [ ] DEMO_SCRIPT.md (step-by-step for judges)

### Friday
- [ ] Demo script execution
  - [ ] Create fresh vault on One
  - [ ] Create automations
  - [ ] Trigger keeper execution
  - [ ] Show on-chain events
  - [ ] Show keeper rewards
  - [ ] Show ShareVault user share growth
  - [ ] Everything works without errors
  - [ ] Record video for judges

### Friday-Saturday
- [ ] Final polish
  - [ ] Any contract gas optimizations
  - [ ] Front-end loading states + error handling
  - [ ] README typos, docs clarity
  - [ ] Final Arbiscan verification (all contracts visible)

### Saturday-Sunday
- [ ] Rehearse demo (30 min version for judges)
  - [ ] Walk through contract composition
  - [ ] Show live keeper execution
  - [ ] Show adapter composability
  - [ ] Show ShareVault
  - [ ] Timing: 5 min architecture, 10 min live demo, 10 min keeper network, 5 min Q&A buffer

**End of Week 3 Milestone**: Live on Arbitrum One, keeper bot executing, front-end deployed, documentation complete, demo ready

---

## Definition of Done (Per Week)

### Week 1 ✅
- BaseVault compiles and tests pass
- ExecutorHub integrated with BaseVault
- UserVault (BaseVault + SingleOwnerModule) works
- 2 adapters (Uniswap, Aave) tested on fork
- All deployed to Sepolia, Arbiscan-verified
- No critical bugs found in manual testing

### Week 2 ✅
- ShareVault (BaseVault + ShareAccounting) works, users can deposit/redeem
- PublicKeeperNetwork allows registration and reward payouts
- 5 adapters total (Uni, Aave, GMX, Curve, Lido) deployed and tested
- Automation chaining tested (3+ adapters in one execution)
- All deployed to Sepolia, keeper bot running continuously
- No integration bugs found

### Week 3 ✅
- All contracts deployed to Arbitrum One
- Keeper bot running on One, earning real rewards
- Front-end deployed (read-only vault listing + deposit form)
- Documentation complete + demo script proven
- Demo rehearsed and timed (30 min)
- Video recording of live execution for judges

---

## Time Box Notes

**Each task has a default time**. If you're behind:
- Week 1, Friday: If Aave adapter is taking >4 hours, skip it. Deploy with just Uniswap. You can add Aave in Week 2.
- Week 2, Thursday: If GMX is complex, skip it. Deploy with Uni + Aave + Curve + Lido (4 adapters still shows composability).
- Week 3, Wednesday: Front-end is lowest priority. If not done, Etherscan view of contract state is acceptable. Judges care about on-chain logic.

**Safety valves**:
- If contracts have critical bugs that take >2 hours to fix, pause and pivot (e.g., public keeper registration can be mocked/admin-only during demo).
- If integration issues cascade, revert to simpler automation (single adapter) and prove that works before chaining.

---

## Communication

**Daily standup** (async or sync):
- What did I get done?
- What's blocking me?
- What's next?

**Weekly review** (Sunday):
- Did we hit the milestone?
- What surprised us?
- Any scope adjustments needed?

Assume 1 developer, 40 hrs/week. Adjust if you have a team.
