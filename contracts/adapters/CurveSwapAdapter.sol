// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategyAdapter } from "../interfaces/IStrategyAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICurvePool {
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);
}

/**
 * @title CurveSwapAdapter
 * @dev Adapter to swap tokens on Curve Finance
 */
contract CurveSwapAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    /**
     * @dev Executes a token swap on a Curve pool
     * @param vault Address of the task vault
     * @param params abi.encoded parameters:
     *        - address pool: The Curve pool address
     *        - address tokenIn: The token to sell
     *        - address tokenOut: The token to buy
     *        - int128 i: Index of tokenIn in the pool
     *        - int128 j: Index of tokenOut in the pool
     *        - uint256 amountIn: Amount of tokenIn to sell
     *        - uint256 minAmountOut: Minimum amount of tokenOut to receive
     *        - address recipient: The recipient of the swapped tokens
     */
    function execute(address vault, bytes calldata params) external override returns (bool, bytes memory) {
        (
            address pool,
            address tokenIn,
            address tokenOut,
            int128 i,
            int128 j,
            uint256 amountIn,
            uint256 minAmountOut,
            address recipient
        ) = abi.decode(params, (address, address, address, int128, int128, uint256, uint256, address));

        // Transfer tokenIn from the vault to this adapter
        IERC20(tokenIn).safeTransferFrom(vault, address(this), amountIn);

        // Approve Curve pool to spend tokenIn
        IERC20(tokenIn).safeIncreaseAllowance(pool, amountIn);

        // Execute swap
        uint256 amountOut = ICurvePool(pool).exchange(i, j, amountIn, minAmountOut);
        (bool okClear,) = address(IERC20(tokenIn)).call(abi.encodeWithSignature("approve(address,uint256)", pool, 0));
        if (!okClear) {
            // ignore
        }

        require(amountOut >= minAmountOut, "Slippage tolerance exceeded");

        // Transfer the received tokenOut to the recipient
        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        emit ActionExecuted(vault, pool, true, abi.encode(amountOut));

        return (true, abi.encode(amountOut));
    }

    function canExecute(address /*vault*/, bytes calldata /*params*/) external pure override returns (bool, string memory) {
        // Simple swap action has no external conditions by default, just executes immediately
        return (true, "Ready to swap");
    }

    function getTokenRequirements(bytes calldata params) external pure override returns (address[] memory tokens, uint256[] memory amounts) {
        (
            ,
            address tokenIn,
            ,
            ,
            ,
            uint256 amountIn,
            ,
        ) = abi.decode(params, (address, address, address, int128, int128, uint256, uint256, address));

        tokens = new address[](1);
        tokens[0] = tokenIn;

        amounts = new uint256[](1);
        amounts[0] = amountIn;
    }

    function isProtocolSupported(address /*protocol*/) external pure returns (bool) {
        return true;
    }

    function name() external pure returns (string memory) {
        return "CurveSwapAdapter";
    }

    function validateParams(bytes calldata params) external pure override returns (bool, string memory) {
        if (params.length == 0) {
            return (false, "Empty params");
        }
        (
            address pool,
            address tokenIn,
            address tokenOut,
            ,
            ,
            uint256 amountIn,
            ,
            address recipient
        ) = abi.decode(params, (address, address, address, int128, int128, uint256, uint256, address));

        if (pool == address(0)) return (false, "Invalid pool");
        if (tokenIn == address(0)) return (false, "Invalid tokenIn");
        if (tokenOut == address(0)) return (false, "Invalid tokenOut");
        if (recipient == address(0)) return (false, "Invalid recipient");
        if (amountIn == 0) return (false, "Zero amount");

        return (true, "");
    }
}
