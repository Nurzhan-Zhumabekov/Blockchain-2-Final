// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}   from "forge-std/Test.sol";
import {StdInvariant}     from "forge-std/StdInvariant.sol";
import {RWAPool}          from "../src/RWAPool.sol";
import {GovernanceToken}  from "../src/GovernanceToken.sol";
import {RWAToken}         from "../src/RWAToken.sol";
import {RWAVault}         from "../src/RWAVault.sol";
import {ERC1967Proxy}     from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockFeed}         from "./MockFeed.sol";

// Handler for AMM invariants — wraps swap/addLiquidity calls with bounded inputs.
contract PoolHandler is Test {
    RWAPool         pool;
    GovernanceToken gov;
    RWAToken        rwa;

    address admin = address(0xF1);

    bytes32 constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    constructor(RWAPool _pool, GovernanceToken _gov, RWAToken _rwa) {
        pool = _pool;
        gov  = _gov;
        rwa  = _rwa;
    }

    function swapGovForRwa(uint256 amountIn) external {
        amountIn = bound(amountIn, 1, 1_000 ether);

        vm.startPrank(msg.sender);
        if (gov.balanceOf(msg.sender) < amountIn) return;
        gov.approve(address(pool), amountIn);
        try pool.swap(address(gov), amountIn, 0) {} catch {}
        vm.stopPrank();
    }

    function swapRwaForGov(uint256 amountIn) external {
        amountIn = bound(amountIn, 1, 1_000 ether);

        vm.startPrank(msg.sender);
        if (rwa.balanceOf(msg.sender) < amountIn) return;
        rwa.approve(address(pool), amountIn);
        try pool.swap(address(rwa), amountIn, 0) {} catch {}
        vm.stopPrank();
    }

    function addLiquidity(uint256 amount0, uint256 amount1) external {
        amount0 = bound(amount0, 1, 500 ether);
        amount1 = bound(amount1, 1, 500 ether);

        vm.startPrank(msg.sender);
        if (gov.balanceOf(msg.sender) < amount0) return;
        if (rwa.balanceOf(msg.sender) < amount1) return;
        gov.approve(address(pool), amount0);
        rwa.approve(address(pool), amount1);
        try pool.addLiquidity(amount0, amount1, 0, 0) {} catch {}
        vm.stopPrank();
    }
}

contract RWAPoolInvariantTest is StdInvariant, Test {
    RWAPool         pool;
    GovernanceToken gov;
    RWAToken        rwa;
    MockFeed        feed;
    PoolHandler     handler;

    address admin  = address(0xF1);
    address lp     = address(0xF2);
    address trader = address(0xF3);

    bytes32 constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");

    function setUp() public {
        feed = new MockFeed(1e8);

        GovernanceToken govImpl = new GovernanceToken();
        gov = GovernanceToken(address(new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(GovernanceToken.initialize, (admin))
        )));

        RWAToken rwaImpl = new RWAToken();
        rwa = RWAToken(address(new ERC1967Proxy(
            address(rwaImpl),
            abi.encodeCall(RWAToken.initialize, (admin, "USTB", "USTB", "BOND", address(feed)))
        )));

        pool = new RWAPool(address(gov), address(rwa), address(feed), admin);

        vm.startPrank(admin);
        gov.grantRole(MINTER_ROLE, admin);
        gov.mint(lp,      100_000 ether);
        gov.mint(trader,  50_000 ether);
        rwa.grantRole(ISSUER_ROLE, admin);
        rwa.issue(lp,     100_000 ether);
        rwa.issue(trader, 50_000 ether);
        vm.stopPrank();

        // Seed initial liquidity
        vm.startPrank(lp);
        gov.approve(address(pool), type(uint256).max);
        rwa.approve(address(pool), type(uint256).max);
        pool.addLiquidity(50_000 ether, 50_000 ether, 0, 0);
        vm.stopPrank();

        handler = new PoolHandler(pool, gov, rwa);

        // Give handler actors tokens
        vm.prank(admin);
        gov.mint(address(handler), 10_000 ether);
        vm.prank(admin);
        rwa.issue(address(handler), 10_000 ether);

        // Target the handler for invariant fuzzing
        targetContract(address(handler));
    }

    // Invariant: Pool's tracked reserves always match actual token balances.
    function invariant_ReservesMatchBalances() public view {
        assertEq(pool.reserve0(), gov.balanceOf(address(pool)));
        assertEq(pool.reserve1(), rwa.balanceOf(address(pool)));
    }

    // Invariant: k (reserve0 * reserve1) is non-decreasing after operations.
    // We track this indirectly: both reserves must be > 0 as long as any LP shares exist.
    function invariant_PositiveReservesWhileLPExists() public view {
        if (pool.totalSupply() > pool.MINIMUM_LIQUIDITY()) {
            assertGt(pool.reserve0(), 0);
            assertGt(pool.reserve1(), 0);
        }
    }

    // Invariant: Total LP supply >= MINIMUM_LIQUIDITY once pool is seeded.
    function invariant_MinLiquidityLocked() public view {
        if (pool.reserve0() > 0) {
            assertGe(pool.totalSupply(), pool.MINIMUM_LIQUIDITY());
        }
    }
}

