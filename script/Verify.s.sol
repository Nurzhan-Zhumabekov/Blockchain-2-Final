// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}      from "forge-std/Script.sol";
import {GovernanceToken}       from "../src/GovernanceToken.sol";
import {RWAPool}               from "../src/RWAPool.sol";
import {RWAGovernor}           from "../src/RWAGovernor.sol";
import {TimelockController}    from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl}        from "@openzeppelin/contracts/access/IAccessControl.sol";

// Post-deployment verification script.
//
// Reads deployed addresses from env vars, then checks that every contract
// is wired up correctly — no admin backdoors, correct role assignments,
// governor parameters within spec, and Timelock as the only admin.
//
// Usage (read-only, no broadcast):
//   forge script script/Verify.s.sol \
//     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
//     --env-file .env.deployed
//
// Required env vars:
//   GOV_PROXY          — GovernanceToken proxy address
//   TIMELOCK_ADDR      — RWATimelock address
//   GOVERNOR_ADDR      — RWAGovernor address
//   FACTORY_ADDR       — RWAFactory address
//   POOL_ADDR          — RWAPool address
//   STAKING_ADDR       — RWAStaking address (optional)
//   RWA_TOKEN_PROXY    — RWAToken proxy address
//   DEPLOYER_ADDR      — original deployer EOA (must have NO remaining admin roles)
contract Verify is Script {

    uint256 constant EXPECTED_TIMELOCK_DELAY    = 2 days;
    uint256 constant EXPECTED_VOTING_DELAY      = 1 days;
    uint256 constant EXPECTED_VOTING_PERIOD     = 1 weeks;
    uint256 constant EXPECTED_PROPOSAL_THRESH   = 1000 ether;
    uint256 constant EXPECTED_QUORUM_NUMERATOR  = 4;

    uint256 internal passCount;
    uint256 internal failCount;

    function run() external {
        address govProxy      = vm.envAddress("GOV_PROXY");
        address timelockAddr  = vm.envAddress("TIMELOCK_ADDR");
        address governorAddr  = vm.envAddress("GOVERNOR_ADDR");
        address factoryAddr   = vm.envAddress("FACTORY_ADDR");
        address poolAddr      = vm.envAddress("POOL_ADDR");
        address rwaProxy      = vm.envAddress("RWA_TOKEN_PROXY");
        address deployer      = vm.envAddress("DEPLOYER_ADDR");

        console2.log("===========================================");
        console2.log(" RWA Platform - Post-Deployment Verification");
        console2.log("===========================================\n");

        _verifyGovernanceToken(govProxy, timelockAddr, deployer);
        _verifyTimelock(timelockAddr, governorAddr, deployer);
        _verifyGovernor(governorAddr, govProxy, timelockAddr);
        _verifyFactory(factoryAddr, timelockAddr, deployer);
        _verifyPool(poolAddr);
        _verifyRWAToken(rwaProxy, deployer);

        console2.log("\n===========================================");
        console2.log(" Results: %s passed, %s failed", passCount, failCount);
        console2.log("===========================================");

        if (failCount > 0) {
            revert("Verification FAILED - see output above");
        }
    }

    // ── GovernanceToken ────────────────────────────────────────────────────────

    function _verifyGovernanceToken(address proxy, address timelock, address deployer) internal {
        console2.log("--- GovernanceToken (%s) ---", proxy);
        GovernanceToken gov = GovernanceToken(proxy);

        bytes32 DEFAULT_ADMIN = 0x00;
        bytes32 MINTER_ROLE   = gov.MINTER_ROLE();
        bytes32 UPGRADER_ROLE = gov.UPGRADER_ROLE();

        // Deployer must NOT be admin anymore
        _check(
            "Deployer has no DEFAULT_ADMIN_ROLE",
            !IAccessControl(proxy).hasRole(DEFAULT_ADMIN, deployer)
        );

        // Timelock must be admin
        _check(
            "Timelock holds DEFAULT_ADMIN_ROLE",
            IAccessControl(proxy).hasRole(DEFAULT_ADMIN, timelock)
        );

        // Timelock controls minting (or deployer still holds it pre-governance)
        bool timelockCanMint = IAccessControl(proxy).hasRole(MINTER_ROLE, timelock);
        bool deployerCanMint = IAccessControl(proxy).hasRole(MINTER_ROLE, deployer);
        _check(
            "MINTER_ROLE held by Timelock (not deployer)",
            timelockCanMint && !deployerCanMint
        );

        // Supply cap is 100M
        _check(
            "MAX_SUPPLY == 100_000_000 ether",
            gov.MAX_SUPPLY() == 100_000_000 ether
        );

        // Upgrader is Timelock
        _check(
            "UPGRADER_ROLE held by Timelock",
            IAccessControl(proxy).hasRole(UPGRADER_ROLE, timelock)
        );
    }

    // ── Timelock ───────────────────────────────────────────────────────────────

    function _verifyTimelock(address timelockAddr, address governor, address deployer) internal {
        console2.log("--- RWATimelock (%s) ---", timelockAddr);
        TimelockController tl = TimelockController(payable(timelockAddr));

        bytes32 DEFAULT_ADMIN   = 0x00;
        bytes32 PROPOSER_ROLE   = tl.PROPOSER_ROLE();
        bytes32 CANCELLER_ROLE  = tl.CANCELLER_ROLE();
        bytes32 EXECUTOR_ROLE   = tl.EXECUTOR_ROLE();

        // Minimum delay == 2 days
        _check(
            "Timelock min delay == 2 days",
            tl.getMinDelay() == EXPECTED_TIMELOCK_DELAY
        );

        // Governor is the only proposer
        _check(
            "Governor holds PROPOSER_ROLE",
            tl.hasRole(PROPOSER_ROLE, governor)
        );

        // Governor is the only canceller (or guardian multisig also holds it — that's fine)
        _check(
            "Governor holds CANCELLER_ROLE",
            tl.hasRole(CANCELLER_ROLE, governor)
        );

        // Executor is open (address(0) = anyone can execute after delay)
        _check(
            "EXECUTOR_ROLE held by address(0) (open execution)",
            tl.hasRole(EXECUTOR_ROLE, address(0))
        );

        // Deployer has no admin role
        _check(
            "Deployer has no DEFAULT_ADMIN_ROLE on Timelock",
            !tl.hasRole(DEFAULT_ADMIN, deployer)
        );
    }

    // ── Governor ───────────────────────────────────────────────────────────────

    function _verifyGovernor(address governorAddr, address govToken, address timelock) internal {
        console2.log("--- RWAGovernor (%s) ---", governorAddr);
        RWAGovernor gov = RWAGovernor(payable(governorAddr));

        _check(
            "Governor votingDelay == 1 day",
            gov.votingDelay() == EXPECTED_VOTING_DELAY
        );

        _check(
            "Governor votingPeriod == 1 week",
            gov.votingPeriod() == EXPECTED_VOTING_PERIOD
        );

        _check(
            "Governor proposalThreshold == 1000 RWAGOV",
            gov.proposalThreshold() == EXPECTED_PROPOSAL_THRESH
        );

        _check(
            "Governor quorumNumerator == 4",
            gov.quorumNumerator() == EXPECTED_QUORUM_NUMERATOR
        );

        _check(
            "Governor token == GovernanceToken proxy",
            address(gov.token()) == govToken
        );

        _check(
            "Governor timelock == RWATimelock",
            address(gov.timelock()) == timelock
        );
    }

    // ── RWAFactory ─────────────────────────────────────────────────────────────

    function _verifyFactory(address factoryAddr, address timelock, address deployer) internal {
        console2.log("--- RWAFactory (%s) ---", factoryAddr);

        bytes32 DEFAULT_ADMIN    = 0x00;
        bytes32 ONBOARDER_ROLE   = keccak256("ONBOARDER_ROLE");

        // Deployer should not be admin
        _check(
            "Deployer has no DEFAULT_ADMIN_ROLE on Factory",
            !IAccessControl(factoryAddr).hasRole(DEFAULT_ADMIN, deployer)
        );

        // Timelock controls onboarding
        _check(
            "Timelock holds ONBOARDER_ROLE",
            IAccessControl(factoryAddr).hasRole(ONBOARDER_ROLE, timelock)
        );
    }

    // ── RWAPool ────────────────────────────────────────────────────────────────

    function _verifyPool(address poolAddr) internal {
        console2.log("--- RWAPool (%s) ---", poolAddr);
        RWAPool pool = RWAPool(poolAddr);

        // Reserves are initialized (pool has been seeded)
        (uint256 r0, uint256 r1) = (pool.reserve0(), pool.reserve1());
        _check(
            "Pool is seeded (reserve0 > 0)",
            r0 > 0
        );
        _check(
            "Pool is seeded (reserve1 > 0)",
            r1 > 0
        );

        // k = reserve0 * reserve1 is non-zero
        _check(
            "Pool k-value is non-zero",
            r0 > 0 && r1 > 0
        );

        // Fee parameters
        _check(
            "Pool FEE_NUMERATOR == 3",
            pool.FEE_NUMERATOR() == 3
        );
        _check(
            "Pool FEE_DENOMINATOR == 1000",
            pool.FEE_DENOMINATOR() == 1000
        );
    }

    // ── RWAToken ───────────────────────────────────────────────────────────────

    function _verifyRWAToken(address proxy, address deployer) internal {
        console2.log("--- RWAToken proxy (%s) ---", proxy);

        bytes32 DEFAULT_ADMIN = 0x00;
        bytes32 PAUSER_ROLE   = keccak256("PAUSER_ROLE");
        bytes32 UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

        // Deployer should have no admin role on the token
        _check(
            "Deployer has no DEFAULT_ADMIN_ROLE on RWAToken",
            !IAccessControl(proxy).hasRole(DEFAULT_ADMIN, deployer)
        );

        // Token is not paused
        (bool success, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("paused()"));
        bool paused = success && abi.decode(data, (bool));
        _check("RWAToken is not paused", !paused);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _check(string memory label, bool condition) internal {
        if (condition) {
            console2.log("  [PASS] %s", label);
            passCount++;
        } else {
            console2.log("  [FAIL] %s", label);
            failCount++;
        }
    }
}
