// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GameItemsV2}      from "../src/GameItemsV2.sol";
import {LootBox}          from "../src/LootBox.sol";
import {UUPSUpgradeable}  from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// V1 -> V2 Upgrade Script
// Run after Deploy.s.sol. Requires:
//   ITEMS_PROXY_ADDRESS   — address of the deployed GameItems proxy
//   VRF_COORDINATOR       — Chainlink VRF Coordinator address on target network
//   VRF_KEY_HASH          — Chainlink key hash for the target network
//   VRF_SUBSCRIPTION_ID   — your funded VRF subscription ID
//   GAME_TOKEN_ADDRESS    — GameToken proxy address
//   LOOT_PRICE            — price in GAME tokens per loot pull (wei)
contract UpgradeItems is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        address itemsProxy     = vm.envAddress("ITEMS_PROXY_ADDRESS");
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        bytes32 vrfKeyHash     = vm.envBytes32("VRF_KEY_HASH");
        uint64  vrfSubId       = uint64(vm.envUint("VRF_SUBSCRIPTION_ID"));
        uint32  callbackGas    = uint32(vm.envOr("VRF_CALLBACK_GAS", uint256(200_000)));
        address gameToken      = vm.envAddress("GAME_TOKEN_ADDRESS");
        uint256 lootPrice      = vm.envOr("LOOT_PRICE", uint256(10 ether));

        vm.startBroadcast(deployerKey);

        // 1. Deploy V2 implementation
        GameItemsV2 v2Impl = new GameItemsV2();

        // 2. Deploy LootBox first (itemsProxy already exists from Deploy.s.sol)
        LootBox lootBox = new LootBox(
            vrfCoordinator,
            itemsProxy,
            gameToken,
            vrfKeyHash,
            vrfSubId,
            callbackGas,
            lootPrice,
            deployer
        );

        // 3. Upgrade proxy to V2 and initialize with real LootBox address in one call
        //    reinitializer(2) runs exactly once here — no double-call issue
        bytes memory initData = abi.encodeCall(GameItemsV2.initializeV2, (address(lootBox)));
        UUPSUpgradeable(itemsProxy).upgradeToAndCall(address(v2Impl), initData);

        vm.stopBroadcast();

        console2.log("=== Upgrade Complete ===");
        console2.log("GameItemsV2 impl:", address(v2Impl));
        console2.log("LootBox:         ", address(lootBox));
        console2.log("Items proxy V2:  ", itemsProxy);
    }
}
