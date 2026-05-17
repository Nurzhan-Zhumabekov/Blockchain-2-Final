// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}  from "forge-std/Script.sol";
import {RWAStaking}        from "../src/RWAStaking.sol";
import {RWAToken}          from "../src/RWAToken.sol";
import {GovernanceToken}   from "../src/GovernanceToken.sol";

// Staking deployment for the RWA Tokenization Platform (Participant 3).
// Deploys RWAStaking where RWAGOV stakers earn RWAToken rewards.
//
// Required env vars:
//   DEPLOYER_PRIVATE_KEY   — deployer's private key
//   GOV_TOKEN_PROXY        — GovernanceToken proxy (staking token)
//   RWA_TOKEN_PROXY        — RWAToken proxy (reward token)
//
// Optional:
//   STAKING_DURATION       — reward period in seconds (default: 7 days)
//   INITIAL_REWARD         — initial reward amount in wei (default: 0, DAO deposits later)
contract DeployStaking is Script {
    function run() external {
        uint256 deployerKey   = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer      = vm.addr(deployerKey);
        address govToken      = vm.envAddress("GOV_TOKEN_PROXY");
        address rwaToken      = vm.envAddress("RWA_TOKEN_PROXY");
        uint256 duration      = vm.envOr("STAKING_DURATION", uint256(7 days));

        vm.startBroadcast(deployerKey);

        RWAStaking staking = new RWAStaking(
            govToken,
            rwaToken,
            deployer,
            duration
        );

        vm.stopBroadcast();

        console2.log("=== RWA Staking Deployment Complete ===");
        console2.log("RWAStaking:       ", address(staking));
        console2.log("Staking token:    ", govToken);
        console2.log("Reward token:     ", rwaToken);
        console2.log("Reward duration:  ", duration);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. DAO mints/sends reward tokens to staking contract");
        console2.log("  2. REWARDS_MANAGER calls notifyRewardAmount(amount)");
        console2.log("  3. RWAGOV holders can stake() and earn RWAToken rewards");
    }
}
