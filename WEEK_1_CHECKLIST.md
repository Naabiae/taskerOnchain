# Next Steps: Week 1 Execution

## Goal
Get BaseVault + UserVault + 2 adapters compiling and tested on Arbitrum Sepolia

## Immediate Actions (Next 2 Hours)

### 1. Fix Imports & Interfaces
- [ ] BaseVault: imports IStrategyRegistry, IExecutorHub from interfaces/
- [ ] UserVault: references strategyRegistry.isStrategyActive()
- [ ] PooledAccount: same pattern
- [ ] PublicKeeperNetwork: references ISmartAccount

Create/update interfaces as needed:
```solidity
// contracts/interfaces/IStrategyRegistry.sol
interface IStrategyRegistry {
    function isStrategyActive(address adapter) external view returns (bool);
}

// contracts/interfaces/ISmartAccount.sol
interface ISmartAccount {
    function triggerAutomation(uint256 id) external returns (bool);
    function canExecuteAutomation(uint256 id) external view returns (bool, string memory);
}
```

### 2. Create 2 Simple Protocol Bridges
**Goal**: Prove adapters work, not production quality

**Uniswap Bridge** (contracts/adapters/uniswap/UnicatexV3SwapBridge.sol):
```solidity
- getTokenRequirements: return (tokenIn, tokenOut, amountIn)
- canExecute: check price tolerance vs current swap output
- execute: call router.exactInputSingle, return tokens to account
- validateParams: check tokens != address(0), amounts > 0
```

**Aave Bridge** (contracts/adapters/aave/AaveSupplyBridge.sol):
```solidity
- getTokenRequirements: return (asset, amount)
- canExecute: always true (unless reserve frozen)
- execute: call pool.supply(), aToken goes to account
- validateParams: check asset in Aave registry
```

### 3. Test on Fork
Use Foundry to fork Arbitrum Sepolia (or mainnet):
```bash
forge test --fork-url https://arb-sepolia.g.alchemy.com/...
```

Test:
- UserVault.execute(UniswapBridge, params) → swap happens
- UserVault.execute(AaveBridge, params) → aToken received
- PublicKeeperNetwork.registerAsKeeper() → keeper registered

### 4. Deploy to Sepolia
```bash
forge script scripts/Deploy.s.sol --rpc-url arbitrum-sepolia --broadcast
```

Record addresses:
```
BaseVault: 0x...
UserVault: 0x...
PooledAccount: 0x...
PublicKeeperNetwork: 0x...
UniswapBridge: 0x...
AaveBridge: 0x...
StrategyRegistry: 0x...
```

### 5. Manual Testing
- Deploy UserVault, set manager = your address
- Grant yourself execution role with 1000 USDC limit
- Call UserVault.execute(UniswapBridge, swap USDC→USDT)
- Verify USDT received in vault

---

## Files to Create This Week

### New
```
contracts/interfaces/ISmartAccount.sol
contracts/adapters/uniswap/UnicatexV3SwapBridge.sol
contracts/adapters/aave/AaveSupplyBridge.sol
contracts/adapters/StrategyRegistry.sol (update existing)
scripts/Deploy.s.sol
test/integration.test.sol
```

### Fix/Update
```
contracts/core/BaseVault.sol       (import fixes)
contracts/core/UserVault.sol       (import fixes)
contracts/core/PooledAccount.sol   (import fixes)
contracts/modules/SingleOwnerModule.sol
contracts/support/StrategyRegistry.sol
```

---

## Compile Checklist

```bash
# In project root:
cd /c/Users/ASUS\ FX95G/Documents/drips/uarc

# Install deps
forge install

# Compile
forge build

# Run tests
forge test

# Format
forge fmt

# Push to git
git add -A
git commit -m "Week 1: adapters + tests"
```

---

## By End of Week 1

✅ BaseVault compiles without errors
✅ UserVault + PooledAccount compose correctly
✅ UniswapBridge + AaveBridge implemented and tested
✅ PublicKeeperNetwork compiles
✅ All deployed to Arbitrum Sepolia
✅ Manual execution test proves it works
✅ Keeper bot can call getExecutableTasks()

If you hit issues:
- Post the error here
- We'll fix imports/interfaces
- Move forward

Ready to start?
