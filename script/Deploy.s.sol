// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}  from "forge-std/Script.sol";
import {GovernanceToken}   from "../src/GovernanceToken.sol";
import {RWAFactory}        from "../src/RWAFactory.sol";
import {RWAPool}           from "../src/RWAPool.sol";
import {ERC1967Proxy}      from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Full deployment for the RWA Tokenization Platform (Option C).
//
// Required env vars:
//   DEPLOYER_PRIVATE_KEY   — deployer's private key
//
// Optional env vars (have sane defaults for testnet):
//   PRICE_FEED_ADDRESS     — Chainlink price feed; address(0) disables staleness check
//   ASSET_NAME             — name for the first RWA token  (default: "US Treasury Bond Token")
//   ASSET_SYMBOL           — symbol                        (default: "USTB")
//   ASSET_TYPE             — human-readable asset class    (default: "US-TREASURY-BOND")
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        address priceFeed  = vm.envOr("PRICE_FEED_ADDRESS",  address(0));
        string memory name_   = vm.envOr("ASSET_NAME",   string("US Treasury Bond Token"));
        string memory symbol_ = vm.envOr("ASSET_SYMBOL", string("USTB"));
        string memory type_   = vm.envOr("ASSET_TYPE",   string("US-TREASURY-BOND"));
        bytes32 salt          = keccak256("RWAInstance.v1");

        vm.startBroadcast(deployerKey);

        // 1. Deploy GovernanceToken implementation + UUPS proxy
        address govImpl = address(new GovernanceToken());
        bytes memory govInit = abi.encodeCall(GovernanceToken.initialize, (deployer));
        address govProxy = address(new ERC1967Proxy(govImpl, govInit));

        // 2. Deploy RWAFactory
        //    Constructor deploys RWAToken impl, RWAVault impl, and AssetCertificate (all via CREATE).
        RWAFactory factory = new RWAFactory(deployer);

        // 3. Onboard the first real-world asset
        //    Deploys RWAToken proxy + RWAVault proxy (both via CREATE2) and mints a certificate NFT.
        (address tokenProxy, address vaultProxy) = factory.onboardAsset(
            salt,
            deployer,
            name_,
            symbol_,
            type_,
            priceFeed
        );

        // 4. Deploy RWAPool (RWAGOV <-> RWAToken AMM)
        RWAPool pool = new RWAPool(govProxy, tokenProxy, priceFeed, deployer);

        // 5. Mint initial governance tokens to deployer for DAO bootstrapping
        GovernanceToken(govProxy).mint(deployer, 10_000_000 ether);

        vm.stopBroadcast();

        console2.log("=== RWA Platform Deployment Complete ===");
        console2.log("GovernanceToken (proxy):", govProxy);
        console2.log("GovernanceToken (impl): ", govImpl);
        console2.log("RWAFactory:             ", address(factory));
        console2.log("AssetCertificate:       ", address(factory.certificate()));
        console2.log("RWAToken (proxy):       ", tokenProxy);
        console2.log("RWAVault (proxy):       ", vaultProxy);
        console2.log("RWAPool:                ", address(pool));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Deploy Governor + Timelock (Participant 2)");
        console2.log("  2. Run UpgradeRWAToken.s.sol to add Proof-of-Reserve (V2 upgrade)");
    }
}
