// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IStrategyAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RecurringTransferAdapter
 * @notice Adapter for recurring token transfers with hybrid funding (vault OR pull-based)
 * @dev Designed for UXmaxx Hackathon - supports Universal Accounts + EIP-7702 flow
 *
 * Two Funding Modes:
 * 1. VAULT: User deposits total amount upfront to TaskVault (traditional)
 * 2. PULL: User approves adapter, tokens pulled per-execution from their wallet/UA
 *
 * Use Cases:
 * - Recurring payments: "Send $50 to alice.eth weekly"
 * - Subscriptions: "Pay my Netflix subscription monthly"
 * - DCA: "Buy $100 ETH every day from my USDC balance"
 */
contract RecurringTransferAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    // ============ Types ============

    enum FundingMode {
        VAULT,  // Pull from TaskVault (user deposited upfront)
        PULL    // Pull from user's wallet/UA (approved spending)
    }

    /**
     * @notice Parameters for recurring transfers
     */
    struct RecurringParams {
        // Transfer details
        address token;              // Token to transfer (e.g., USDC)
        address recipient;          // Where to send tokens
        uint256 amountPerExecution; // Amount per execution

        // Schedule
        uint256 startTime;          // Unix timestamp of first execution
        uint256 interval;           // Seconds between executions (604800 = 1 week)
        uint256 maxExecutions;      // Total allowed executions (0 = unlimited)

        // Funding
        FundingMode fundingMode;    // VAULT or PULL
        address fundingSource;      // For PULL: user's wallet/UA address
    }

    // ============ State ============

    /// @notice Track execution count per task (keyed by params hash)
    mapping(bytes32 => uint256) public executionCounts;

    /// @notice Track last execution timestamp per task
    mapping(bytes32 => uint256) public lastExecutionTimes;

    // ============ Events ============

    event RecurringTransferExecuted(
        bytes32 indexed paramsHash,
        address indexed recipient,
        uint256 amount,
        uint256 executionNumber,
        FundingMode fundingMode
    );

    // ============ IStrategyAdapter Implementation ============

    /// @notice Adapter name for identification
    function name() external pure returns (string memory) {
        return "RecurringTransferAdapter";
    }

    /// @notice Check if a protocol is supported
    function isProtocolSupported(address) external pure returns (bool) {
        return true; // Supports any ERC20
    }

    /**
     * @inheritdoc IStrategyAdapter
     * @notice Returns per-execution token requirements
     * @dev For VAULT mode, tokens come from vault. For PULL mode, from fundingSource.
     */
    function getTokenRequirements(bytes calldata params)
        external
        pure
        override
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        RecurringParams memory p = abi.decode(params, (RecurringParams));

        tokens = new address[](1);
        amounts = new uint256[](1);

        tokens[0] = p.token;

        // For VAULT mode, TaskVault needs to hold per-execution amount
        // For PULL mode, we return 0 since tokens come from user's wallet
        if (p.fundingMode == FundingMode.VAULT) {
            amounts[0] = p.amountPerExecution;
        } else {
            amounts[0] = 0; // Pull mode - no vault funding needed
        }
    }

    /**
     * @inheritdoc IStrategyAdapter
     * @notice Check if execution conditions are met
     */
    function canExecute(address /*vault*/, bytes calldata params)
        external
        view
        override
        returns (bool canExec, string memory reason)
    {
        RecurringParams memory p = abi.decode(params, (RecurringParams));
        bytes32 paramsHash = keccak256(params);

        // Check 1: Max executions not reached
        uint256 execCount = executionCounts[paramsHash];
        if (p.maxExecutions > 0 && execCount >= p.maxExecutions) {
            return (false, "Max executions reached");
        }

        // Check 2: Time condition met
        uint256 nextExecTime;
        if (execCount == 0) {
            nextExecTime = p.startTime;
        } else {
            nextExecTime = lastExecutionTimes[paramsHash] + p.interval;
        }

        if (block.timestamp < nextExecTime) {
            return (
                false,
                string(abi.encodePacked(
                    "Too early - next execution at ",
                    _uint2str(nextExecTime),
                    " (current: ",
                    _uint2str(block.timestamp),
                    ")"
                ))
            );
        }

        // Check 3: For PULL mode, verify balance and allowance
        if (p.fundingMode == FundingMode.PULL) {
            uint256 balance = IERC20(p.token).balanceOf(p.fundingSource);
            if (balance < p.amountPerExecution) {
                return (false, "Insufficient balance in funding source");
            }

            uint256 allowance = IERC20(p.token).allowance(p.fundingSource, address(this));
            if (allowance < p.amountPerExecution) {
                return (false, "Insufficient allowance - user must approve adapter");
            }
        }

        return (true, "Ready to execute");
    }

    /**
     * @inheritdoc IStrategyAdapter
     * @notice Execute the recurring transfer
     * @param vault Address of TaskVault (used for VAULT funding mode)
     * @param params ABI-encoded RecurringParams
     */
    function execute(address vault, bytes calldata params)
        external
        override
        returns (bool success, bytes memory result)
    {
        // Step 1: Validate conditions
        (bool canExec, string memory reason) = this.canExecute(vault, params);
        if (!canExec) {
            return (false, bytes(reason));
        }

        // Step 2: Decode and validate
        RecurringParams memory p = abi.decode(params, (RecurringParams));
        bytes32 paramsHash = keccak256(params);

        if (p.recipient == address(0)) {
            return (false, bytes("Invalid recipient"));
        }
        if (p.amountPerExecution == 0) {
            return (false, bytes("Invalid amount"));
        }

        // Step 3: Update state BEFORE transfer (CEI pattern)
        executionCounts[paramsHash]++;
        lastExecutionTimes[paramsHash] = block.timestamp;

        // Step 4: Execute transfer based on funding mode
        if (p.fundingMode == FundingMode.VAULT) {
            // Pull from TaskVault
            try IERC20(p.token).transferFrom(vault, p.recipient, p.amountPerExecution) returns (bool transferSuccess) {
                if (!transferSuccess) {
                    // Revert state on failure
                    executionCounts[paramsHash]--;
                    return (false, bytes("Vault transfer failed"));
                }
            } catch Error(string memory err) {
                executionCounts[paramsHash]--;
                return (false, bytes(err));
            } catch {
                executionCounts[paramsHash]--;
                return (false, bytes("Vault transfer reverted"));
            }
        } else {
            // PULL mode: Pull from user's wallet/UA
            try IERC20(p.token).transferFrom(p.fundingSource, p.recipient, p.amountPerExecution) returns (bool transferSuccess) {
                if (!transferSuccess) {
                    executionCounts[paramsHash]--;
                    return (false, bytes("Pull transfer failed"));
                }
            } catch Error(string memory err) {
                executionCounts[paramsHash]--;
                return (false, bytes(err));
            } catch {
                executionCounts[paramsHash]--;
                return (false, bytes("Pull transfer reverted - check approval"));
            }
        }

        emit RecurringTransferExecuted(
            paramsHash,
            p.recipient,
            p.amountPerExecution,
            executionCounts[paramsHash],
            p.fundingMode
        );

        return (
            true,
            abi.encode(
                p.recipient,
                p.amountPerExecution,
                executionCounts[paramsHash],
                p.maxExecutions,
                block.timestamp
            )
        );
    }

    /// @inheritdoc IStrategyAdapter
    function validateParams(bytes calldata params)
        external
        view
        override
        returns (bool isValid, string memory errorMessage)
    {
        try this.decodeParams(params) returns (RecurringParams memory p) {
            if (p.token == address(0)) {
                return (false, "Invalid token address");
            }
            if (p.recipient == address(0)) {
                return (false, "Invalid recipient address");
            }
            if (p.amountPerExecution == 0) {
                return (false, "Amount must be greater than 0");
            }
            if (p.startTime == 0) {
                return (false, "Start time must be set");
            }
            if (p.interval == 0) {
                return (false, "Interval must be greater than 0");
            }
            if (p.fundingMode == FundingMode.PULL && p.fundingSource == address(0)) {
                return (false, "Pull mode requires valid funding source address");
            }

            return (true, "");
        } catch {
            return (false, "Invalid parameter encoding");
        }
    }

    // ============ View Helpers ============

    /// @notice Get execution state for a task
    function getExecutionState(bytes calldata params)
        external
        view
        returns (
            uint256 executionsCompleted,
            uint256 lastExecution,
            uint256 nextExecution,
            bool isComplete
        )
    {
        RecurringParams memory p = abi.decode(params, (RecurringParams));
        bytes32 paramsHash = keccak256(params);

        executionsCompleted = executionCounts[paramsHash];
        lastExecution = lastExecutionTimes[paramsHash];

        if (executionsCompleted == 0) {
            nextExecution = p.startTime;
        } else {
            nextExecution = lastExecution + p.interval;
        }

        isComplete = p.maxExecutions > 0 && executionsCompleted >= p.maxExecutions;
    }

    /// @notice Calculate total funding needed for VAULT mode
    function calculateTotalFunding(bytes calldata params)
        external
        pure
        returns (uint256 totalAmount, uint256 perExecution, uint256 executions)
    {
        RecurringParams memory p = abi.decode(params, (RecurringParams));
        perExecution = p.amountPerExecution;
        executions = p.maxExecutions;
        totalAmount = p.maxExecutions > 0
            ? p.amountPerExecution * p.maxExecutions
            : 0; // Unlimited requires PULL mode
    }

    /// @notice Decode params helper
    function decodeParams(bytes calldata params)
        external
        pure
        returns (RecurringParams memory)
    {
        return abi.decode(params, (RecurringParams));
    }

    // ============ Internal Helpers ============

    function _uint2str(uint256 _i) internal pure returns (string memory str) {
        if (_i == 0) return "0";
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
}
