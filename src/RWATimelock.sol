// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

// Thin wrapper around OZ TimelockController.
// Queues and executes governance proposals with a mandatory delay.
// Proposers = Governor contract; Executors = address(0) (anyone can execute after delay).
contract RWATimelock is TimelockController {
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}
