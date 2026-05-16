// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GameFactory}      from "../src/GameFactory.sol";
import {MineralToken}     from "../src/MineralToken.sol";
import {ResourceAMM}      from "../src/ResourceAMM.sol";
import {ItemVault}        from "../src/ItemVault.sol";
import {ERC1967Proxy}     from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        string  memory uri  = vm.envOr("ITEMS_URI", string("https://game.example.com/api/items/{id}.json"));

        // Chainlink price feed address on the target network (override via env)
        address priceFeed = vm.envOr("PRICE_FEED_ADDRESS", address(0));
        bytes32 salt      = keccak256("GameInstance.v1");

        vm.startBroadcast(deployerKey);

        // 1. Deploy GameFactory (deploys GameToken + GameItems implementations internally)
        GameFactory factory = new GameFactory(deployer);

        // 2. Deploy GameToken + GameItems proxies via factory
        (address tokenProxy, address itemsProxy) = factory.deployInstance(salt, deployer, uri);

        // 3. Deploy MineralToken (fungible resource for AMM)
        MineralToken mineral = new MineralToken(deployer);

        // 4. Deploy ResourceAMM (GAME <-> MINE with Chainlink staleness guard)
        //    Requires a valid Chainlink price feed; on testnets use a mock address.
        ResourceAMM amm = new ResourceAMM(tokenProxy, address(mineral), priceFeed, deployer);

        // 5. Deploy ItemVault (ERC-4626, accepts GAME tokens)
        address vaultImpl  = address(new ItemVault());
        bytes memory vaultInit = abi.encodeCall(ItemVault.initialize, (deployer, tokenProxy));
        address vaultProxy = address(new ERC1967Proxy(vaultImpl, vaultInit));

        vm.stopBroadcast();

        console2.log("=== Deployment Complete ===");
        console2.log("GameFactory:    ", address(factory));
        console2.log("GameToken proxy:", tokenProxy);
        console2.log("GameItems proxy:", itemsProxy);
        console2.log("MineralToken:   ", address(mineral));
        console2.log("ResourceAMM:    ", address(amm));
        console2.log("ItemVault proxy:", vaultProxy);
        console2.log("");
        console2.log("Next: run UpgradeItems.s.sol to upgrade GameItems to V2 and deploy LootBox");
    }
}
