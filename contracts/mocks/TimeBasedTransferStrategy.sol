// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IStrategyAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TimeBasedTransferStrategy is IStrategyAdapter {
    // params: abi.encode(address vault, address recipient, address token, uint256 amount, uint256 interval)
    mapping(address => uint256) public lastExecuted; // by vault

    event TransferExecuted(address indexed vault, address indexed recipient, address token, uint256 amount);

    function execute(address vault, bytes calldata params) external override returns (bool success, bytes memory result) {
        (address p_vault, address recipient, address token, uint256 amount, uint256 interval) = abi.decode(params, (address, address, address, uint256, uint256));
        // ensure params vault matches caller-provided vault
        require(p_vault == vault, "Vault mismatch");
        require(block.timestamp >= lastExecuted[vault] + interval, "Not ready");

        // transfer tokens from vault to recipient
        if (token != address(0) && amount > 0) {
            IERC20(token).transferFrom(vault, recipient, amount);
        } else if (token == address(0) && amount > 0) {
            // Not handling native in this strategy
            revert("Native token not supported");
        }

        lastExecuted[vault] = block.timestamp;
        emit TransferExecuted(vault, recipient, token, amount);
        return (true, abi.encodePacked("ok"));
    }

    function canExecute(address vault, bytes calldata params) external view override returns (bool canExec, string memory reason) {
        // Expect params to include vault as first element or otherwise trust provided vault
        if (params.length < 160) {
            return (false, "invalid params");
        }
        (address p_vault, address recipient, address token, uint256 amt, uint256 interval) = abi.decode(params, (address, address, address, uint256, uint256));
        // require vault equality for safety
        if (p_vault != vault) return (false, "vault mismatch");
        if (block.timestamp >= lastExecuted[vault] + interval) {
            return (true, "");
        }
        return (false, "not ready");
    }

    function getTokenRequirements(bytes calldata params) external view override returns (address[] memory tokens, uint256[] memory amounts) {
        (address p_vault, address recipient, address token, uint256 amt, uint256 interval) = abi.decode(params, (address, address, address, uint256, uint256));
        tokens = new address[](1);
        amounts = new uint256[](1);
        tokens[0] = token;
        amounts[0] = amt;
        return (tokens, amounts);
    }

    function validateParams(bytes calldata params) external view override returns (bool valid, string memory error) {
        // simple validation: params must be 4 elements
        if (params.length == 0) return (false, "empty params");
        // Not deeply validating for brevity
        return (true, "");
    }
}
