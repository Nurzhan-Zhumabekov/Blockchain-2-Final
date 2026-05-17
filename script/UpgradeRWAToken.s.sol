// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}  from "forge-std/Script.sol";
import {RWATokenV2}        from "../src/RWATokenV2.sol";
import {UUPSUpgradeable}   from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// V1 → V2 Upgrade Script — adds Chainlink Proof-of-Reserve enforcement to an existing RWAToken proxy.
//
// Required env vars:
//   DEPLOYER_PRIVATE_KEY   — must hold UPGRADER_ROLE on the proxy
//   RWA_TOKEN_PROXY        — address of the deployed RWAToken proxy
//   RESERVE_FEED_ADDRESS   — Chainlink Proof-of-Reserve feed address for this asset
contract UpgradeRWAToken is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenProxy  = vm.envAddress("RWA_TOKEN_PROXY");
        address reserveFeed = vm.envAddress("RESERVE_FEED_ADDRESS");

        vm.startBroadcast(deployerKey);

        // 1. Deploy V2 implementation
        RWATokenV2 v2Impl = new RWATokenV2();

        // 2. Upgrade proxy to V2 and call initializeV2() atomically.
        //    reinitializer(2) ensures this runs exactly once and cannot be replayed.
        bytes memory initData = abi.encodeCall(RWATokenV2.initializeV2, (reserveFeed));
        UUPSUpgradeable(tokenProxy).upgradeToAndCall(address(v2Impl), initData);

        vm.stopBroadcast();

        console2.log("=== RWAToken V1 to V2 Upgrade Complete ===");
        console2.log("RWATokenV2 (impl): ", address(v2Impl));
        console2.log("RWAToken (proxy):  ", tokenProxy);
        console2.log("Reserve feed:      ", reserveFeed);
        console2.log("All subsequent issue() calls now enforce Proof-of-Reserve.");
    }
}
