# How to Write a Strategy Adapter

## The Interface

Every adapter must implement IStrategyAdapter:

```solidity
interface IStrategyAdapter {
    
    // Execute the strategy
    // Vault has already approved the exact amount returned by getTokenRequirements()
    // Adapter pulls tokens, executes, and returns control to vault
    function execute(address vault, bytes calldata params)
        external returns (bool success, bytes memory result);
    
    // Check if strategy conditions are met
    // Called by ExecutorHub before triggering automation
    // Called by vault before executing immediate strategy
    function canExecute(bytes calldata params)
        external view returns (bool canExecute, string memory reason);
    
    // Return exact tokens and amounts needed
    // Vault uses this to approve the exact amount to the adapter
    // Never over-approve. Never under-approve.
    function getTokenRequirements(bytes calldata params)
        external view returns (address[] memory tokens, uint256[] memory amounts);
    
    // Validate params are correctly encoded
    // Called by vault before creating an automation
    // Catch encoding errors early, don't let bad automations exist
    function validateParams(bytes calldata params)
        external view returns (bool valid, string memory error);
}
```

## Example 1: Uniswap Swap (Simple)

```solidity
pragma solidity ^0.8.20;
import "./IStrategyAdapter.sol";
import "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UniswapV3SwapAdapter is IStrategyAdapter {
    
    ISwapRouter public constant swapRouter = ISwapRouter(...);
    
    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint256 minAmountOut;
    }
    
    function execute(address vault, bytes calldata params)
        external returns (bool, bytes memory)
    {
        SwapParams memory p = abi.decode(params, (SwapParams));
        
        // Vault has already approved amountIn to this adapter
        IERC20(p.tokenIn).transferFrom(vault, address(this), p.amountIn);
        
        // Approve swap router
        IERC20(p.tokenIn).approve(address(swapRouter), p.amountIn);
        
        // Execute swap
        uint256 amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: p.tokenIn,
                tokenOut: p.tokenOut,
                fee: p.fee,
                recipient: vault,  // Return tokens directly to vault
                deadline: block.timestamp + 60,
                amountIn: p.amountIn,
                amountOutMinimum: p.minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        
        return (amountOut >= p.minAmountOut, abi.encode(amountOut));
    }
    
    function canExecute(bytes calldata params)
        external view returns (bool, string memory)
    {
        SwapParams memory p = abi.decode(params, (SwapParams));
        
        // Get current price from Uniswap pool
        uint160 sqrtPrice = _getSqrtPriceX96(p.tokenIn, p.tokenOut, p.fee);
        
        // Calculate expected output at current price
        uint256 expectedOut = _getAmountOut(p.amountIn, sqrtPrice);
        
        // Check if we'd get minAmountOut
        if (expectedOut < p.minAmountOut) {
            return (false, "Insufficient output amount");
        }
        
        return (true, "");
    }
    
    function getTokenRequirements(bytes calldata params)
        external pure returns (address[] memory tokens, uint256[] memory amounts)
    {
        SwapParams memory p = abi.decode(params, (SwapParams));
        
        tokens = new address[](1);
        amounts = new uint256[](1);
        
        tokens[0] = p.tokenIn;
        amounts[0] = p.amountIn;
        
        return (tokens, amounts);
    }
    
    function validateParams(bytes calldata params)
        external pure returns (bool, string memory)
    {
        try this._decode(params) {
            return (true, "");
        } catch {
            return (false, "Invalid params");
        }
    }
    
    function _decode(bytes calldata params) external pure {
        abi.decode(params, (SwapParams));
    }
}
```

---

## Example 2: Aave Supply (Medium)

