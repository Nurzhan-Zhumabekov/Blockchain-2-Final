// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GameItems} from "./GameItems.sol";

// V1 -> V2 upgrade path:
//   1. Deploy GameItemsV2 as a new implementation contract.
//   2. Admin calls proxy.upgradeToAndCall(
//          address(gameItemsV2Impl),
//          abi.encodeCall(GameItemsV2.initializeV2, (lootboxAddress))
//      )
//   3. Proxy now delegates to V2; lootboxAddress is set and LOOTBOX_ROLE granted.
contract GameItemsV2 is GameItems {
    bytes32 public constant LOOTBOX_ROLE = keccak256("LOOTBOX_ROLE");

    uint256 public constant LEGENDARY_SWORD = 8;

    address public lootboxAddress;

    error LootboxAlreadySet();

    event LootboxSet(address indexed lootbox);

    function initializeV2(address lootbox) external reinitializer(2) {
        if (lootbox == address(0)) revert ZeroAddress();
        lootboxAddress = lootbox;
        _grantRole(LOOTBOX_ROLE, lootbox);
        emit LootboxSet(lootbox);
    }

    function mintLoot(
        address           to,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external onlyRole(LOOTBOX_ROLE) {
        if (to == address(0))             revert ZeroAddress();
        if (ids.length != amounts.length) revert ArrayLengthMismatch();
        _mintBatch(to, ids, amounts, "");
    }
}
