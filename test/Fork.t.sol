// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}      from "forge-std/Test.sol";
import {GovernanceToken}     from "../src/GovernanceToken.sol";
import {RWAToken}            from "../src/RWAToken.sol";
import {RWATokenV2}          from "../src/RWATokenV2.sol";
import {RWAVault}            from "../src/RWAVault.sol";
import {RWAFactory}          from "../src/RWAFactory.sol";
import {RWAPool}             from "../src/RWAPool.sol";
import {RWAStaking}          from "../src/RWAStaking.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ERC1967Proxy}        from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable}     from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Fork tests against Arbitrum Sepolia.
// Requires ARBITRUM_SEPOLIA_RPC_URL in environment.
// Run with: forge test --match-contract ForkTest --fork-url $ARBITRUM_SEPOLIA_RPC_URL -vvv
//
// Chainlink Arbitrum Sepolia feeds (data as of deployment time):
//   ETH/USD : 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165
//   BTC/USD : 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69
//   LINK/USD: 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298
contract ForkTest is Test {
    // ── Chainlink feed addresses on Arbitrum Sepolia ──────────────────────────
    address constant ETH_USD_FEED  = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    address constant BTC_USD_FEED  = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69;

    GovernanceToken gov;
    RWAFactory      factory;
    RWAPool         pool;
    RWAStaking      staking;

    address deployer = address(0xDEF1);
    address issuer   = address(0xDEF2);
    address alice    = address(0xDEF3);

    bytes32 constant ISSUER_ROLE  = keccak256("ISSUER_ROLE");
    bytes32 constant MINTER_ROLE  = keccak256("MINTER_ROLE");
    bytes32 constant ONBOARDER_ROLE = keccak256("ONBOARDER_ROLE");

    uint256 forkId;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true); // Skip if no RPC URL provided
            return;
        }
        forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        vm.deal(deployer, 10 ether);
        vm.deal(issuer,   10 ether);
        vm.deal(alice,    10 ether);

        vm.startPrank(deployer);

        // 1. Deploy GovernanceToken
        GovernanceToken govImpl = new GovernanceToken();
        gov = GovernanceToken(address(new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(GovernanceToken.initialize, (deployer))
        )));

        // 2. Deploy RWAFactory (creates RWAToken + RWAVault impls + AssetCertificate)
        factory = new RWAFactory(deployer);

        // 3. Onboard a US Treasury Bond token with real ETH/USD feed as price reference
        bytes32 salt = keccak256("fork.test.v1");
        (address tokenProxy, address vaultProxy) = factory.onboardAsset(
            salt,
            issuer,
            "US Treasury Bond Token",
            "USTB",
            "US-TREASURY-BOND",
            ETH_USD_FEED
        );

        // 4. Deploy RWAPool
        pool = new RWAPool(address(gov), tokenProxy, ETH_USD_FEED, deployer);

        // 5. Deploy RWAStaking
        staking = new RWAStaking(address(gov), tokenProxy, deployer, 7 days);

        vm.stopPrank();
    }

    // ── Chainlink feed sanity checks ─────────────────────────────────────────

    function test_Fork_ChainlinkFeed_ReturnsPositivePrice() public {
        AggregatorV3Interface feed = AggregatorV3Interface(ETH_USD_FEED);
        (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();
        assertGt(price, 0);
        assertGt(updatedAt, 0);
        // Price should not be stale (< 1 hour old relative to fork block)
        assertLt(block.timestamp - updatedAt, 1 hours);
        console2.log("ETH/USD price:", uint256(price));
    }

    function test_Fork_ChainlinkFeed_BTC_ReturnsPositivePrice() public {
        AggregatorV3Interface feed = AggregatorV3Interface(BTC_USD_FEED);
        (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();
        assertGt(price, 0);
        console2.log("BTC/USD price:", uint256(price));
    }

    // ── Full deployment smoke test ────────────────────────────────────────────

    function test_Fork_Deployment_FactoryHasImpls() public view {
        assertTrue(factory.tokenImpl() != address(0));
        assertTrue(factory.vaultImpl() != address(0));
        assertTrue(address(factory.certificate()) != address(0));
    }

    function test_Fork_Deployment_PoolHasCorrectTokens() public view {
        assertEq(address(pool.token0()), address(gov));
    }

    // ── RWAToken: issue + staleness check with real feed ─────────────────────

    function test_Fork_RWAToken_IssueWithFreshFeed() public {
        bytes32 salt  = keccak256("fork.test.issue.v1");
        vm.startPrank(deployer);
        (address tokenProxy, ) = factory.onboardAsset(
            salt,
            issuer,
            "Fork Bond",
            "FBOND",
            "US-TREASURY-BOND",
            ETH_USD_FEED
        );
        vm.stopPrank();

        RWAToken token = RWAToken(tokenProxy);

        vm.prank(issuer);
        token.issue(alice, 1_000 ether);
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    function test_Fork_RWAToken_StalenessFails_WhenTimeAdvanced() public {
        bytes32 salt = keccak256("fork.test.stale.v1");
        vm.startPrank(deployer);
        (address tokenProxy, ) = factory.onboardAsset(
            salt,
            issuer,
            "Stale Bond",
            "SBOND",
            "US-TREASURY-BOND",
            ETH_USD_FEED
        );
        vm.stopPrank();

        RWAToken token = RWAToken(tokenProxy);

        // Advance time by 25 hours — feed becomes stale
        vm.warp(block.timestamp + 25 hours);

        vm.prank(issuer);
        vm.expectRevert();
        token.issue(alice, 1_000 ether);
    }

    // ── AMM: addLiquidity + swap with real Chainlink staleness check ──────────

    function test_Fork_Pool_AddLiquidityAndSwap() public {
        // Mint tokens to alice
        vm.prank(deployer);
        gov.mint(alice, 100_000 ether);

        bytes32 salt = keccak256("fork.pool.v1");
        vm.prank(deployer);
        (address tokenProxy, ) = factory.onboardAsset(
            salt,
            alice,
            "Pool Bond",
            "PBOND",
            "US-TREASURY-BOND",
            ETH_USD_FEED
        );

        RWAToken rwa = RWAToken(tokenProxy);
        vm.startPrank(alice);
        rwa.grantRole(ISSUER_ROLE, alice);
        rwa.issue(alice, 100_000 ether);
        vm.stopPrank();

        RWAPool localPool = new RWAPool(address(gov), tokenProxy, ETH_USD_FEED, deployer);

        vm.startPrank(alice);
        gov.approve(address(localPool), type(uint256).max);
        rwa.approve(address(localPool), type(uint256).max);
        uint256 shares = localPool.addLiquidity(50_000 ether, 50_000 ether, 0, 0);
        assertGt(shares, 0);

        uint256 out = localPool.swap(address(gov), 1_000 ether, 0);
        assertGt(out, 0);
        console2.log("Swap output (RWAToken):", out);
        vm.stopPrank();
    }

    // ── V1 → V2 upgrade with Chainlink Proof-of-Reserve feed ─────────────────

    function test_Fork_UpgradeToV2_ProofOfReserve() public {
        bytes32 salt = keccak256("fork.upgrade.v1");
        vm.prank(deployer);
        (address tokenProxy, ) = factory.onboardAsset(
            salt,
            issuer,
            "Upgrade Bond",
            "UBOND",
            "US-TREASURY-BOND",
            ETH_USD_FEED
        );

        RWAToken token = RWAToken(tokenProxy);

        // Issue before upgrade
        vm.prank(issuer);
        token.issue(alice, 500 ether);
        assertEq(token.totalSupply(), 500 ether);

        // Upgrade to V2 using BTC/USD feed as the PoR feed (reused for test)
        RWATokenV2 v2Impl = new RWATokenV2();
        bytes memory initData = abi.encodeCall(RWATokenV2.initializeV2, (BTC_USD_FEED));

        vm.prank(issuer);
        UUPSUpgradeable(tokenProxy).upgradeToAndCall(address(v2Impl), initData);

        RWATokenV2 v2 = RWATokenV2(tokenProxy);
        assertEq(address(v2.reserveFeed()), BTC_USD_FEED);

        // The BTC/USD feed reports a price orders of magnitude larger than totalSupply (500 ether)
        // so issue should succeed
        vm.prank(issuer);
        v2.issue(alice, 100 ether);
        assertEq(v2.balanceOf(alice), 600 ether);
    }

    // ── RWAStaking: stake + earn + claim on fork ──────────────────────────────

    function test_Fork_Staking_StakeAndEarn() public {
        bytes32 salt = keccak256("fork.staking.v1");
        vm.prank(deployer);
        (address tokenProxy, ) = factory.onboardAsset(
            salt,
            deployer,
            "Stake Bond",
            "SKBOND",
            "US-TREASURY-BOND",
            ETH_USD_FEED
        );

        RWAToken rwaLocal = RWAToken(tokenProxy);

        RWAStaking localStaking = new RWAStaking(address(gov), tokenProxy, deployer, 7 days);

        // Fund staking contract with rewards
        vm.startPrank(deployer);
        rwaLocal.grantRole(ISSUER_ROLE, deployer);
        rwaLocal.issue(address(localStaking), 70_000 ether);
        localStaking.notifyRewardAmount(70_000 ether);
        gov.mint(alice, 5_000 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        gov.approve(address(localStaking), type(uint256).max);
        localStaking.stake(1_000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        uint256 earned = localStaking.earned(alice);
        assertGt(earned, 0);
        console2.log("Earned after 1 day:", earned);
    }
}
