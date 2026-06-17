// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategyAdapter } from "../../interfaces/IStrategyAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Uniswap V3 SwapRouter interface (SwapRouter02)
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title UniswapV3SwapAdapter
 * @notice Adapter for executing token swaps on Uniswap V3 (Base chain)
 * @dev Supports both single-hop and multi-hop swaps
 *
 * Base Mainnet Addresses:
 * - SwapRouter02: 0x2626664c2603336E57B271c5C0b26F421741e481
 * - Factory: 0x33128a8fC17869897dcE68Ed026d694621f6FDfD
 *
 * Base Sepolia Addresses:
 * - SwapRouter02: 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4
 */
contract UniswapV3SwapAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    /// @notice Default Uniswap V3 SwapRouter on Base Sepolia
    address public immutable swapRouter;

    /// @notice Common fee tiers on Uniswap V3
    uint24 public constant FEE_LOW = 500;      // 0.05%
    uint24 public constant FEE_MEDIUM = 3000;  // 0.3%
    uint24 public constant FEE_HIGH = 10000;   // 1%

    constructor(address _swapRouter) {
        require(_swapRouter != address(0), "Invalid router");
        swapRouter = _swapRouter;
    }

    /**
     * @notice Execute a token swap on Uniswap V3
     * @param vault Address of the task vault
     * @param params ABI-encoded parameters:
     *        - address tokenIn: Token to sell
     *        - address tokenOut: Token to buy
     *        - uint24 fee: Pool fee tier (500, 3000, or 10000)
     *        - uint256 amountIn: Amount of tokenIn to swap
     *        - uint256 amountOutMin: Minimum amount of tokenOut to receive
     *        - address recipient: Address to receive tokenOut
     *        - uint256 deadline: Unix timestamp deadline (0 = no deadline)
     */
    function execute(address vault, bytes calldata params) external override returns (bool, bytes memory) {
        (
            address tokenIn,
            address tokenOut,
            uint24 fee,
            uint256 amountIn,
            uint256 amountOutMin,
            address recipient,
            uint256 deadline
        ) = abi.decode(params, (address, address, uint24, uint256, uint256, address, uint256));

        // Check deadline if set
        if (deadline > 0) {
            require(block.timestamp <= deadline, "Swap deadline passed");
        }

        // Transfer tokenIn from vault to this adapter
        IERC20(tokenIn).safeTransferFrom(vault, address(this), amountIn);

        // Approve SwapRouter to spend tokenIn
        IERC20(tokenIn).safeIncreaseAllowance(swapRouter, amountIn);

        // Build swap params
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Execute swap
        uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle(swapParams);
        // clear allowance (best-effort)
        (bool okClear,) = address(IERC20(tokenIn)).call(abi.encodeWithSignature("approve(address,uint256)", swapRouter, 0));
        if (!okClear) {
            // ignore - some tokens don't return bool
        }

        require(amountOut >= amountOutMin, "Slippage exceeded");

        emit ActionExecuted(vault, swapRouter, true, abi.encode(amountOut));

        return (true, abi.encode(amountOut));
    }

    /**
     * @notice Check if swap can be executed
     * @dev Always returns true for immediate swaps (no time/price conditions)
     */
    function canExecute(address /*vault*/, bytes calldata params) external view override returns (bool, string memory) {
        (,,,,,, uint256 deadline) = abi.decode(params, (address, address, uint24, uint256, uint256, address, uint256));

        if (deadline > 0 && block.timestamp > deadline) {
            return (false, "Deadline passed");
        }

        return (true, "Ready to swap");
    }

    /**
     * @notice Get token requirements for the swap
     */
    function getTokenRequirements(bytes calldata params)
        external
        pure
        override
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        (address tokenIn,,, uint256 amountIn,,,) = abi.decode(
            params,
            (address, address, uint24, uint256, uint256, address, uint256)
        );

        tokens = new address[](1);
        tokens[0] = tokenIn;

        amounts = new uint256[](1);
        amounts[0] = amountIn;
    }

    function isProtocolSupported(address protocol) external view returns (bool) {
        return protocol == swapRouter;
    }

    function name() external pure returns (string memory) {
        return "UniswapV3SwapAdapter-Base";
    }

    function validateParams(bytes calldata params) external pure override returns (bool, string memory) {
        if (params.length == 0) {
            return (false, "Empty params");
        }

        (
            address tokenIn,
            address tokenOut,
            uint24 fee,
            uint256 amountIn,
            ,
            address recipient,
        ) = abi.decode(params, (address, address, uint24, uint256, uint256, address, uint256));

        if (tokenIn == address(0)) return (false, "Invalid tokenIn");
        if (tokenOut == address(0)) return (false, "Invalid tokenOut");
        if (tokenIn == tokenOut) return (false, "Same token");
        if (fee != 500 && fee != 3000 && fee != 10000) return (false, "Invalid fee tier");
        if (amountIn == 0) return (false, "Zero amount");
        if (recipient == address(0)) return (false, "Invalid recipient");

        return (true, "");
    }
}
