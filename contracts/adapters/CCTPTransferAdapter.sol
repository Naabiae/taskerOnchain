// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IStrategyAdapter } from "../interfaces/IStrategyAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITokenMessenger {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);
}

/**
 * @title CCTPTransferAdapter
 * @dev Adapter to execute a time-based or immediate cross-chain bridge using Circle CCTP
 */
contract CCTPTransferAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    /**
     * @dev Executes a cross-chain transfer via CCTP
     * @param vault Address of the task vault
     * @param params abi.encoded parameters:
     *        - address cctpMessenger: Address of the TokenMessenger
     *        - address token: The token to bridge (e.g. USDC, EURC)
     *        - uint256 amount: Amount of token to bridge
     *        - uint32 destinationDomain: Destination chain domain ID
     *        - bytes32 mintRecipient: The recipient address on the destination chain (padded to 32 bytes)
     *        - uint256 executeAfter: Timestamp after which the bridge can be executed
     */
    function execute(address vault, bytes calldata params) external override returns (bool, bytes memory) {
        (
            address cctpMessenger,
            address token,
            uint256 amount,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            uint256 executeAfter
        ) = abi.decode(params, (address, address, uint256, uint32, bytes32, uint256));

        require(block.timestamp >= executeAfter, "Execution time not reached");

        // Transfer token from vault to this adapter
        IERC20(token).safeTransferFrom(vault, address(this), amount);

        // Approve CCTP Messenger
        IERC20(token).safeIncreaseAllowance(cctpMessenger, amount);

        // Execute CCTP depositForBurn
        uint64 nonce = ITokenMessenger(cctpMessenger).depositForBurn(
            amount,
            destinationDomain,
            mintRecipient,
            token
        );

        (bool okClear,) = address(IERC20(token)).call(abi.encodeWithSignature("approve(address,uint256)", cctpMessenger, 0));
        if (!okClear) {
            // ignore
        }

        emit ActionExecuted(vault, cctpMessenger, true, abi.encode(nonce));

        return (true, abi.encode(nonce));
    }

    function canExecute(address /*vault*/, bytes calldata params) external view override returns (bool, string memory) {
        (,, , , , uint256 executeAfter) = abi.decode(params, (address, address, uint256, uint32, bytes32, uint256));
        if (block.timestamp < executeAfter) {
            return (false, "Time not reached");
        }
        return (true, "Ready to bridge");
    }

    function getTokenRequirements(bytes calldata params) external pure override returns (address[] memory tokens, uint256[] memory amounts) {
        (, address token, uint256 amount, , ,) = abi.decode(params, (address, address, uint256, uint32, bytes32, uint256));
        tokens = new address[](1);
        tokens[0] = token;
        amounts = new uint256[](1);
        amounts[0] = amount;
    }

    function isProtocolSupported(address /*protocol*/) external pure returns (bool) {
        return true; // We don't limit protocols natively
    }

    function name() external pure returns (string memory) {
        return "CCTPTransferAdapter";
    }

    function validateParams(bytes calldata params) external pure override returns (bool, string memory) {
        if (params.length == 0) return (false, "Empty params");
        (address cctpMessenger, address token, uint256 amount, , bytes32 mintRecipient, ) = abi.decode(params, (address, address, uint256, uint32, bytes32, uint256));
        if (cctpMessenger == address(0)) return (false, "Invalid messenger");
        if (token == address(0)) return (false, "Invalid token");
        if (mintRecipient == bytes32(0)) return (false, "Invalid recipient");
        if (amount == 0) return (false, "Zero amount");
        return (true, "");
    }
}
