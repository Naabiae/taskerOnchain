// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IStrategyAdapter.sol";

contract SimpleSwapAdapter is IStrategyAdapter {
    // params: (address vault, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)

    event SwapExecuted(address indexed vault, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    function execute(address vault, bytes calldata params) external override returns (bool success, bytes memory result) {
        (address p_vault, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) = abi.decode(params, (address, address, address, uint256, uint256));
        require(p_vault == vault, "Vault mismatch");

        // take tokenIn from vault
        if (amountIn > 0) {
            IERC20(tokenIn).transferFrom(vault, address(this), amountIn);
        }

        // mint tokenOut to vault if tokenOut supports mint (MockERC20)
        if (amountOut > 0) {
            // try to mint via low-level call (best-effort), else transfer from this contract
            (bool ok,) = address(tokenOut).call(abi.encodeWithSignature("mint(address,uint256)", vault, amountOut));
            if (!ok) {
                // fallback: transfer from this contract (requires this contract has tokens)
                IERC20(tokenOut).transfer(vault, amountOut);
            }
        }

        emit SwapExecuted(vault, tokenIn, tokenOut, amountIn, amountOut);
        return (true, abi.encodePacked("ok"));
    }

    function canExecute(address /*vault*/, bytes calldata params) external view override returns (bool canExec, string memory reason) {
        // always allow; BaseVault checks balances/approvals
        return (true, "");
    }

    function getTokenRequirements(bytes calldata params) external view override returns (address[] memory tokens, uint256[] memory amounts) {
        (address p_vault, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) = abi.decode(params, (address, address, address, uint256, uint256));
        tokens = new address[](1);
        amounts = new uint256[](1);
        tokens[0] = tokenIn;
        amounts[0] = amountIn;
        return (tokens, amounts);
    }

    function validateParams(bytes calldata params) external view override returns (bool valid, string memory error) {
        if (params.length == 0) return (false, "empty");
        return (true, "");
    }
}
