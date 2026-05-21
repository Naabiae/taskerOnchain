// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategyAdapter } from "../interfaces/IStrategyAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IStorkOracle {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/**
 * @title StorkPriceTransferAdapter
 * @dev Adapter to execute a token transfer based on Stork Oracle price on Arc Testnet
 */
contract StorkPriceTransferAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    /**
     * @dev Executes a price-based token transfer
     * @param vault Address of the task vault
     * @param params abi.encoded parameters:
     *        - address storkOracle: The Stork price feed oracle address
     *        - address token: The token to transfer
     *        - uint256 amount: Amount of token to transfer
     *        - int256 targetPrice: The target price condition
     *        - bool isBelow: True if triggering when price < targetPrice, False if price >= targetPrice
     *        - address recipient: The destination address for the tokens
     */
    function execute(address vault, bytes calldata params) external override returns (bool, bytes memory) {
        (
            address storkOracle,
            address token,
            uint256 amount,
            int256 targetPrice,
            bool isBelow,
            address recipient
        ) = abi.decode(params, (address, address, uint256, int256, bool, address));

        (, int256 currentPrice, , , ) = IStorkOracle(storkOracle).latestRoundData();

        if (isBelow) {
            require(currentPrice < targetPrice, "Price condition not met (must be below)");
        } else {
            require(currentPrice >= targetPrice, "Price condition not met (must be above)");
        }

        // Transfer token from the caller (TaskVault) to this adapter
        IERC20(token).safeTransferFrom(vault, address(this), amount);

        // Transfer the tokens to the recipient
        IERC20(token).safeTransfer(recipient, amount);

        emit ActionExecuted(vault, recipient, true, abi.encode(amount));

        return (true, abi.encode(amount));
    }

    function canExecute(address /*vault*/, bytes calldata params) external view override returns (bool, string memory) {
        (address storkOracle, , , int256 targetPrice, bool isBelow, ) = abi.decode(params, (address, address, uint256, int256, bool, address));

        (, int256 currentPrice, , , ) = IStorkOracle(storkOracle).latestRoundData();

        if (isBelow) {
            if (currentPrice >= targetPrice) {
                return (false, "Price not below target");
            }
        } else {
            if (currentPrice < targetPrice) {
                return (false, "Price not above target");
            }
        }
        return (true, "Price condition met");
    }

    function getTokenRequirements(bytes calldata params) external pure override returns (address[] memory tokens, uint256[] memory amounts) {
        (, address token, uint256 amount, , ,) = abi.decode(params, (address, address, uint256, int256, bool, address));
        tokens = new address[](1);
        tokens[0] = token;
        amounts = new uint256[](1);
        amounts[0] = amount;
    }

    function isProtocolSupported(address /*protocol*/) external pure returns (bool) {
        return true;
    }

    function name() external pure returns (string memory) {
        return "StorkPriceTransferAdapter";
    }

    function validateParams(bytes calldata params) external pure override returns (bool, string memory) {
        if (params.length == 0) return (false, "Empty params");
        (address storkOracle, address token, uint256 amount, , , address recipient) = abi.decode(params, (address, address, uint256, int256, bool, address));
        if (storkOracle == address(0)) return (false, "Invalid oracle");
        if (token == address(0)) return (false, "Invalid token");
        if (recipient == address(0)) return (false, "Invalid recipient");
        if (amount == 0) return (false, "Zero amount");
        return (true, "");
    }
}