```solidity
pragma solidity ^0.8.20;
import "./IStrategyAdapter.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AaveSupplyAdapter is IStrategyAdapter {
    
    IPool public constant aavePool = IPool(...);
    
    struct SupplyParams {
        address asset;
        uint256 amount;
        bool useAsCollateral;
    }
    
    function execute(address vault, bytes calldata params)
        external returns (bool, bytes memory)
    {
        SupplyParams memory p = abi.decode(params, (SupplyParams));
        
        // Vault has already approved amount to this adapter
        IERC20(p.asset).transferFrom(vault, address(this), p.amount);
        
        // Approve Aave pool
        IERC20(p.asset).approve(address(aavePool), p.amount);
        
        // Supply to Aave
        // Aave returns aToken to vault
        aavePool.supply(p.asset, p.amount, vault, 0);
        
        // If we want to use it as collateral immediately (requires special handling)
        if (p.useAsCollateral) {
            aavePool.setUserUseReserveAsCollateral(p.asset, true);
        }
        
        return (true, abi.encode(p.amount));
    }
    
    function canExecute(bytes calldata params)
        external view returns (bool, string memory)
    {
        SupplyParams memory p = abi.decode(params, (SupplyParams));
        
        // Get reserve data
        (
            ,
            ,
            ,
            ,
            ,
            uint256 liquidityThreshold,
            ,
            ,
            ,
        ) = aavePool.getConfiguration(p.asset).getParamsMemory();
        
        // Always executable unless reserve is frozen
        // This is a simplified check; real implementation would check freezing
        if (liquidityThreshold == 0) {
            return (false, "Reserve is frozen");
        }
        
        return (true, "");
    }
    
    function getTokenRequirements(bytes calldata params)
        external pure returns (address[] memory tokens, uint256[] memory amounts)
    {
        SupplyParams memory p = abi.decode(params, (SupplyParams));
        
        tokens = new address[](1);
        amounts = new uint256[](1);
        
        tokens[0] = p.asset;
        amounts[0] = p.amount;
        
        return (tokens, amounts);
    }
    
    function validateParams(bytes calldata params)
        external pure returns (bool, string memory)
    {
        try this._decode(params) {
            SupplyParams memory p = abi.decode(params, (SupplyParams));
            if (p.asset == address(0)) return (false, "Invalid asset");
            if (p.amount == 0) return (false, "Zero amount");
            return (true, "");
        } catch {
            return (false, "Invalid params");
        }
    }
    
    function _decode(bytes calldata params) external pure {
        abi.decode(params, (SupplyParams));
    }
}
```

---

## Example 3: Lido Stake (Conditional Execution)

```solidity
pragma solidity ^0.8.20;
import "./IStrategyAdapter.sol";
import "@lido/contracts/Lido.sol";

contract LidoStakeAdapter is IStrategyAdapter {
    
    ILido public constant lido = ILido(...);
    
    struct StakeParams {
        uint256 ethAmount;
        // Could add: max slippage on stETH/ETH, referral, etc.
    }
    
    function execute(address vault, bytes calldata params)
        external returns (bool, bytes memory)
    {
        StakeParams memory p = abi.decode(params, (StakeParams));
        
        // Vault sends ETH value to this adapter via call{value: p.ethAmount}()
        // This is handled by BaseVault._executeStrategy() passing value parameter
        require(msg.value == p.ethAmount, "Value mismatch");
        
        // Call Lido with ETH
        uint256 stETHReceived = lido.submit{value: p.ethAmount}(address(0));
        
        // Transfer stETH back to vault
        IERC20(address(lido)).transfer(vault, stETHReceived);
        
        return (true, abi.encode(stETHReceived));
    }
    
    function canExecute(bytes calldata params)
        external view returns (bool, string memory)
    {
        StakeParams memory p = abi.decode(params, (StakeParams));
        
        // Check Lido is not stopped
        if (lido.isStopped()) {
            return (false, "Lido is paused");
        }
        
        // Check we'd get reasonable stETH back
        // Typically stETH/ETH ratio is ~0.99-1.00
        // But can vary; check against oracle if strict
        
        return (true, "");
    }
    
    function getTokenRequirements(bytes calldata params)
        external pure returns (address[] memory tokens, uint256[] memory amounts)
    {
        // For native ETH strategies, we return address(0) = ETH
        tokens = new address[](1);
        amounts = new uint256[](1);
        
        StakeParams memory p = abi.decode(params, (StakeParams));
        
        tokens[0] = address(0);  // ETH
        amounts[0] = p.ethAmount;
        
        return (tokens, amounts);
    }
    
    function validateParams(bytes calldata params)
        external pure returns (bool, string memory)
    {
        try this._decode(params) {
            StakeParams memory p = abi.decode(params, (StakeParams));
            if (p.ethAmount == 0) return (false, "Zero ETH amount");
            return (true, "");
        } catch {
            return (false, "Invalid params");
        }
    }
    
    function _decode(bytes calldata params) external pure {
        abi.decode(params, (StakeParams));
    }
    
    // For ETH receive
    receive() external payable {}
}
```

