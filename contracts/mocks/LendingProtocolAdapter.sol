// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IStrategyAdapter.sol";

contract LendingProtocolAdapter is IStrategyAdapter {
    mapping(address => uint256) public supplied;
    uint256 public totalLP;

    event Supplied(address indexed vault, address token, uint256 amount, uint256 lpMinted);

    function execute(address vault, bytes calldata params) external override returns (bool success, bytes memory result) {
        (address p_vault, address token, uint256 amount) = abi.decode(params, (address, address, uint256));
        require(p_vault == vault, "Vault mismatch");

        if (amount > 0) {
            IERC20(token).transferFrom(vault, address(this), amount);
            supplied[vault] += amount;
            uint256 lp = amount; // 1:1 for mock
            totalLP += lp;
            // mint LP to vault if supports - call by address
            // Best-effort: try low-level call without try/catch (wrap in unchecked to avoid reverting the whole tx)
            (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", vault, lp));
            if (!ok) {
                // noop
            }
            emit Supplied(vault, token, amount, lp);
        }
        return (true, abi.encodePacked("ok"));
    }

    function canExecute(address /*vault*/, bytes calldata params) external view override returns (bool canExec, string memory reason) {
        return (true, "");
    }

    function getTokenRequirements(bytes calldata params) external view override returns (address[] memory tokens, uint256[] memory amounts) {
        (address p_vault, address token, uint256 amount) = abi.decode(params, (address, address, uint256));
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
