// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockStorkOracle
 * @notice Chainlink AggregatorV3-compatible mock oracle for Arc testnet testing
 * @dev Simulates Stork price feeds using the Chainlink latestRoundData() interface
 *      Real Stork feeds on Arc use the same interface, just swap the address
 */
contract MockStorkOracle {
    string public description;
    uint8 public decimals;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    address public owner;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    constructor(string memory _description, uint8 _decimals, int256 initialPrice) {
        description = _description;
        decimals = _decimals;
        owner = msg.sender;
        _updateAnswer(initialPrice);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /**
     * @notice Update the price (owner only)
     * @param newAnswer New price value
     */
    function updateAnswer(int256 newAnswer) external onlyOwner {
        _updateAnswer(newAnswer);
    }

    function _updateAnswer(int256 newAnswer) internal {
        _roundId++;
        _answer = newAnswer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
        emit AnswerUpdated(newAnswer, _roundId, block.timestamp);
    }

    /**
     * @notice Chainlink-compatible latestRoundData
     * @return roundId Current round ID
     * @return answer Current price
     * @return startedAt Round start timestamp
     * @return updatedAt Last update timestamp
     * @return answeredInRound Round in which answer was computed
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function latestRound() external view returns (uint256) {
        return _roundId;
    }
}
