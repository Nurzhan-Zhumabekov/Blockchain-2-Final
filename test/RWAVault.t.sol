// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}   from "forge-std/Test.sol";
import {RWAVault}         from "../src/RWAVault.sol";
import {RWAToken}         from "../src/RWAToken.sol";
import {ERC1967Proxy}     from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockFeed}         from "./MockFeed.sol";

contract RWAVaultTest is Test {
    RWAVault  vault;
    RWAToken  token;
    MockFeed  feed;

    address admin   = address(0xD1);
    address manager = address(0xD2);
    address user1   = address(0xD3);
    address user2   = address(0xD4);

    bytes32 constant ISSUER_ROLE  = keccak256("ISSUER_ROLE");
    bytes32 constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    function setUp() public {
        feed = new MockFeed(1e8);

        RWAToken tokenImpl = new RWAToken();
        token = RWAToken(address(new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeCall(RWAToken.initialize, (admin, "USTB Token", "USTB", "BOND", address(feed)))
        )));

        RWAVault vaultImpl = new RWAVault();
        vault = RWAVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(RWAVault.initialize, (admin, address(token)))
        )));

        vm.startPrank(admin);
        token.grantRole(ISSUER_ROLE, admin);
        vault.grantRole(MANAGER_ROLE, manager);
        // Mint tokens to users
        token.issue(user1, 10_000 ether);
        token.issue(user2, 10_000 ether);
        token.issue(manager, 5_000 ether);
        vm.stopPrank();

        // Approvals
        vm.prank(user1);   token.approve(address(vault), type(uint256).max);
        vm.prank(user2);   token.approve(address(vault), type(uint256).max);
        vm.prank(manager); token.approve(address(vault), type(uint256).max);
    }

    // --- Initialization ---

    function test_Initialize_Name() public view {
        assertEq(vault.name(), "RWA Vault Shares");
    }

    function test_Initialize_Symbol() public view {
        assertEq(vault.symbol(), "vRWA");
    }

    function test_Initialize_AssetIsRWAToken() public view {
        assertEq(vault.asset(), address(token));
    }

    function test_Initialize_AdminHasRole() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
    }

    // --- ERC-4626 deposit/withdraw ---

    function test_Deposit_MintsShares() public {
        vm.prank(user1);
        uint256 shares = vault.deposit(1000 ether, user1);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(user1), shares);
    }

    function test_Deposit_TransfersAssets() public {
        uint256 before = token.balanceOf(user1);
        vm.prank(user1);
        vault.deposit(1000 ether, user1);
        assertEq(token.balanceOf(user1), before - 1000 ether);
    }

    function test_Withdraw_BurnsShares() public {
        vm.prank(user1);
        vault.deposit(1000 ether, user1);

        uint256 sharesBefore = vault.balanceOf(user1);
        vm.prank(user1);
        vault.withdraw(500 ether, user1, user1);
        assertLt(vault.balanceOf(user1), sharesBefore);
    }

    function test_Withdraw_ReturnsAssets() public {
        vm.prank(user1);
        vault.deposit(1000 ether, user1);

        uint256 before = token.balanceOf(user1);
        vm.prank(user1);
        vault.withdraw(500 ether, user1, user1);
        assertEq(token.balanceOf(user1), before + 500 ether);
    }

    function test_TwoUsers_SharesAreFair() public {
        vm.prank(user1);
        uint256 shares1 = vault.deposit(1000 ether, user1);
        vm.prank(user2);
        uint256 shares2 = vault.deposit(1000 ether, user2);
        assertEq(shares1, shares2); // same deposits → same shares
    }

    // --- depositYield ---

    function test_DepositYield_IncreasesShareValue() public {
        vm.prank(user1);
        vault.deposit(1000 ether, user1);

        uint256 assetsBefore = vault.convertToAssets(vault.balanceOf(user1));

        vm.prank(manager);
        vault.depositYield(200 ether);

        uint256 assetsAfter = vault.convertToAssets(vault.balanceOf(user1));
        assertGt(assetsAfter, assetsBefore);
    }

    function test_DepositYield_UpdatesTotalYieldAccrued() public {
        vm.prank(manager);
        vault.depositYield(500 ether);
        assertEq(vault.totalYieldAccrued(), 500 ether);

        vm.prank(manager);
        vault.depositYield(300 ether);
        assertEq(vault.totalYieldAccrued(), 800 ether);
    }

    function test_DepositYield_EmitsEvent() public {
        vm.prank(manager);
        vm.expectEmit(true, false, false, true, address(vault));
        emit RWAVault.YieldDeposited(manager, 1000 ether);
        vault.depositYield(1000 ether);
    }

    function test_DepositYield_RevertsIfNotManager() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.depositYield(100 ether);
    }

    function test_DepositYield_RevertsIfZero() public {
        vm.prank(manager);
        vm.expectRevert(RWAVault.ZeroAmount.selector);
        vault.depositYield(0);
    }

    // --- Yield distribution: later depositors don't dilute yield ---

    function test_Yield_LateDepositor_DoesNotGetPriorYield() public {
        // user1 deposits, yield added, user2 deposits
        vm.prank(user1);
        vault.deposit(1000 ether, user1);

        vm.prank(manager);
        vault.depositYield(1000 ether); // 100% yield

        vm.prank(user2);
        vault.deposit(1000 ether, user2);

        // user2 deposited 1000 tokens but pool now has 3000 tokens for (shares1 + shares2) shares
        // user1 should withdraw ~2000, user2 should withdraw ~1000
        uint256 redeem1 = vault.convertToAssets(vault.balanceOf(user1));
        uint256 redeem2 = vault.convertToAssets(vault.balanceOf(user2));
        assertGt(redeem1, redeem2); // user1 earned yield
    }

    // --- Fuzz ---

    function testFuzz_DepositAndWithdraw(uint128 amount) public {
        vm.assume(amount > 0 && amount <= 10_000 ether);
        vm.prank(user1);
        uint256 shares = vault.deposit(amount, user1);
        assertGt(shares, 0);
        vm.prank(user1);
        uint256 assets = vault.redeem(shares, user1, user1);
        assertApproxEqAbs(assets, amount, 1); // rounding tolerance of 1 wei
    }

    function testFuzz_DepositYield(uint128 yield) public {
        vm.assume(yield > 0 && yield <= 5_000 ether);
        vm.prank(user1);
        vault.deposit(1000 ether, user1);
        vm.prank(manager);
        vault.depositYield(yield);
        assertGt(vault.convertToAssets(vault.balanceOf(user1)), 0);
    }
}
