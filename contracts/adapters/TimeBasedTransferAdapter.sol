// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IStrategyAdapter.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title TimeBasedTransferAdapter
 * @notice Simple adapter for testing: transfers tokens when a specific timestamp is reached
 * @dev Perfect for testnet protocol testing - just set a time and recipient
 *
 * Use Case:
 * - User deposits USDC into TaskVault
 * - Creates task with execution time (e.g., "transfer at 2pm tomorrow")
 * - When time arrives, executor can trigger the transfer
 * - Tokens go to specified recipient
 *
 * ✅ REFACTORED: Now uses clean 4-parameter structure with getTokenRequirements()
 * No longer needs 6-parameter Uniswap workaround!
 */
contract TimeBasedTransferAdapter is IStrategyAdapter {
    /**
     * @notice Clean parameter structure for time-based transfers
     * @dev No more fake/ignored fields - just what we actually need!
     */
    struct TransferParams {
        address token;           // Token to transfer (e.g., Mock USDC)
        address recipient;       // Where to send tokens
        uint256 amount;          // Amount to transfer
        uint256 executeAfter;    // Timestamp when task can execute
    }

    /**
     * @notice Get token requirements for this transfer
     * @dev Implements IStrategyAdapter.getTokenRequirements() - tells vault what tokens/amounts we need
     * @param params ABI-encoded TransferParams
     * @return tokens Array with single token address
     * @return amounts Array with single amount value
     */
    function getTokenRequirements(bytes calldata params)
        external
        pure
        override
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        TransferParams memory p = abi.decode(params, (TransferParams));

        // Single-token adapter: return one token and one amount
        tokens = new address[](1);
        amounts = new uint256[](1);

        tokens[0] = p.token;
        amounts[0] = p.amount;
    }

    /**
     * @notice Check if the time condition is met
     * @param params ABI-encoded TransferParams (4 clean fields)
     * @return canExec True if current time >= executeAfter
     * @return reason Human-readable reason
     */
    function canExecute(address /*vault*/, bytes calldata params)
        external
        view
        override
        returns (bool canExec, string memory reason)
    {
        TransferParams memory p = abi.decode(params, (TransferParams));

        // Check if time has arrived
        if (block.timestamp < p.executeAfter) {
            return (
                false,
                string(
                    abi.encodePacked(
                        'Too early - execute after ',
                        _uint2str(p.executeAfter),
                        ' (current: ',
                        _uint2str(block.timestamp),
                        ')'
                    )
                )
            );
        }

        return (true, 'Time condition met - ready to execute');
    }

    /**
     * @notice Execute the token transfer
     * @param vault Address of TaskVault holding the tokens
     * @param params ABI-encoded TransferParams (4 clean fields)
     * @return success True if transfer succeeded
     * @return result Encoded result data
     */
    function execute(address vault, bytes calldata params)
        external
        override
        returns (bool success, bytes memory result)
    {
        // Step 1: Check time condition
        (bool conditionMet, string memory reason) = this.canExecute(address(this), params);
        if (!conditionMet) {
            return (false, bytes(reason));
        }

        // Step 2: Decode parameters
        TransferParams memory p = abi.decode(params, (TransferParams));

        // Step 3: Validate parameters
        if (p.recipient == address(0)) {
            return (false, bytes('Invalid recipient'));
        }
        if (p.amount == 0) {
            return (false, bytes('Invalid amount'));
        }

        // Step 4: Transfer tokens from vault to recipient
        try IERC20(p.token).transferFrom(vault, p.recipient, p.amount) returns (
            bool transferSuccess
        ) {
            if (!transferSuccess) {
                return (false, bytes('Token transfer failed'));
            }

            return (
                true,
                abi.encode(
                    p.recipient,
                    p.amount,
                    block.timestamp,
                    'Transfer successful'
                )
            );
        } catch Error(string memory err) {
            return (false, bytes(err));
        } catch {
            return (false, bytes('Transfer reverted'));
        }
    }

    /**
     * @notice Helper to convert uint to string for error messages
     */
    function _uint2str(uint256 _i) internal pure returns (string memory str) {
        if (_i == 0) {
            return '0';
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + (j % 10)));
            j /= 10;
        }
        str = string(bstr);
    }


    /// @notice Check if a protocol is supported
    function isProtocolSupported(address protocol) external view returns (bool) {
        return true;
    }

    /// @notice Adapter name for identification
    function name() external pure returns (string memory) {
        return "TimeBasedTransferAdapter";
    }

    /// @inheritdoc IStrategyAdapter
    /// @notice Validate parameters during task creation
    /// @dev Catches encoding errors early instead of at execution time
    function validateParams(bytes calldata params)
        external
        view
        override
        returns (bool isValid, string memory errorMessage)
    {
        // Try to decode parameters
        try this.decodeParams(params) returns (TransferParams memory p) {
            // Validate each field
            if (p.token == address(0)) {
                return (false, "Invalid token address (zero address)");
            }
            if (p.recipient == address(0)) {
                return (false, "Invalid recipient address (zero address)");
            }
            if (p.amount == 0) {
                return (false, "Invalid amount (zero)");
            }
            if (p.executeAfter == 0) {
                return (false, "Invalid executeAfter timestamp (zero)");
            }

            // All validations passed
            return (true, "");
        } catch Error(string memory reason) {
            return (false, string(abi.encodePacked("Decoding failed: ", reason)));
        } catch {
            return (false, "Decoding failed: Invalid parameter encoding");
        }
    }

    /// @notice Internal helper to decode params (used by validateParams)
    function decodeParams(bytes calldata params)
        external
        pure
        returns (TransferParams memory)
    {
        return abi.decode(params, (TransferParams));
    }
}
