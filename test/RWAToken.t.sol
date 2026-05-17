// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}   from "forge-std/Test.sol";
import {RWAToken}         from "../src/RWAToken.sol";
import {RWATokenV2}       from "../src/RWATokenV2.sol";
import {ERC1967Proxy}     from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable}  from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MockFeed}         from "./MockFeed.sol";

contract RWATokenTest is Test {
    RWAToken  token;
    MockFeed  feed;
    address   admin   = address(0xA1);
    address   issuer  = address(0xA2);
    address   pauser  = address(0xA3);
    address   user    = address(0xA4);

    bytes32 constant ISSUER_ROLE  = keccak256("ISSUER_ROLE");
    bytes32 constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    function setUp() public {
        feed = new MockFeed(1e8); // $1.00

        RWAToken impl = new RWAToken();
        bytes memory init = abi.encodeCall(
            RWAToken.initialize,
            (admin, "US Treasury Bond Token", "USTB", "US-TREASURY-BOND", address(feed))
        );
        token = RWAToken(address(new ERC1967Proxy(address(impl), init)));

        vm.prank(admin);
        token.grantRole(ISSUER_ROLE, issuer);
        vm.prank(admin);
        token.grantRole(PAUSER_ROLE, pauser);
    }

    // --- Initialization ---

    function test_Initialize_Name() public view {
        assertEq(token.name(), "US Treasury Bond Token");
    }

    function test_Initialize_Symbol() public view {
        assertEq(token.symbol(), "USTB");
    }

    function test_Initialize_AssetType() public view {
        assertEq(token.assetType(), "US-TREASURY-BOND");
    }

    function test_Initialize_AdminHasDefaultAdminRole() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    // --- issue() ---

    function test_Issue_MintsTokens() public {
        vm.prank(issuer);
        token.issue(user, 1000 ether);
        assertEq(token.balanceOf(user), 1000 ether);
    }

    function test_Issue_EmitsEvent() public {
        vm.prank(issuer);
        vm.expectEmit(true, true, false, true, address(token));
        emit RWAToken.Issued(issuer, user, 500 ether);
        token.issue(user, 500 ether);
    }

    function test_Issue_RevertsIfNotIssuer() public {
        vm.prank(user);
        vm.expectRevert();
        token.issue(user, 100 ether);
    }

    function test_Issue_RevertsIfZeroAmount() public {
        vm.prank(issuer);
        vm.expectRevert(RWAToken.ZeroAmount.selector);
        token.issue(user, 0);
    }

    function test_Issue_RevertsIfZeroAddress() public {
        vm.prank(issuer);
        vm.expectRevert(RWAToken.ZeroAddress.selector);
        token.issue(address(0), 100 ether);
    }

    function test_Issue_RevertsWhenPaused() public {
        vm.prank(pauser);
        token.pause();
        vm.prank(issuer);
        vm.expectRevert();
        token.issue(user, 100 ether);
    }

    function test_Issue_RevertsOnStalePrice() public {
        vm.warp(block.timestamp + 48 hours); // ensure we have headroom to go stale
        feed.setUpdatedAt(block.timestamp - 25 hours);
        vm.prank(issuer);
        vm.expectRevert();
        token.issue(user, 100 ether);
    }

    // --- redeem() ---

    function test_Redeem_BurnsTokens() public {
        vm.prank(issuer);
        token.issue(user, 1000 ether);
        vm.prank(user);
        token.redeem(300 ether);
        assertEq(token.balanceOf(user), 700 ether);
    }

    function test_Redeem_EmitsEvent() public {
        vm.prank(issuer);
        token.issue(user, 500 ether);
        vm.prank(user);
        vm.expectEmit(true, false, false, true, address(token));
        emit RWAToken.Redeemed(user, 200 ether);
        token.redeem(200 ether);
    }

    function test_Redeem_RevertsIfZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(RWAToken.ZeroAmount.selector);
        token.redeem(0);
    }

    // --- updateCollateral() ---

    function test_UpdateCollateral_SetsValue() public {
        vm.prank(issuer);
        token.updateCollateral(999 ether);
        assertEq(token.totalCollateral(), 999 ether);
    }

    function test_UpdateCollateral_RevertsIfNotIssuer() public {
        vm.prank(user);
        vm.expectRevert();
        token.updateCollateral(100 ether);
    }

    // --- setPriceFeed() ---

    function test_SetPriceFeed_UpdatesFeed() public {
        MockFeed newFeed = new MockFeed(2e8);
        vm.prank(admin);
        token.setPriceFeed(address(newFeed));
        assertEq(address(token.priceFeed()), address(newFeed));
    }

    function test_SetPriceFeed_RevertsIfNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        token.setPriceFeed(address(0xDEAD));
    }

    // --- Pause / Unpause ---

    function test_Pause_BlocksIssue() public {
        vm.prank(pauser);
        token.pause();
        assertTrue(token.paused());
    }

    function test_Unpause_AllowsIssue() public {
        vm.prank(pauser);
        token.pause();
        vm.prank(pauser);
        token.unpause();
        assertFalse(token.paused());
    }

    // --- UUPS Upgrade to V2 ---

    function test_UpgradeToV2_Works() public {
        MockFeed reserveFeed = new MockFeed(int256(1_000_000 ether));

        vm.prank(issuer);
        token.issue(user, 100 ether);

        RWATokenV2 v2Impl = new RWATokenV2();
        bytes memory initData = abi.encodeCall(RWATokenV2.initializeV2, (address(reserveFeed)));

        vm.prank(admin);
        UUPSUpgradeable(address(token)).upgradeToAndCall(address(v2Impl), initData);

        RWATokenV2 v2 = RWATokenV2(address(token));
        assertEq(address(v2.reserveFeed()), address(reserveFeed));
    }

    function test_UpgradeToV2_IssueEnforcesReserve() public {
        MockFeed reserveFeed = new MockFeed(int256(500 ether)); // reserve = 500

        vm.prank(issuer);
        token.issue(user, 100 ether); // totalSupply = 100

        RWATokenV2 v2Impl = new RWATokenV2();
        bytes memory initData = abi.encodeCall(RWATokenV2.initializeV2, (address(reserveFeed)));
        vm.prank(admin);
        UUPSUpgradeable(address(token)).upgradeToAndCall(address(v2Impl), initData);

        RWATokenV2 v2 = RWATokenV2(address(token));

        // 500 reserve - 100 supply = 400 headroom; minting 400 should pass
        vm.prank(issuer);
        v2.issue(user, 400 ether);
        assertEq(v2.totalSupply(), 500 ether);

        // Minting 1 more exceeds reserve → revert
        vm.prank(issuer);
        vm.expectRevert();
        v2.issue(user, 1 ether);
    }

    // --- Fuzz tests ---

    function testFuzz_Issue_AnyAmount(uint128 amount) public {
        vm.assume(amount > 0);
        vm.prank(issuer);
        token.issue(user, amount);
        assertEq(token.balanceOf(user), amount);
    }

    function testFuzz_Redeem_Partial(uint128 total, uint128 amount) public {
        vm.assume(total > 0 && amount > 0 && amount <= total);
        vm.prank(issuer);
        token.issue(user, total);
        vm.prank(user);
        token.redeem(amount);
        assertEq(token.balanceOf(user), total - amount);
    }

    function testFuzz_UpdateCollateral_AnyValue(uint256 val) public {
        vm.prank(issuer);
        token.updateCollateral(val);
        assertEq(token.totalCollateral(), val);
    }
}
