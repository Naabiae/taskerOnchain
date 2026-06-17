// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockTokenMessenger
 * @notice Mock implementation of Circle CCTP TokenMessenger for Arc testnet testing
 * @dev Simulates CCTP depositForBurn without actual cross-chain bridging
 */
contract MockTokenMessenger {
    uint64 private _nonce;

    event DepositForBurn(
        uint64 indexed nonce,
        address indexed burnToken,
        uint256 amount,
        address indexed depositor,
        bytes32 mintRecipient,
        uint32 destinationDomain,
        bytes32 destinationTokenMessenger,
        bytes32 destinationCaller
    );

    /**
     * @notice Mock CCTP depositForBurn - emits event and returns nonce
     * @param amount Amount to burn/bridge
     * @param destinationDomain Destination chain domain
     * @param mintRecipient Recipient on destination chain (bytes32 padded)
     * @param burnToken Token to burn
     * @return nonce Unique nonce for this burn
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce) {
        nonce = _nonce++;

        // Pull tokens from caller (adapter has already approved)
        // In real CCTP, the token would be burned
        // For testing, we just emit the event
        emit DepositForBurn(
            nonce,
            burnToken,
            amount,
            msg.sender,
            mintRecipient,
            destinationDomain,
            bytes32(0),
            bytes32(0)
        );

        return nonce;
    }

    function getNonce() external view returns (uint64) {
        return _nonce;
    }
}
