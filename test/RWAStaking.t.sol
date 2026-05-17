// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}   from "forge-std/Test.sol";
import {RWAStaking}       from "../src/RWAStaking.sol";
import {GovernanceToken}  from "../src/GovernanceToken.sol";
import {RWAToken}         from "../src/RWAToken.sol";
import {ERC1967Proxy}     from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockFeed}         from "./MockFeed.sol";

contract RWAStakingTest is Test {
    RWAStaking      staking;
    GovernanceToken gov;     // staking token (RWAGOV)
    RWAToken        rwa;     // reward token

    MockFeed feed;

    address admin   = address(0xAA1);
    address alice   = address(0xAA2);
    address bob     = address(0xAA3);
    address manager = address(0xAA4);

    bytes32 constant MINTER_ROLE    = keccak256("MINTER_ROLE");
    bytes32 constant ISSUER_ROLE    = keccak256("ISSUER_ROLE");
    bytes32 constant REWARDS_MANAGER = keccak256("REWARDS_MANAGER");

    uint256 constant DURATION = 7 days;
    uint256 constant REWARD   = 70_000 ether; // 10_000 RWAGOV/day over 7 days

    function setUp() public {
        feed = new MockFeed(1e8);

        // GovernanceToken (staking token)
        GovernanceToken govImpl = new GovernanceToken();
        gov = GovernanceToken(address(new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(GovernanceToken.initialize, (admin))
        )));

        // RWAToken (reward token)
        RWAToken rwaImpl = new RWAToken();
        rwa = RWAToken(address(new ERC1967Proxy(
            address(rwaImpl),
            abi.encodeCall(RWAToken.initialize, (admin, "USTB", "USTB", "BOND", address(feed)))
        )));

        staking = new RWAStaking(address(gov), address(rwa), admin, DURATION);

        // Mint RWAGOV to stakers
        vm.startPrank(admin);
        gov.mint(alice, 10_000 ether);
        gov.mint(bob,   5_000 ether);

        // Mint reward tokens and send to staking contract (DAO would do this via governance)
        rwa.grantRole(ISSUER_ROLE, admin);
        rwa.issue(address(staking), REWARD);

        staking.grantRole(REWARDS_MANAGER, manager);
        vm.stopPrank();

        // Approvals
        vm.prank(alice); gov.approve(address(staking), type(uint256).max);
        vm.prank(bob);   gov.approve(address(staking), type(uint256).max);
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    function test_Constructor_StakingToken() public view {
        assertEq(address(staking.stakingToken()), address(gov));
    }

    function test_Constructor_RewardToken() public view {
        assertEq(address(staking.rewardToken()), address(rwa));
    }

    function test_Constructor_Duration() public view {
        assertEq(staking.rewardsDuration(), DURATION);
    }

    // ─── notifyRewardAmount ───────────────────────────────────────────────────

    function test_NotifyRewardAmount_SetsRate() public {
        vm.prank(manager);
        staking.notifyRewardAmount(REWARD);
        assertGt(staking.rewardRate(), 0);
    }

    function test_NotifyRewardAmount_SetsPeriodFinish() public {
        vm.prank(manager);
        staking.notifyRewardAmount(REWARD);
        assertEq(staking.periodFinish(), block.timestamp + DURATION);
    }

    function test_NotifyRewardAmount_RevertsIfNotManager() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.notifyRewardAmount(REWARD);
    }

    // ─── stake ────────────────────────────────────────────────────────────────

    function test_Stake_IncreasesBalance() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice);
        staking.stake(1_000 ether);
        assertEq(staking.balanceOf(alice), 1_000 ether);
        assertEq(staking.totalSupply(), 1_000 ether);
    }

    function test_Stake_TransfersTokens() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        uint256 before = gov.balanceOf(alice);
        vm.prank(alice);
        staking.stake(1_000 ether);
        assertEq(gov.balanceOf(alice), before - 1_000 ether);
    }

    function test_Stake_EmitsEvent() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(staking));
        emit RWAStaking.Staked(alice, 1_000 ether);
        staking.stake(1_000 ether);
    }

    function test_Stake_RevertsIfZero() public {
        vm.prank(alice);
        vm.expectRevert(RWAStaking.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_Stake_RevertsWhenPaused() public {
        vm.prank(admin);
        staking.pause();
        vm.prank(alice);
        vm.expectRevert();
        staking.stake(1_000 ether);
    }

    // ─── withdraw ─────────────────────────────────────────────────────────────

    function test_Withdraw_DecreasesBalance() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice); staking.stake(1_000 ether);
        vm.prank(alice); staking.withdraw(400 ether);
        assertEq(staking.balanceOf(alice), 600 ether);
    }

    function test_Withdraw_ReturnsTokens() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice); staking.stake(1_000 ether);
        uint256 before = gov.balanceOf(alice);
        vm.prank(alice); staking.withdraw(1_000 ether);
        assertEq(gov.balanceOf(alice), before + 1_000 ether);
    }

    function test_Withdraw_RevertsIfZero() public {
        vm.prank(alice);
        vm.expectRevert(RWAStaking.ZeroAmount.selector);
        staking.withdraw(0);
    }

    // ─── earned / claimReward ─────────────────────────────────────────────────

    function test_Earned_AccruedOverTime() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice); staking.stake(1_000 ether);

        vm.warp(block.timestamp + 1 days);

        uint256 earned = staking.earned(alice);
        assertGt(earned, 0);
    }

    function test_ClaimReward_TransfersRewards() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice); staking.stake(1_000 ether);

        vm.warp(block.timestamp + 1 days);

        uint256 before = rwa.balanceOf(alice);
        vm.prank(alice); staking.claimReward();
        assertGt(rwa.balanceOf(alice), before);
    }

    function test_ClaimReward_ClearsAccrued() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice); staking.stake(1_000 ether);

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice); staking.claimReward();
        assertEq(staking.rewards(alice), 0);
    }

    function test_ClaimReward_EmitsEvent() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice); staking.stake(1_000 ether);

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectEmit(true, false, false, false, address(staking));
        emit RWAStaking.RewardPaid(alice, 0);
        staking.claimReward();
    }

    // ─── Two stakers — proportional rewards ──────────────────────────────────

    function test_TwoStakers_ProportionalRewards() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);

        // Alice stakes 2x Bob
        vm.prank(alice); staking.stake(2_000 ether);
        vm.prank(bob);   staking.stake(1_000 ether);

        vm.warp(block.timestamp + DURATION);

        uint256 aliceEarned = staking.earned(alice);
        uint256 bobEarned   = staking.earned(bob);

        // Alice should earn ~2x Bob's rewards
        assertApproxEqRel(aliceEarned, 2 * bobEarned, 0.01e18); // 1% tolerance
    }

    function test_TwoStakers_TotalRewardBounded() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);

        vm.prank(alice); staking.stake(5_000 ether);
        vm.prank(bob);   staking.stake(5_000 ether);

        vm.warp(block.timestamp + DURATION);

        uint256 total = staking.earned(alice) + staking.earned(bob);
        // Total earned must not exceed the deposited reward (with small rounding margin)
        assertLe(total, REWARD + 1e12);
    }

    // ─── exit ─────────────────────────────────────────────────────────────────

    function test_Exit_WithdrawsAndClaims() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice); staking.stake(1_000 ether);

        vm.warp(block.timestamp + 1 days);

        uint256 govBefore = gov.balanceOf(alice);
        uint256 rwaBefore = rwa.balanceOf(alice);

        vm.prank(alice); staking.exit();

        assertGt(gov.balanceOf(alice), govBefore);
        assertGt(rwa.balanceOf(alice), rwaBefore);
        assertEq(staking.balanceOf(alice), 0);
    }

    // ─── rewardPerToken at zero supply ────────────────────────────────────────

    function test_RewardPerToken_ZeroSupply_NoChange() public {
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.rewardPerToken(), staking.rewardPerTokenStored()); // no stakers → stays 0
    }

    // ─── setRewardsDuration ──────────────────────────────────────────────────

    function test_SetDuration_UpdatesDuration() public {
        vm.prank(manager);
        staking.setRewardsDuration(14 days);
        assertEq(staking.rewardsDuration(), 14 days);
    }

    function test_SetDuration_RevertsIfZero() public {
        vm.prank(manager);
        vm.expectRevert(RWAStaking.ZeroAmount.selector);
        staking.setRewardsDuration(0);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_Stake_AnyAmount(uint128 amount) public {
        vm.assume(amount > 0 && amount <= 10_000 ether);
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice); staking.stake(amount);
        assertEq(staking.balanceOf(alice), amount);
    }

    function testFuzz_Earned_GrowsOverTime(uint48 elapsed) public {
        vm.assume(elapsed > 0 && elapsed <= DURATION);
        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice); staking.stake(1_000 ether);
        vm.warp(block.timestamp + elapsed);
        assertGt(staking.earned(alice), 0);
    }

    function testFuzz_TotalEarned_NeverExceedsReward(uint48 elapsed, uint96 aliceAmt, uint96 bobAmt) public {
        vm.assume(elapsed > 0 && elapsed <= DURATION);
        vm.assume(aliceAmt > 0 && aliceAmt <= 8_000 ether);
        vm.assume(bobAmt > 0 && bobAmt <= 4_000 ether);

        vm.prank(manager); staking.notifyRewardAmount(REWARD);
        vm.prank(alice); staking.stake(aliceAmt);
        vm.prank(bob);   staking.stake(bobAmt);

        vm.warp(block.timestamp + elapsed);

        uint256 total = staking.earned(alice) + staking.earned(bob);
        assertLe(total, REWARD + 1e15); // 1e15 rounding tolerance
    }
}
