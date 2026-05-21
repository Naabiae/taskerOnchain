// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IStrategyAdapter.sol";

/**
 * @title MockStrategyAdapter
 * @notice Simple mock strategy adapter for composability integration testing.
 * @dev Transfers ERC20 tokens from the vault to a predefined recipient.
 *      Configurable canExecute result for testing condition checks.
 */
contract MockStrategyAdapter is IStrategyAdapter {

    bool public canExecuteResult = true;
    string public canExecuteReason = "";

    function setCanExecute(bool result, string memory reason) external {
        canExecuteResult = result;
        canExecuteReason = reason;
    }

    /// @notice Execute a token transfer from vault to recipient encoded in params
    /// @param vault    The UserVault address
    /// @param params   ABI-encoded (address token, uint256 amount, address recipient)
    function execute(address vault, bytes calldata params)
        external
        returns (bool success, bytes memory result)
    {
        (address token, uint256 amount, address recipient) =
            abi.decode(params, (address, uint256, address));

        if (token != address(0)) {
            IERC20(token).transferFrom(vault, recipient, amount);
        }

        result = abi.encode(recipient, amount);
        success = true;

        emit ActionExecuted(vault, recipient, success, result);
    }

    /// @notice Configurable condition check
    function canExecute(address /*vault*/, bytes calldata)
        external
        view
        override
        returns (bool canExec, string memory reason)
    {
        return (canExecuteResult, canExecuteReason);
    }

    /// @notice Decode params to return token requirements
    function getTokenRequirements(bytes calldata params)
        external
        pure
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        (address token, uint256 amount, ) =
            abi.decode(params, (address, uint256, address));

        tokens = new address[](1);
        amounts = new uint256[](1);
        tokens[0] = token;
        amounts[0] = amount;
    }

    /// @notice Always validates successfully
    function validateParams(bytes calldata)
        external
        pure
        returns (bool valid, string memory error)
    {
        return (true, "");
    }
}
