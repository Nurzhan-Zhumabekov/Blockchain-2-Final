// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}       from "forge-std/Test.sol";
import {RWAGovernor}          from "../src/RWAGovernor.sol";
import {RWATimelock}          from "../src/RWATimelock.sol";
import {GovernanceToken}      from "../src/GovernanceToken.sol";
import {ERC1967Proxy}         from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController}   from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor}            from "@openzeppelin/contracts/governance/IGovernor.sol";

contract RWAGovernorTest is Test {
    RWAGovernor    governor;
    RWATimelock    timelock;
    GovernanceToken govToken;

    address admin   = address(0xE1);
    address voter1  = address(0xE2);
    address voter2  = address(0xE3);
    address other   = address(0xE4);

    bytes32 constant MINTER_ROLE    = keccak256("MINTER_ROLE");
    bytes32 constant PROPOSER_ROLE  = keccak256("PROPOSER_ROLE");
    bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    uint256 constant VOTE_DELAY  = 1 days;
    uint256 constant VOTE_PERIOD = 1 weeks;
    uint256 constant TIMELOCK_DELAY = 2 days;

    function setUp() public {
        // Deploy GovernanceToken
        GovernanceToken govImpl = new GovernanceToken();
        govToken = GovernanceToken(address(new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(GovernanceToken.initialize, (admin))
        )));

        // Mint tokens and delegate
        vm.startPrank(admin);
        govToken.grantRole(MINTER_ROLE, admin);
        govToken.mint(voter1, 5_000_000 ether);
        govToken.mint(voter2, 5_000_000 ether);
        vm.stopPrank();

        vm.prank(voter1); govToken.delegate(voter1);
        vm.prank(voter2); govToken.delegate(voter2);

        // Deploy Timelock (no initial proposers)
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new RWATimelock(TIMELOCK_DELAY, proposers, executors, admin);

        // Deploy Governor
        governor = new RWAGovernor(
            govToken,
            TimelockController(payable(address(timelock)))
        );

        // Wire governor roles on timelock
        vm.startPrank(admin);
        timelock.grantRole(PROPOSER_ROLE,  address(governor));
        timelock.grantRole(CANCELLER_ROLE, address(governor));
        timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();

        // Advance block so votes are checkpointed
        vm.roll(block.number + 1);
    }

    // --- Basic parameter checks ---

    function test_VotingDelay() public view {
        assertEq(governor.votingDelay(), VOTE_DELAY);
    }

    function test_VotingPeriod() public view {
        assertEq(governor.votingPeriod(), VOTE_PERIOD);
    }

    function test_ProposalThreshold() public view {
        assertEq(governor.proposalThreshold(), 1000e18);
    }

    function test_QuorumNumerator() public view {
        assertEq(governor.quorumNumerator(), 4);
    }

    // --- Full proposal lifecycle ---

    function _makeProposal() internal returns (
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) {
        targets      = new address[](1);
        values       = new uint256[](1);
        calldatas    = new bytes[](1);
        targets[0]   = address(govToken);
        values[0]    = 0;
        calldatas[0] = abi.encodeCall(GovernanceToken.mint, (other, 100 ether));
        description  = "Proposal: mint 100 RWAGOV to other";

        vm.prank(voter1);
        proposalId = governor.propose(targets, values, calldatas, description);
    }

    function test_Propose_CreatesProposal() public {
        (uint256 id,,,, ) = _makeProposal();
        assertGt(id, 0);
    }

    function test_Propose_StateIsPending() public {
        (uint256 id,,,, ) = _makeProposal();
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));
    }

    function test_Vote_AfterDelay() public {
        (uint256 id,,,,) = _makeProposal();

        // Governor uses block.number clock (ERC20Votes default). Advance past votingDelay in blocks.
        vm.roll(block.number + VOTE_DELAY + 1);

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active));

        vm.prank(voter1);
        governor.castVote(id, 1); // FOR

        vm.prank(voter2);
        governor.castVote(id, 1); // FOR

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(id);
        assertGt(forVotes, 0);
        assertEq(against, 0);
        assertEq(abstain, 0);
    }

    function test_ProposalSucceedsAndQueues() public {
        (uint256 id, address[] memory targets, uint256[] memory values,
         bytes[] memory calldatas, string memory description) = _makeProposal();

        vm.roll(block.number + VOTE_DELAY + 1);

        vm.prank(voter1); governor.castVote(id, 1);
        vm.prank(voter2); governor.castVote(id, 1);

        // Advance past voting period (also in blocks)
        vm.roll(block.number + VOTE_PERIOD + 1);

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));

        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));
    }

    function test_ProposalExecutes() public {
        // Grant timelock MINTER_ROLE so it can execute the mint proposal
        vm.prank(admin);
        govToken.grantRole(MINTER_ROLE, address(timelock));

        (uint256 id, address[] memory targets, uint256[] memory values,
         bytes[] memory calldatas, string memory description) = _makeProposal();

        vm.roll(block.number + VOTE_DELAY + 1);
        vm.prank(voter1); governor.castVote(id, 1);
        vm.prank(voter2); governor.castVote(id, 1);

        vm.roll(block.number + VOTE_PERIOD + 1);

        governor.queue(targets, values, calldatas, keccak256(bytes(description)));

        // Timelock uses timestamps — advance past the timelock delay
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));
        assertEq(govToken.balanceOf(other), 100 ether);
    }

    function test_Vote_AgainstCausesDefeat() public {
        (uint256 id,,,,) = _makeProposal();

        vm.roll(block.number + VOTE_DELAY + 1);

        vm.prank(voter1); governor.castVote(id, 0); // AGAINST
        vm.prank(voter2); governor.castVote(id, 0);

        vm.roll(block.number + VOTE_PERIOD + 1);

        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    // --- GovernanceToken ---

    function test_GovernanceToken_MaxSupply() public view {
        assertEq(govToken.MAX_SUPPLY(), 100_000_000 ether);
    }

    function test_GovernanceToken_Mint_RevertsAboveMax() public {
        vm.prank(admin);
        vm.expectRevert();
        govToken.mint(voter1, 100_000_001 ether);
    }

    function test_GovernanceToken_DelegateTracksVotes() public {
        vm.prank(voter1);
        govToken.delegate(voter1);
        assertGt(govToken.getVotes(voter1), 0);
    }

    function test_GovernanceToken_Burn() public {
        uint256 bal = govToken.balanceOf(voter1);
        vm.prank(voter1);
        govToken.burn(100 ether);
        assertEq(govToken.balanceOf(voter1), bal - 100 ether);
    }
}