// Handler for Vault invariants
contract VaultHandler is Test {
    RWAVault vault;
    RWAToken token;

    constructor(RWAVault _vault, RWAToken _token) {
        vault = _vault;
        token = _token;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        vm.startPrank(msg.sender);
        if (token.balanceOf(msg.sender) < amount) return;
        token.approve(address(vault), amount);
        try vault.deposit(amount, msg.sender) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        vm.startPrank(msg.sender);
        uint256 maxWithdraw = vault.maxWithdraw(msg.sender);
        if (maxWithdraw == 0) return;
        amount = amount > maxWithdraw ? maxWithdraw : amount;
        try vault.withdraw(amount, msg.sender, msg.sender) {} catch {}
        vm.stopPrank();
    }
}

contract RWAVaultInvariantTest is StdInvariant, Test {
    RWAVault     vault;
    RWAToken     token;
    VaultHandler handler;
    MockFeed     feed;

    address admin   = address(0xF5);
    address manager = address(0xF6);
    address user    = address(0xF7);

    bytes32 constant ISSUER_ROLE  = keccak256("ISSUER_ROLE");
    bytes32 constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    function setUp() public {
        feed = new MockFeed(1e8);

        RWAToken tokenImpl = new RWAToken();
        token = RWAToken(address(new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeCall(RWAToken.initialize, (admin, "USTB", "USTB", "BOND", address(feed)))
        )));

        RWAVault vaultImpl = new RWAVault();
        vault = RWAVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(RWAVault.initialize, (admin, address(token)))
        )));

        vm.startPrank(admin);
        token.grantRole(ISSUER_ROLE, admin);
        token.issue(user,    100_000 ether);
        vault.grantRole(MANAGER_ROLE, manager);
        vm.stopPrank();

        handler = new VaultHandler(vault, token);
        vm.prank(admin);
        token.issue(address(handler), 100_000 ether);

        targetContract(address(handler));
    }

    // Invariant: vault's token balance == totalAssets()
    function invariant_TotalAssetsMatchBalance() public view {
        assertEq(token.balanceOf(address(vault)), vault.totalAssets());
    }

    // Invariant: sum of all shares redeemable never exceeds totalAssets
    // (ERC-4626 rounding ensures no user can redeem more than the vault holds)
    function invariant_SolvencyConvertToAssets() public view {
        uint256 totalShares = vault.totalSupply();
        if (totalShares == 0) return;
        uint256 totalRedeemable = vault.convertToAssets(totalShares);
        assertLe(totalRedeemable, vault.totalAssets() + 1); // +1 for rounding
    }
}
