// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";

// Synthetix-style staking rewards contract for the RWA Tokenization Platform.
//
// Stakers lock RWAGOV and earn RWAToken rewards distributed by the DAO.
// Reward rate is set by REWARDS_MANAGER (typically the Timelock/Governor).
//
// Reward math:
//   rewardPerToken accumulates linearly per second proportional to totalStaked.
//   Each user's earned() = balance * (rewardPerToken - userRewardPerTokenPaid) + accrued.
//
// Invariant: sum of earned() across all users <= rewardBalance held by this contract.
contract RWAStaking is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant REWARDS_MANAGER = keccak256("REWARDS_MANAGER");
    bytes32 public constant PAUSER_ROLE     = keccak256("PAUSER_ROLE");

    IERC20 public immutable stakingToken;  // RWAGOV
    IERC20 public immutable rewardToken;   // RWAToken (or any ERC-20)

    uint256 public rewardRate;             // reward tokens per second (scaled 1e18)
    uint256 public periodFinish;           // timestamp when current reward period ends
    uint256 public rewardsDuration;        // length of each reward period in seconds
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public balanceOf;

    uint256 public totalSupply;

    error ZeroAmount();
    error ZeroAddress();
    error RewardTooHigh();
    error DurationNotSet();

    event Staked        (address indexed user, uint256 amount);
    event Withdrawn     (address indexed user, uint256 amount);
    event RewardPaid    (address indexed user, uint256 reward);
    event RewardAdded   (uint256 reward, uint256 newRate, uint256 periodFinish);
    event DurationSet   (uint256 newDuration);

    constructor(
        address _stakingToken,
        address _rewardToken,
        address admin,
        uint256 _rewardsDuration
    ) {
        if (_stakingToken == address(0) || _rewardToken == address(0) || admin == address(0))
            revert ZeroAddress();
        if (_rewardsDuration == 0) revert ZeroAmount();

        stakingToken     = IERC20(_stakingToken);
        rewardToken      = IERC20(_rewardToken);
        rewardsDuration  = _rewardsDuration;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REWARDS_MANAGER,    admin);
        _grantRole(PAUSER_ROLE,        admin);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18)
            / totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18
            + rewards[account];
    }

    // ─── Staker actions ───────────────────────────────────────────────────────

    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        totalSupply         += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        totalSupply           -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function claimReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(balanceOf[msg.sender]);
        claimReward();
    }

    // ─── Manager actions ──────────────────────────────────────────────────────

    // DAO deposits reward tokens and sets the emission rate for a new period.
    // Called after transferring `reward` tokens to this contract.
    function notifyRewardAmount(uint256 reward)
        external
        onlyRole(REWARDS_MANAGER)
        updateReward(address(0))
    {
        if (rewardsDuration == 0) revert DurationNotSet();

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining   = periodFinish - block.timestamp;
            uint256 leftover    = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        // Safety: ensure contract holds enough reward tokens
        uint256 balance = rewardToken.balanceOf(address(this));
        if (rewardRate > balance / rewardsDuration) revert RewardTooHigh();

        lastUpdateTime = block.timestamp;
        periodFinish   = block.timestamp + rewardsDuration;

        emit RewardAdded(reward, rewardRate, periodFinish);
    }

    function setRewardsDuration(uint256 _duration)
        external
        onlyRole(REWARDS_MANAGER)
    {
        if (_duration == 0) revert ZeroAmount();
        rewardsDuration = _duration;
        emit DurationSet(_duration);
    }

    // Recover accidentally sent ERC-20 tokens (not the staking or reward token).
    function recoverERC20(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(stakingToken) && token != address(rewardToken));
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ─── Modifier ─────────────────────────────────────────────────────────────

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime       = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account]              = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }
}
