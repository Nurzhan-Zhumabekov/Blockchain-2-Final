// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor}                    from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings}            from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple}      from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes}               from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl}     from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {IVotes}                      from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController}          from "@openzeppelin/contracts/governance/TimelockController.sol";

// DAO Governor for the RWA Tokenization Platform.
// Uses RWAGOV (GovernanceToken with ERC20Votes) as the voting token.
// Timelock enforces a mandatory execution delay after proposals pass.
//
// Parameters (all adjustable via governance proposals):
//   votingDelay   : 1 day  — blocks between proposal creation and vote start
//   votingPeriod  : 1 week — duration of the voting window
//   proposalThreshold: 1000 RWAGOV — tokens needed to create a proposal
//   quorumNumerator: 4%  — fraction of total supply that must vote FOR
contract RWAGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    constructor(IVotes _token, TimelockController _timelock)
        Governor("RWA Governor")
        GovernorSettings(
            1 days,    // votingDelay
            1 weeks,   // votingPeriod
            1000e18    // proposalThreshold
        )
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4)
        GovernorTimelockControl(_timelock)
    {}

    // --- Required overrides ---

    function votingDelay()
        public view override(Governor, GovernorSettings)
        returns (uint256)
    { return super.votingDelay(); }

    function votingPeriod()
        public view override(Governor, GovernorSettings)
        returns (uint256)
    { return super.votingPeriod(); }

    function quorum(uint256 blockNumber)
        public view override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    { return super.quorum(blockNumber); }

    function proposalThreshold()
        public view override(Governor, GovernorSettings)
        returns (uint256)
    { return super.proposalThreshold(); }

    function state(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    { return super.state(proposalId); }

    function proposalNeedsQueuing(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl)
        returns (bool)
    { return super.proposalNeedsQueuing(proposalId); }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal view override(Governor, GovernorTimelockControl)
        returns (address)
    { return super._executor(); }
}
