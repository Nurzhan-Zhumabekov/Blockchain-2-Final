// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

contract MockFeed is AggregatorV3Interface {
    int256  public answer;
    uint256 public updatedAt;
    uint8   public decimals_ = 18;

    constructor(int256 _answer) {
        answer    = _answer;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 _answer) external { answer = _answer; }
    function setUpdatedAt(uint256 _updatedAt) external { updatedAt = _updatedAt; }
    function decimals() external view returns (uint8) { return decimals_; }
    function description() external pure returns (string memory) { return "Mock"; }
    function version() external pure returns (uint256) { return 1; }

    function getRoundData(uint80) external view returns (
        uint80 roundId, int256 ans, uint256 startedAt, uint256 upAt, uint80 answeredInRound
    ) { return (1, answer, block.timestamp, updatedAt, 1); }

    function latestRoundData() external view returns (
        uint80 roundId, int256 ans, uint256 startedAt, uint256 upAt, uint80 answeredInRound
    ) { return (1, answer, block.timestamp, updatedAt, 1); }
}
