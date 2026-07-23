// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";

contract MockAggregator is IAggregatorV3 {
    uint8 public immutable override decimals;
    string public override description;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    constructor(uint8 decimals_, string memory description_, int256 answer_) {
        decimals = decimals_;
        description = description_;
        setAnswer(answer_);
    }

    function setAnswer(int256 answer_) public {
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        roundId++;
        answeredInRound = roundId;
    }

    function setRound(int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId++;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
