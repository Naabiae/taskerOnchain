// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IStrategyAdapter.sol";
import "./LendingProtocolAdapter.sol";
import "./SimpleSwapAdapter.sol";

contract CompoundStrategyAdapter is IStrategyAdapter {
    // params: (address vault, string action, address token, uint256 amount, address swapToken, uint256 swapAmountOut)

    function execute(address vault, bytes calldata params) external override returns (bool success, bytes memory result) {
        (address p_vault, string memory action, address token, uint256 amount, address swapToken, uint256 swapOut) = abi.decode(params, (address, string, address, uint256, address, uint256));
        require(p_vault == vault, "Vault mismatch");

        if (keccak256(bytes(action)) == keccak256(bytes("supply"))) {
            // call lending
            (bool ok,) = address(new LendingProtocolAdapter()).call(abi.encodeWithSignature("execute(address,bytes)", vault, abi.encode(vault, token, amount)));
            require(ok, "lend failed");
        } else if (keccak256(bytes(action)) == keccak256(bytes("withdraw"))) {
            // withdraw -> swap
            (bool ok,) = address(new LendingProtocolAdapter()).call(abi.encodeWithSignature("execute(address,bytes)", vault, abi.encode(vault, token, amount)));
            require(ok, "lend failed");
            (ok,) = address(new SimpleSwapAdapter()).call(abi.encodeWithSignature("execute(address,bytes)", vault, abi.encode(vault, token, swapToken, amount, swapOut)));
            require(ok, "swap failed");
        }
        return (true, abi.encodePacked("ok"));
    }

    function canExecute(address /*vault*/, bytes calldata params) external view override returns (bool canExec, string memory reason) {
        return (true, "");
    }

    function getTokenRequirements(bytes calldata params) external view override returns (address[] memory tokens, uint256[] memory amounts) {
        // best-effort: return token from params
        (address p_vault, string memory action, address token, uint256 amount, address swapToken, uint256 swapOut) = abi.decode(params, (address, string, address, uint256, address, uint256));
        tokens = new address[](1);
        amounts = new uint256[](1);
        tokens[0] = token;
        amounts[0] = amount;
        return (tokens, amounts);
    }

    function validateParams(bytes calldata params) external view override returns (bool valid, string memory error) {
        if (params.length == 0) return (false, "empty");
        return (true, "");
    }
}
