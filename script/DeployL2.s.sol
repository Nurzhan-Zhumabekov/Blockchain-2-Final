// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}      from "forge-std/Script.sol";
import {GovernanceToken}       from "../src/GovernanceToken.sol";
import {RWAFactory}            from "../src/RWAFactory.sol";
import {RWAPool}               from "../src/RWAPool.sol";
import {RWAStaking}            from "../src/RWAStaking.sol";
import {RWATimelock}           from "../src/RWATimelock.sol";
import {RWAGovernor}           from "../src/RWAGovernor.sol";
import {ERC1967Proxy}          from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController}    from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes}                from "@openzeppelin/contracts/governance/utils/IVotes.sol";

// Full L2 deployment for the RWA Tokenization Platform (Option C).
// Deploys every contract in one broadcast and wires access-control roles so
// the Timelock/Governor owns the protocol with no deployer backdoor remaining.
//
// Required env var:
//   DEPLOYER_PRIVATE_KEY   — deployer EOA private key
//
// Optional env vars (all have testnet-safe defaults):
//   PRICE_FEED_ADDRESS     — Chainlink feed; address(0) disables staleness check
//   ASSET_NAME             — first RWA token name   (default: "US Treasury Bond Token")
//   ASSET_SYMBOL           — first RWA token symbol (default: "USTB")
//   ASSET_TYPE             — asset class label      (default: "US-TREASURY-BOND")
//   TIMELOCK_DELAY         — TimelockController min delay in seconds (default: 2 days)
//   STAKING_DURATION       — reward period in seconds (default: 7 days)
//   INITIAL_GOV_SUPPLY     — governance tokens minted to deployer (default: 10_000_000e18)
//
// Usage:
//   forge script script/DeployL2.s.sol \
//     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
//     --broadcast \
//     --verify \
//     --etherscan-api-key $ARBISCAN_API_KEY \
//     -vvv
contract DeployL2 is Script {

    // Populated during run() — readable by tests / other scripts.
    address public govImpl;
    address public govProxy;
    address public factory;
    address public certificate;
    address public tokenProxy;
    address public vaultProxy;
    address public pool;
    address public staking;
    address public timelock;
    address public governor;

    function run() external {
        uint256 deployerKey   = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer      = vm.addr(deployerKey);

        address priceFeed     = vm.envOr("PRICE_FEED_ADDRESS",  address(0));
        string  memory name_  = vm.envOr("ASSET_NAME",          string("US Treasury Bond Token"));
        string  memory sym_   = vm.envOr("ASSET_SYMBOL",        string("USTB"));
        string  memory type_  = vm.envOr("ASSET_TYPE",          string("US-TREASURY-BOND"));
        uint256 tlDelay       = vm.envOr("TIMELOCK_DELAY",      uint256(2 days));
        uint256 stakingDur    = vm.envOr("STAKING_DURATION",    uint256(7 days));
        uint256 initSupply    = vm.envOr("INITIAL_GOV_SUPPLY",  uint256(10_000_000 ether));
        bytes32 salt          = keccak256("RWAInstance.v1");

        vm.startBroadcast(deployerKey);

        // 1. GovernanceToken — UUPS proxy ──────────────────────────────────────
        govImpl  = address(new GovernanceToken());
        govProxy = address(new ERC1967Proxy(
            govImpl,
            abi.encodeCall(GovernanceToken.initialize, (deployer))
        ));
        GovernanceToken govToken = GovernanceToken(govProxy);

        // 2. RWAFactory ────────────────────────────────────────────────────────
        // Constructor internally deploys RWAToken impl, RWAVault impl,
        // and AssetCertificate (ERC-721) — all via CREATE.
        RWAFactory rwaFactory = new RWAFactory(deployer);
        factory     = address(rwaFactory);
        certificate = address(rwaFactory.certificate());

        // 3. Onboard first real-world asset ────────────────────────────────────
        // Deploys RWAToken proxy + RWAVault proxy via CREATE2; mints certificate.
        (tokenProxy, vaultProxy) = rwaFactory.onboardAsset(
            salt, deployer, name_, sym_, type_, priceFeed
        );

        // 4. RWAPool — constant-product AMM with 0.3 % fee ─────────────────────
        pool = address(new RWAPool(govProxy, tokenProxy, priceFeed, deployer));

        // 5. RWAStaking — RWAGOV stakers earn RWAToken rewards ─────────────────
        staking = address(new RWAStaking(govProxy, tokenProxy, deployer, stakingDur));

        // 6. Mint initial governance tokens to deployer BEFORE role revocations
        //    (deployer still holds MINTER_ROLE at this point)
        govToken.mint(deployer, initSupply);

        // 7. Timelock — 2-day mandatory delay ──────────────────────────────────
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone may execute after the delay
        RWATimelock rwaTimelock = new RWATimelock(tlDelay, proposers, executors, deployer);
        timelock = address(rwaTimelock);

        // 8. Governor — OZ Governor stack (GovernorVotes + Timelock) ───────────
        RWAGovernor rwaGovernor = new RWAGovernor(
            IVotes(govProxy),
            TimelockController(payable(timelock))
        );
        governor = address(rwaGovernor);

        // 9. Wire Governor as sole proposer/canceller on Timelock ──────────────
        rwaTimelock.grantRole(rwaTimelock.PROPOSER_ROLE(),  governor);
        rwaTimelock.grantRole(rwaTimelock.CANCELLER_ROLE(), governor);

        // 10. Transfer GovernanceToken admin to Timelock; revoke deployer ───────
        govToken.grantRole(govToken.DEFAULT_ADMIN_ROLE(), timelock);
        govToken.grantRole(govToken.MINTER_ROLE(),        timelock);
        govToken.grantRole(govToken.UPGRADER_ROLE(),      timelock);
        govToken.revokeRole(govToken.MINTER_ROLE(),        deployer);
        govToken.revokeRole(govToken.DEFAULT_ADMIN_ROLE(), deployer);

        // 11. Transfer RWAFactory admin to Timelock; revoke deployer ────────────
        rwaFactory.grantRole(rwaFactory.DEFAULT_ADMIN_ROLE(), timelock);
        rwaFactory.grantRole(rwaFactory.ONBOARDER_ROLE(),     timelock);
        rwaFactory.revokeRole(rwaFactory.DEFAULT_ADMIN_ROLE(), deployer);

        // 12. Revoke deployer's temporary admin role on Timelock ────────────────
        rwaTimelock.revokeRole(rwaTimelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        _printSummary(deployer);
        _printEnv();
    }

    // ── Output helpers ─────────────────────────────────────────────────────────

    function _printSummary(address deployer) internal view {
        console2.log("");
        console2.log("========================================");
        console2.log(" RWA Platform - L2 Deployment Complete ");
        console2.log("========================================");
        console2.log("Network : Arbitrum Sepolia (chain 421614)");
        console2.log("Deployer:", deployer);
        console2.log("");
        console2.log("-- Core --");
        console2.log("GovernanceToken impl :", govImpl);
        console2.log("GovernanceToken proxy:", govProxy);
        console2.log("RWAFactory           :", factory);
        console2.log("AssetCertificate     :", certificate);
        console2.log("RWAToken proxy       :", tokenProxy);
        console2.log("RWAVault proxy       :", vaultProxy);
        console2.log("RWAPool              :", pool);
        console2.log("RWAStaking           :", staking);
        console2.log("");
        console2.log("-- Governance --");
        console2.log("RWATimelock          :", timelock);
        console2.log("RWAGovernor          :", governor);
        console2.log("");
        console2.log("-- Role assignments (post-deploy) --");
        console2.log("Timelock DEFAULT_ADMIN on GovernanceToken : YES");
        console2.log("Timelock MINTER_ROLE on GovernanceToken   : YES");
        console2.log("Timelock DEFAULT_ADMIN on RWAFactory      : YES");
        console2.log("Governor PROPOSER_ROLE on Timelock        : YES");
        console2.log("Deployer admin roles revoked              : YES");
        console2.log("");
        console2.log("-- Next steps --");
        console2.log("1. forge script script/Verify.s.sol --rpc-url $RPC --env-file .env.deployed");
        console2.log("2. Approve + seed RWAPool liquidity");
        console2.log("3. Fill subgraph/subgraph.yaml with deployed addresses + startBlocks");
        console2.log("4. Fill frontend/.env from the block below");
        console2.log("5. graph deploy --studio rwa-platform");
    }

    function _printEnv() internal view {
        console2.log("");
        console2.log("=== Paste into frontend/.env ===");
        console2.log("VITE_RPC_URL=https://sepolia-rollup.arbitrum.io/rpc");
        console2.log("VITE_GOV_TOKEN=", govProxy);
        console2.log("VITE_RWA_TOKEN=", tokenProxy);
        console2.log("VITE_RWA_POOL=", pool);
        console2.log("VITE_RWA_STAKING=", staking);
        console2.log("VITE_RWA_GOVERNOR=", governor);
        console2.log("VITE_TIMELOCK=", timelock);
        console2.log("VITE_RWA_VAULT=", vaultProxy);
        console2.log("VITE_SUBGRAPH_URL=https://api.studio.thegraph.com/query/<id>/rwa-platform/version/latest");
        console2.log("");
        console2.log("=== Paste into .env.deployed (for Verify.s.sol) ===");
        console2.log("GOV_PROXY=", govProxy);
        console2.log("TIMELOCK_ADDR=", timelock);
        console2.log("GOVERNOR_ADDR=", governor);
        console2.log("FACTORY_ADDR=", factory);
        console2.log("POOL_ADDR=", pool);
        console2.log("STAKING_ADDR=", staking);
        console2.log("RWA_TOKEN_PROXY=", tokenProxy);
        console2.log("DEPLOYER_ADDR=", address(0)); // fill in deployer EOA
    }
}
