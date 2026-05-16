// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVRFCoordinatorV2} from "./interfaces/IVRFCoordinatorV2.sol";
import {GameItemsV2}     from "./GameItemsV2.sol";

abstract contract VRFConsumerBaseV2 {
    error OnlyCoordinatorCanFulfill(address have, address want);
    address private immutable _vrfCoordinator;

    constructor(address vrfCoordinator_) {
        _vrfCoordinator = vrfCoordinator_;
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        if (msg.sender != _vrfCoordinator)
            revert OnlyCoordinatorCanFulfill(msg.sender, _vrfCoordinator);
        fulfillRandomWords(requestId, randomWords);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal virtual;
}

contract LootBox is VRFConsumerBaseV2, ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    IVRFCoordinatorV2 public immutable coordinator;
    GameItemsV2       public immutable gameItems;
    IERC20            public immutable gameToken;

    bytes32 public keyHash;
    uint64  public subscriptionId;
    uint32  public callbackGasLimit;
    uint16  public constant MIN_CONFIRMATIONS = 3;
    uint32  public constant NUM_WORDS         = 1;

    uint256 public lootPrice;

    mapping(uint256 => address) private _requestToPlayer;

    // Item IDs from GameItems
    uint256 private constant IRON_ORE       = 1;
    uint256 private constant COAL           = 2;
    uint256 private constant STEEL          = 3;
    uint256 private constant HEALTH_POTION  = 7;
    uint256 private constant MAGIC_CRYSTAL  = 6;
    uint256 private constant LEGENDARY_SWORD = 8;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidPrice();

    event LootRequested(address indexed player, uint256 indexed requestId);
    event LootFulfilled(address indexed player, uint256 indexed requestId, uint256 itemId, uint256 amount);
    event LootPriceUpdated(uint256 newPrice);

    constructor(
        address _coordinator,
        address _gameItems,
        address _gameToken,
        bytes32 _keyHash,
        uint64  _subscriptionId,
        uint32  _callbackGasLimit,
        uint256 _lootPrice,
        address admin
    ) VRFConsumerBaseV2(_coordinator) {
        if (_coordinator == address(0) || _gameItems == address(0) ||
            _gameToken  == address(0) || admin == address(0)) revert ZeroAddress();
        if (_lootPrice == 0) revert InvalidPrice();

        coordinator      = IVRFCoordinatorV2(_coordinator);
        gameItems        = GameItemsV2(_gameItems);
        gameToken        = IERC20(_gameToken);
        keyHash          = _keyHash;
        subscriptionId   = _subscriptionId;
        callbackGasLimit = _callbackGasLimit;
        lootPrice        = _lootPrice;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER_ROLE,       admin);
    }

    function requestLoot() external nonReentrant returns (uint256 requestId) {
        gameToken.safeTransferFrom(msg.sender, address(this), lootPrice);

        requestId = coordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            MIN_CONFIRMATIONS,
            callbackGasLimit,
            NUM_WORDS
        );

        _requestToPlayer[requestId] = msg.sender;
        emit LootRequested(msg.sender, requestId);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        address player = _requestToPlayer[requestId];
        if (player == address(0)) return;
        delete _requestToPlayer[requestId];

        uint256 roll = randomWords[0] % 100;

        uint256 itemId;
        uint256 amount = 1;

        if      (roll < 40) { itemId = IRON_ORE;        amount = 3; }
        else if (roll < 65) { itemId = COAL;             amount = 2; }
        else if (roll < 80) { itemId = STEEL;            amount = 1; }
        else if (roll < 93) { itemId = HEALTH_POTION;   amount = 1; }
        else if (roll < 99) { itemId = MAGIC_CRYSTAL;   amount = 1; }
        else                { itemId = LEGENDARY_SWORD; amount = 1; }

        uint256[] memory ids     = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0]     = itemId;
        amounts[0] = amount;

        gameItems.mintLoot(player, ids, amounts);
        emit LootFulfilled(player, requestId, itemId, amount);
    }

    function setLootPrice(uint256 newPrice) external onlyRole(MANAGER_ROLE) {
        if (newPrice == 0) revert InvalidPrice();
        lootPrice = newPrice;
        emit LootPriceUpdated(newPrice);
    }

    function withdrawTokens(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        gameToken.safeTransfer(to, amount);
    }
}