---

## Best Practices

### 1. Always Return Tokens to Vault
```solidity
// ✅ GOOD — token goes back to vault
IERC20(outputToken).transfer(vault, amount);

// ❌ BAD — token stuck in adapter
IERC20(outputToken).transfer(address(this), amount);
```

### 2. getTokenRequirements Must Match execute
If getTokenRequirements says "need 1000 USDC", execute must only use 1000 USDC.
```solidity
// ✅ GOOD
function getTokenRequirements(bytes calldata params) external pure returns (...) {
    SwapParams memory p = abi.decode(params, (SwapParams));
    amounts[0] = p.amountIn;  // Same value
}

function execute(address vault, bytes calldata params) external returns (...) {
    SwapParams memory p = abi.decode(params, (SwapParams));
    IERC20(p.tokenIn).transferFrom(vault, address(this), p.amountIn);  // Same value
}
```

### 3. canExecute Should Be Cheap
Don't do expensive calculations in canExecute. It's called by ExecutorHub in a loop across all tasks.
```solidity
// ❌ EXPENSIVE — external calls in loop
function canExecute(bytes calldata params) external view {
    uint256 price = oracle.getPrice(...);  // external call
}

// ✅ CHEAP — uses cached data
function canExecute(bytes calldata params) external view {
    uint256 price = _cachedPrice;  // internal state
}
```

### 4. Error Messages in canExecute
Return human-readable reason why execution can't happen. ExecutorHub logs this.
```solidity
// ✅ GOOD
if (price < minPrice) {
    return (false, "Price too low: current 1800, min 2000");
}

// ❌ VAGUE
if (price < minPrice) {
    return (false, "Condition not met");
}
```

### 5. Validate Early
validateParams is called when vault creates automation. Catch encoding errors then, not during execution.
```solidity
function validateParams(bytes calldata params)
    external pure returns (bool, string memory)
{
    SwapParams memory p = abi.decode(params, (SwapParams));
    
    // Check every invariant
    if (p.tokenIn == address(0)) return (false, "tokenIn is zero");
    if (p.tokenOut == address(0)) return (false, "tokenOut is zero");
    if (p.tokenIn == p.tokenOut) return (false, "Cannot swap same token");
    if (p.amountIn == 0) return (false, "amountIn is zero");
    if (p.minAmountOut > p.amountIn) return (false, "minOut exceeds in");
    
    return (true, "");
}
```

---

## Testing Adapters

