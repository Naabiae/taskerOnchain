// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IStrategyAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockStrategy is IStrategyAdapter {
    bool public allow;
    address public lastVault;
    bytes public lastParams;
    address[] public tokens;
    uint256[] public amounts;

    constructor(address[] memory _tokens, uint256[] memory _amounts) {
        tokens = _tokens;
        amounts = _amounts;
        allow = true;
    }

    function setAllow(bool v) external {
        allow = v;
    }

    function execute(address vault, bytes calldata params) external override returns (bool success, bytes memory result) {
        lastVault = vault;
        lastParams = params;
        // emulate token transfers: assume vault approved
        for (uint i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(0) && amounts[i] > 0) {
                IERC20(tokens[i]).transferFrom(vault, address(this), amounts[i]);
            }
        }
        emit ActionExecuted(vault, address(this), true, params);
        return (true, params);
    }

    function canExecute(bytes calldata params) external view override returns (bool canExec, string memory reason) {
        if (allow) return (true, "");
        return (false, "not allowed");
    }

    function getTokenRequirements(bytes calldata params) external view override returns (address[] memory _tokens, uint256[] memory _amounts) {
        return (tokens, amounts);
    }

    function validateParams(bytes calldata params) external view override returns (bool valid, string memory error) {
        return (true, "");
    }
}
