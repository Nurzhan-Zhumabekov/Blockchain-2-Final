// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {RWAGovernor}         from "../src/RWAGovernor.sol";
import {RWATimelock}         from "../src/RWATimelock.sol";
import {GovernanceToken}     from "../src/GovernanceToken.sol";
import {TimelockController}  from "@openzeppelin/contracts/governance/TimelockController.sol";

// Governance deployment for the RWA Tokenization Platform (Participant 2).
// Deploys RWATimelock + RWAGovernor and wires them together.
//
// Required env vars:
//   DEPLOYER_PRIVATE_KEY   — deployer's private key
//   GOV_TOKEN_PROXY        — address of the GovernanceToken (RWAGOV) proxy from Deploy.s.sol
//
// Optional:
//   TIMELOCK_DELAY         — timelock min delay in seconds (default: 2 days)
contract DeployGovernance is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address govToken    = vm.envAddress("GOV_TOKEN_PROXY");
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(2 days));

        vm.startBroadcast(deployerKey);

        // 1. Deploy Timelock with no initial proposers/executors (will be set after governor)
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone can execute after delay passes

        RWATimelock timelock = new RWATimelock(
            timelockDelay,
            proposers,
            executors,
            deployer   // temporary admin — revoked below
        );

        // 2. Deploy Governor
        RWAGovernor governor = new RWAGovernor(
            GovernanceToken(govToken),
            TimelockController(payable(address(timelock)))
        );

        // 3. Wire governor as the sole proposer + canceller on the timelock
        timelock.grantRole(timelock.PROPOSER_ROLE(),  address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // 4. Revoke deployer's admin role — timelock is now self-governed
        timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console2.log("=== RWA Governance Deployment Complete ===");
        console2.log("RWATimelock:  ", address(timelock));
        console2.log("RWAGovernor:  ", address(governor));
        console2.log("Voting token: ", govToken);
        console2.log("Timelock delay (s):", timelockDelay);
        console2.log("");
        console2.log("Next: grant Timelock UPGRADER_ROLE on RWAToken/RWAVault/GovernanceToken proxies");
    }
}
