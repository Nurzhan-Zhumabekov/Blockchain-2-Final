// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable}           from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PausableUpgradeable}   from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AggregatorV3Interface}      from "./interfaces/AggregatorV3Interface.sol";

// ERC-20 asset-backed token representing real-world collateral.
// V1: price-feed staleness guard on every issuance.
// V2: adds Chainlink Proof-of-Reserve check (see RWATokenV2.sol).
contract RWAToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ISSUER_ROLE   = keccak256("ISSUER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant STALENESS_THRESHOLD = 24 hours;

    AggregatorV3Interface public priceFeed;
    string  public assetType;
    uint256 public totalCollateral;

    error ZeroAddress();
    error ZeroAmount();
    error StalePrice(uint256 updatedAt);

    event Issued(address indexed issuer, address indexed to, uint256 amount);
    event Redeemed(address indexed from, uint256 amount);
    event CollateralUpdated(uint256 oldAmount, uint256 newAmount);
    event PriceFeedUpdated(address indexed oldFeed, address indexed newFeed);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address        admin,
        string  memory name_,
        string  memory symbol_,
        string  memory assetType_,
        address        priceFeed_
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC20Pausable_init();
        __AccessControl_init();

        assetType = assetType_;
        if (priceFeed_ != address(0)) {
            priceFeed = AggregatorV3Interface(priceFeed_);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ISSUER_ROLE,        admin);
        _grantRole(PAUSER_ROLE,        admin);
        _grantRole(UPGRADER_ROLE,      admin);
    }

    // Mint RWA tokens — authorized issuers only.
    function issue(address to, uint256 amount) external virtual onlyRole(ISSUER_ROLE) whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0)      revert ZeroAmount();
        _checkFreshPrice();
        _mint(to, amount);
        emit Issued(msg.sender, to, amount);
    }

    // Burn RWA tokens to redeem underlying collateral off-chain.
    function redeem(uint256 amount) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, amount);
        emit Redeemed(msg.sender, amount);
    }

    // Issuer updates the reported collateral value (scaled 1e8, same as Chainlink).
    function updateCollateral(uint256 newCollateral) external onlyRole(ISSUER_ROLE) {
        emit CollateralUpdated(totalCollateral, newCollateral);
        totalCollateral = newCollateral;
    }

    // Governance-controlled feed replacement.
    function setPriceFeed(address newFeed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit PriceFeedUpdated(address(priceFeed), newFeed);
        priceFeed = AggregatorV3Interface(newFeed);
    }

    // Returns latest price; reverts if stale.
    function latestPrice() public view returns (int256 price, uint256 updatedAt) {
        (, price, , updatedAt, ) = priceFeed.latestRoundData();
        if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert StalePrice(updatedAt);
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        super._update(from, to, value);
    }

    function _authorizeUpgrade(address)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    function _checkFreshPrice() internal view {
        if (address(priceFeed) == address(0)) return;
        (, , , uint256 updatedAt, ) = priceFeed.latestRoundData();
        if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert StalePrice(updatedAt);
    }
}
