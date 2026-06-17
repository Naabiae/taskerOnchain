// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStrategyAdapter
 * @notice Interface for strategy adapters — protocol-level capabilities.
 *
 * @dev Each adapter IS a complete strategy. A single adapter can encapsulate
 *      multi-step logic internally (price monitoring, swapping, yield deployment).
 *      The vault gives temporary ERC20 approval; adapter pulls tokens, executes,
 *      and returns tokens/yield tokens back to the vault.
 *
 *      This replaces IActionAdapter with a clearer naming convention.
 *      The core interface is the same: execute(vault, params), canExecute(params),
 *      getTokenRequirements(params), validateParams(params).
 */
interface IStrategyAdapter {

    /**
     * @notice Execute the strategy for a given vault.
     * @param vault    The UserVault address (tokens are pulled from here via transferFrom)
     * @param params   ABI-encoded strategy-specific parameters
     * @return success Whether execution succeeded
     * @return result  Return data or error message
     */
    function execute(address vault, bytes calldata params)
        external returns (bool success, bytes memory result);

    /**
     * @notice Check if the strategy's conditions are met for execution.
     * @dev Called by ExecutorHub before triggering an automation.
     *      Each strategy embeds its own condition logic:
     *      - Time-based: "has 7 days passed since last execution?"
     *      - Price-based: "has ETH gone below $2000?"
     *      - State-based: "has the DCA run 10 times?"
     * @param params  ABI-encoded strategy-specific parameters
     * @return canExecute  Whether conditions are met
     * @return reason      Human-readable reason if conditions not met
     */
    // NOTE: include vault address so strategies can reason about per-vault state
    function canExecute(address vault, bytes calldata params)
        external view returns (bool canExecute, string memory reason);

    /**
     * @notice Get the ERC20 tokens and amounts this strategy needs.
     * @dev The vault uses this to approve the exact amount to the adapter.
     *      No over-approval — exact amounts only.
     * @param params  ABI-encoded strategy-specific parameters
     * @return tokens   Array of token addresses (address(0) = native ETH)
     * @return amounts  Array of amounts needed per token
     */
    function getTokenRequirements(bytes calldata params)
        external view returns (address[] memory tokens, uint256[] memory amounts);

    /**
     * @notice Validate that params are correctly encoded.
     * @dev Called by vault before creating an automation.
     *      Catch encoding errors early so automations don't fail on execution.
     * @param params  ABI-encoded strategy-specific parameters
     * @return valid   Whether params are valid
     * @return error   Human-readable error if invalid
     */
    function validateParams(bytes calldata params)
        external view returns (bool valid, string memory error);

    // ============ Events ============

    /// @notice Emitted when a strategy execution completes
    event ActionExecuted(address indexed vault, address indexed target, bool success, bytes data);
}