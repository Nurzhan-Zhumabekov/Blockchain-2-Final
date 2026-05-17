// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}   from "forge-std/Test.sol";
import {RWAPool}          from "../src/RWAPool.sol";
import {GovernanceToken}  from "../src/GovernanceToken.sol";
import {RWAToken}         from "../src/RWAToken.sol";
import {ERC1967Proxy}     from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockFeed}         from "./MockFeed.sol";

contract RWAPoolTest is Test {
    RWAPool         pool;
    GovernanceToken gov;
    RWAToken        rwa;
    MockFeed        feed;

    address admin  = address(0xB1);
    address lp     = address(0xB2);
    address trader = address(0xB3);

    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    uint256 constant LP0 = 10_000 ether;
    uint256 constant LP1 = 10_000 ether;

    function setUp() public {
        feed = new MockFeed(1e8);

        // Deploy GovernanceToken proxy
        GovernanceToken govImpl = new GovernanceToken();
        gov = GovernanceToken(address(new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(GovernanceToken.initialize, (admin))
        )));

        // Deploy RWAToken proxy
        RWAToken rwaImpl = new RWAToken();
        rwa = RWAToken(address(new ERC1967Proxy(
            address(rwaImpl),
            abi.encodeCall(RWAToken.initialize, (admin, "USTB", "USTB", "BOND", address(feed)))
        )));

        pool = new RWAPool(address(gov), address(rwa), address(feed), admin);

        // Mint tokens to lp and trader
        vm.startPrank(admin);
        gov.mint(lp,     LP0 * 2);
        gov.mint(trader, LP0 / 10);
        rwa.grantRole(ISSUER_ROLE, admin);
        rwa.issue(lp,     LP1 * 2);
        rwa.issue(trader, LP1 / 10);
        vm.stopPrank();

        // LP approves pool
        vm.startPrank(lp);
        gov.approve(address(pool), type(uint256).max);
        rwa.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        // Trader approves pool
        vm.startPrank(trader);
        gov.approve(address(pool), type(uint256).max);
        rwa.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // --- addLiquidity ---

    function test_AddLiquidity_FirstDeposit() public {
        vm.prank(lp);
        uint256 shares = pool.addLiquidity(LP0, LP1, 0, 0);
        assertGt(shares, 0);
        assertEq(pool.reserve0(), LP0);
        assertEq(pool.reserve1(), LP1);
    }

    function test_AddLiquidity_SecondDeposit_ProportionalShares() public {
        vm.prank(lp);
        uint256 shares1 = pool.addLiquidity(LP0, LP1, 0, 0);

        // totalSupply after first deposit = shares1 + MINIMUM_LIQUIDITY (locked in address(1))
        uint256 totalAfterFirst = pool.totalSupply();

        vm.startPrank(lp);
        uint256 shares2 = pool.addLiquidity(LP0, LP1, 0, 0);
        vm.stopPrank();

        // Second deposit of same amount → shares proportional to totalSupply/reserves
        // shares2 = LP0 * totalAfterFirst / LP0 = totalAfterFirst
        assertEq(shares2, totalAfterFirst);
    }

    function test_AddLiquidity_EmitsEvent() public {
        vm.prank(lp);
        vm.expectEmit(true, false, false, false, address(pool));
        emit RWAPool.LiquidityAdded(lp, LP0, LP1, 0);
        pool.addLiquidity(LP0, LP1, 0, 0);
    }

    function test_AddLiquidity_RevertsIfZeroAmount() public {
        vm.prank(lp);
        vm.expectRevert(RWAPool.ZeroAmount.selector);
        pool.addLiquidity(0, LP1, 0, 0);
    }

    function test_AddLiquidity_SlippageCheck() public {
        vm.prank(lp);
        pool.addLiquidity(LP0, LP1, 0, 0); // initial deposit

        // Deposit LP0 token0 and LP1/2 token1 but require LP0 for token0 (will get LP0/2 → revert)
        vm.prank(lp);
        vm.expectRevert();
        pool.addLiquidity(LP0, LP1 / 2, LP0, 0); // amount0Min = LP0, but optimal is LP0/2
    }

    // --- removeLiquidity ---

    function test_RemoveLiquidity_ReturnsTokens() public {
        vm.prank(lp);
        uint256 shares = pool.addLiquidity(LP0, LP1, 0, 0);

        uint256 gov0 = gov.balanceOf(lp);
        uint256 rwa0 = rwa.balanceOf(lp);

        vm.prank(lp);
        pool.approve(address(pool), shares);
        vm.prank(lp);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(shares, 0, 0);

        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(gov.balanceOf(lp), gov0 + a0);
        assertEq(rwa.balanceOf(lp), rwa0 + a1);
    }

    function test_RemoveLiquidity_RevertsIfZeroShares() public {
        vm.prank(lp);
        vm.expectRevert(RWAPool.ZeroAmount.selector);
        pool.removeLiquidity(0, 0, 0);
    }

    // --- swap ---

    function test_Swap_Token0ForToken1() public {
        vm.prank(lp);
        pool.addLiquidity(LP0, LP1, 0, 0);

        uint256 amountIn = 100 ether;
        uint256 rwa0 = rwa.balanceOf(trader);

        vm.prank(trader);
        uint256 out = pool.swap(address(gov), amountIn, 0);

        assertGt(out, 0);
        assertEq(rwa.balanceOf(trader), rwa0 + out);
    }

    function test_Swap_Token1ForToken0() public {
        vm.prank(lp);
        pool.addLiquidity(LP0, LP1, 0, 0);

        uint256 amountIn = 100 ether;
        uint256 gov0 = gov.balanceOf(trader);

        vm.prank(trader);
        uint256 out = pool.swap(address(rwa), amountIn, 0);

        assertGt(out, 0);
        assertEq(gov.balanceOf(trader), gov0 + out);
    }

    function test_Swap_RevertsInvalidToken() public {
        vm.prank(lp);
        pool.addLiquidity(LP0, LP1, 0, 0);

        vm.prank(trader);
        vm.expectRevert(RWAPool.InvalidToken.selector);
        pool.swap(address(0xDEAD), 100 ether, 0);
    }

    function test_Swap_RevertsIfZeroAmount() public {
        vm.prank(lp);
        pool.addLiquidity(LP0, LP1, 0, 0);

        vm.prank(trader);
        vm.expectRevert(RWAPool.ZeroAmount.selector);
        pool.swap(address(gov), 0, 0);
    }

    function test_Swap_SlippageProtection() public {
        vm.prank(lp);
        pool.addLiquidity(LP0, LP1, 0, 0);

        uint256 amountIn = 100 ether;
        uint256 expected = pool.getAmountOut(amountIn, LP0, LP1);

        vm.prank(trader);
        vm.expectRevert();
        pool.swap(address(gov), amountIn, expected + 1); // require more than possible
    }

    function test_Swap_StalePrice_Reverts() public {
        vm.prank(lp);
        pool.addLiquidity(LP0, LP1, 0, 0);

        vm.warp(block.timestamp + 3 hours); // ensure headroom for stale check
        feed.setUpdatedAt(block.timestamp - 2 hours);

        vm.prank(trader);
        vm.expectRevert();
        pool.swap(address(gov), 100 ether, 0);
    }

    // --- getAmountOut vs getAmountOutSolidity ---

    function test_GetAmountOut_MatchesSolidity() public view {
        uint256 amountIn   = 1_000 ether;
        uint256 reserveIn  = 100_000 ether;
        uint256 reserveOut = 100_000 ether;

        uint256 yul     = pool.getAmountOut(amountIn, reserveIn, reserveOut);
        uint256 solidity = pool.getAmountOutSolidity(amountIn, reserveIn, reserveOut);
        assertEq(yul, solidity);
    }

    function testFuzz_GetAmountOut_MatchesSolidity(
        uint128 amountIn,
        uint128 reserveIn,
        uint128 reserveOut
    ) public view {
        vm.assume(amountIn > 0 && reserveIn > 0 && reserveOut > 0);
        // Prevent overflow: amountIn * 997 * reserveOut must fit in uint256
        // max safe: amountIn * reserveOut < 2^256 / 1000
        vm.assume(uint256(amountIn) <= 1e30 && uint256(reserveOut) <= 1e30);
        uint256 yul     = pool.getAmountOut(amountIn, reserveIn, reserveOut);
        uint256 sol     = pool.getAmountOutSolidity(amountIn, reserveIn, reserveOut);
        assertEq(yul, sol);
    }

    // --- getAmountOut reverts on zero reserves ---

    function test_GetAmountOut_RevertsZeroReserveIn() public {
        vm.expectRevert(RWAPool.InsufficientLiquidity.selector);
        pool.getAmountOut(100 ether, 0, 1000 ether);
    }

    // --- Pause ---

    function test_Pause_BlocksSwap() public {
        vm.prank(lp);
        pool.addLiquidity(LP0, LP1, 0, 0);

        vm.prank(admin);
        pool.pause();

        vm.prank(trader);
        vm.expectRevert();
        pool.swap(address(gov), 100 ether, 0);
    }

    function test_Unpause_AllowsSwap() public {
        vm.prank(lp);
        pool.addLiquidity(LP0, LP1, 0, 0);

        vm.prank(admin);
        pool.pause();
        vm.prank(admin);
        pool.unpause();

        vm.prank(trader);
        uint256 out = pool.swap(address(gov), 100 ether, 0);
        assertGt(out, 0);
    }

    // --- k invariant: reserve0 * reserve1 should not decrease after swap ---

    function testFuzz_KInvariant(uint96 amountIn) public {
        // Avoid amounts so small getAmountOut rounds to 0 → InsufficientOutputAmount
        vm.assume(amountIn > 1e15 && amountIn < LP0 / 2);

        vm.prank(lp);
        pool.addLiquidity(LP0, LP1, 0, 0);

        uint256 kBefore = pool.reserve0() * pool.reserve1();

        vm.prank(trader);
        gov.approve(address(pool), amountIn);
        vm.prank(admin);
        gov.mint(trader, amountIn);
        vm.prank(trader);
        pool.swap(address(gov), amountIn, 0);

        uint256 kAfter = pool.reserve0() * pool.reserve1();
        assertGe(kAfter, kBefore); // k can only grow (due to fees)
    }
}
