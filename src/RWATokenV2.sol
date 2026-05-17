// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RWAToken}             from "./RWAToken.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

// V1 → V2 upgrade path:
//   1. Deploy RWATokenV2 as a new implementation contract.
//   2. Admin calls proxy.upgradeToAndCall(
//          address(rwaTokenV2Impl),
//          abi.encodeCall(RWATokenV2.initializeV2, (reserveFeedAddress))
//      )
//   3. Subsequent issue() calls now enforce Chainlink Proof-of-Reserve before minting.
//
// Storage layout: V2 appends `reserveFeed` after all V1 slots — no collision possible.
contract RWATokenV2 is RWAToken {
    AggregatorV3Interface public reserveFeed;

    error ReserveDeficit(uint256 required, int256 reported);

    event ReserveFeedSet(address indexed feed);

    function initializeV2(address reserveFeed_) external reinitializer(2) {
        if (reserveFeed_ == address(0)) revert ZeroAddress();
        reserveFeed = AggregatorV3Interface(reserveFeed_);
        emit ReserveFeedSet(reserveFeed_);
    }

    // Overrides V1 issue() to add Proof-of-Reserve check before every mint.
    function issue(address to, uint256 amount)
        external
        override
        onlyRole(ISSUER_ROLE)
        whenNotPaused
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0)      revert ZeroAmount();
        _checkFreshPrice();
        _checkReserve(amount);
        _mint(to, amount);
        emit Issued(msg.sender, to, amount);
    }

    // Reverts if the Chainlink PoR feed reports less reserve than the post-mint supply.
    // Scales feed answer to 18 decimals before comparing with token supply.
    function _checkReserve(uint256 additionalAmount) internal view {
        if (address(reserveFeed) == address(0)) return;
        (, int256 reserveBalance, , uint256 updatedAt, ) = reserveFeed.latestRoundData();
        if (block.timestamp - updatedAt > STALENESS_THRESHOLD) revert StalePrice(updatedAt);
        if (reserveBalance < 0) revert ReserveDeficit(totalSupply() + additionalAmount, reserveBalance);
        uint8 feedDecimals = reserveFeed.decimals();
        uint256 reserveScaled = feedDecimals >= 18
            ? uint256(reserveBalance) / (10 ** (feedDecimals - 18))
            : uint256(reserveBalance) * (10 ** (18 - feedDecimals));
        uint256 required = totalSupply() + additionalAmount;
        if (reserveScaled < required)
            revert ReserveDeficit(required, reserveBalance);
    }
}