### Unit Tests (Foundry)
```solidity
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../adapters/UniswapV3SwapAdapter.sol";

contract UniswapV3SwapAdapterTest is Test {
    UniswapV3SwapAdapter adapter;
    
    function setUp() public {
        adapter = new UniswapV3SwapAdapter();
    }
    
    function test_getTokenRequirements() public {
        UniswapV3SwapAdapter.SwapParams memory p = UniswapV3SwapAdapter.SwapParams({
            tokenIn: USDC,
            tokenOut: ETH,
            fee: 3000,
            amountIn: 1000e6,
            minAmountOut: 0.5e18
        });
        
        (address[] memory tokens, uint256[] memory amounts) = 
            adapter.getTokenRequirements(abi.encode(p));
        
        assertEq(tokens[0], USDC);
        assertEq(amounts[0], 1000e6);
    }
    
    function test_validateParams() public {
        UniswapV3SwapAdapter.SwapParams memory p = UniswapV3SwapAdapter.SwapParams({
            tokenIn: USDC,
            tokenOut: ETH,
            fee: 3000,
            amountIn: 1000e6,
            minAmountOut: 0.5e18
        });
        
        (bool valid, string memory err) = 
            adapter.validateParams(abi.encode(p));
        
        assertTrue(valid);
    }
    
    function test_validateParams_invalidTokenIn() public {
        UniswapV3SwapAdapter.SwapParams memory p = UniswapV3SwapAdapter.SwapParams({
            tokenIn: address(0),  // INVALID
            tokenOut: ETH,
            fee: 3000,
            amountIn: 1000e6,
            minAmountOut: 0.5e18
        });
        
        (bool valid,) = adapter.validateParams(abi.encode(p));
        assertFalse(valid);
    }
}
```

### Fork Tests (Test on Real Mainnet Fork)
```solidity
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../adapters/UniswapV3SwapAdapter.sol";

contract UniswapV3SwapAdapterForkTest is Test {
    
    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc");
    }
    
    function test_execute_swapUSDCtoETH() public {
        // Get USDC whale
        address whale = 0x...;  // USDC holder
        
        vm.startPrank(whale);
        
        // Approve adapter
        IERC20(USDC).approve(address(adapter), 1000e6);
        
        // Call adapter.execute (normally called by vault)
        (bool success, bytes memory result) = adapter.execute(whale, abi.encode(...));
        
        assertTrue(success);
        
        uint256 ethReceived = abi.decode(result, (uint256));
        assertGt(ethReceived, 0);
        
        vm.stopPrank();
    }
}
```

---

## Deployment Checklist

Before deploying a new adapter:
- [ ] validateParams catches all invalid inputs
- [ ] canExecute is gas-efficient (< 10k gas)
- [ ] execute returns tokens to vault, not adapter
- [ ] execute's token usage matches getTokenRequirements
- [ ] Unit tests pass (at least 3 test cases)
- [ ] Fork test passes against real Arbitrum state
- [ ] Arbiscan verification (code is public)
- [ ] StrategyRegistry.registerStrategy() called to whitelist

---

## Common Pitfalls

### 1. Approval Not Revoked After Execute
**Problem**: Vault approves 1000 USDC to adapter, but adapter only uses 100. Leftover 900 USDC is still approved.
**Solution**: Use SafeERC20.forceApprove(0) or ensure getTokenRequirements is exact.

### 2. External Calls in canExecute
**Problem**: canExecute calls external price oracle. Keeper loop calls canExecute on 1000 tasks. = 1000 oracle calls = high gas, slow.
**Solution**: Use cached prices (updated by separate keeper), or move expensive logic to execute (adapter can fail gracefully).

### 3. Unbounded Loops in Adapter
**Problem**: Adapter has for loop that could iterate 10000+ times. Execution runs out of gas.
**Solution**: Batch limits. If processing 100 items per call, can only handle 100, not unlimited.

### 4. Trust Assumptions Break
**Problem**: Adapter assumes "Uniswap price is always correct" but oracle is stale, returns wrong price.
**Solution**: Always add safety checks (canExecute validates, execute has minimum output check).

---

## Adapter Registry

When you write a new adapter, add it to ADAPTER_REGISTRY.md:

```markdown
## UniswapV3SwapAdapter
- Address: 0x...
- Network: Arbitrum One
- Tokens: Any ERC20 pair with pool on Uni
- Conditions: Price tolerance (slippage)
- Gas: ~150k per execution
- Whitelisted: Yes

## AaveSupplyAdapter
- Address: 0x...
- Network: Arbitrum One
- Tokens: Any Aave-supported asset
- Conditions: Reserve not frozen
- Gas: ~120k per execution
- Whitelisted: Yes
```

This is your adapter documentation for judges + future builders.
