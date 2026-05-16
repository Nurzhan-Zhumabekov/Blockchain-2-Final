// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable}                  from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1155Upgradeable}             from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {ERC1155PausableUpgradeable}     from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155PausableUpgradeable.sol";
import {ERC1155SupplyUpgradeable}       from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {AccessControlUpgradeable}       from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuard}                from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable}                from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract GameItems is
    Initializable,
    ERC1155Upgradeable,
    ERC1155PausableUpgradeable,
    ERC1155SupplyUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    bytes32 public constant MINTER_ROLE   = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant IRON_ORE      = 1;
    uint256 public constant COAL          = 2;
    uint256 public constant STEEL         = 3;
    uint256 public constant BASIC_SWORD   = 4;
    uint256 public constant RARE_SWORD    = 5;
    uint256 public constant MAGIC_CRYSTAL = 6;
    uint256 public constant HEALTH_POTION = 7;

    struct Recipe {
        uint256[] ingredientIds;
        uint256[] ingredientAmounts;
        uint256   resultId;
        uint256   resultAmount;
        bool      active;
    }

    mapping(uint256 => Recipe) private _recipes;
    uint256 public recipeCount;

    error ZeroAddress();
    error ZeroAmount();
    error RecipeNotFound(uint256 recipeId);
    error RecipeInactive(uint256 recipeId);
    error ArrayLengthMismatch();

    event RecipeAdded(uint256 indexed recipeId, uint256 resultId);
    event RecipeToggled(uint256 indexed recipeId, bool active);
    event ItemCrafted(address indexed crafter, uint256 indexed recipeId, uint256 resultId, uint256 resultAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, string memory uri_) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __ERC1155_init(uri_);
        __ERC1155Pausable_init();
        __ERC1155Supply_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE,        admin);
        _grantRole(PAUSER_ROLE,        admin);
        _grantRole(UPGRADER_ROLE,      admin);

        _addDefaultRecipes();
    }

    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        onlyRole(MINTER_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0)      revert ZeroAmount();
        _mint(to, id, amount, data);
    }

    function mintBatch(
        address           to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes     calldata data
    ) external onlyRole(MINTER_ROLE) {
        if (to == address(0))             revert ZeroAddress();
        if (ids.length != amounts.length) revert ArrayLengthMismatch();
        _mintBatch(to, ids, amounts, data);
    }

    function craft(uint256 recipeId) external nonReentrant whenNotPaused {
        Recipe storage recipe = _recipes[recipeId];
        if (recipe.resultId == 0) revert RecipeNotFound(recipeId);
        if (!recipe.active)       revert RecipeInactive(recipeId);

        uint256[] memory ids     = recipe.ingredientIds;
        uint256[] memory amounts = recipe.ingredientAmounts;

        assembly ("memory-safe") {
            if iszero(eq(mload(ids), mload(amounts))) {
                mstore(0x00, 0x7cd44272)
                revert(0x00, 0x04)
            }
        }

        uint256 resultId     = recipe.resultId;
        uint256 resultAmount = recipe.resultAmount;

        _burnBatch(msg.sender, ids, amounts);
        _mint(msg.sender, resultId, resultAmount, "");

        emit ItemCrafted(msg.sender, recipeId, resultId, resultAmount);
    }

    function addRecipe(
        uint256[] calldata ingredientIds,
        uint256[] calldata ingredientAmounts,
        uint256            resultId,
        uint256            resultAmount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 recipeId) {
        if (ingredientIds.length != ingredientAmounts.length) revert ArrayLengthMismatch();
        recipeId = ++recipeCount;
        _recipes[recipeId] = Recipe({
            ingredientIds:     ingredientIds,
            ingredientAmounts: ingredientAmounts,
            resultId:          resultId,
            resultAmount:      resultAmount,
            active:            true
        });
        emit RecipeAdded(recipeId, resultId);
    }

    function setRecipeActive(uint256 recipeId, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_recipes[recipeId].resultId == 0) revert RecipeNotFound(recipeId);
        _recipes[recipeId].active = active;
        emit RecipeToggled(recipeId, active);
    }

    function getRecipe(uint256 recipeId) external view returns (Recipe memory) {
        return _recipes[recipeId];
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function _update(
        address          from,
        address          to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155Upgradeable, ERC1155PausableUpgradeable, ERC1155SupplyUpgradeable) {
        super._update(from, to, ids, values);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _addDefaultRecipes() private {
        uint256[] memory ids1     = new uint256[](2);
        uint256[] memory amounts1 = new uint256[](2);
        ids1[0] = IRON_ORE; ids1[1] = COAL;
        amounts1[0] = 2;    amounts1[1] = 1;
        recipeCount = 1;
        _recipes[1] = Recipe(ids1, amounts1, STEEL, 1, true);
        emit RecipeAdded(1, STEEL);

        uint256[] memory ids2     = new uint256[](1);
        uint256[] memory amounts2 = new uint256[](1);
        ids2[0] = STEEL; amounts2[0] = 2;
        recipeCount = 2;
        _recipes[2] = Recipe(ids2, amounts2, BASIC_SWORD, 1, true);
        emit RecipeAdded(2, BASIC_SWORD);

        uint256[] memory ids3     = new uint256[](3);
        uint256[] memory amounts3 = new uint256[](3);
        ids3[0] = BASIC_SWORD; ids3[1] = STEEL; ids3[2] = MAGIC_CRYSTAL;
        amounts3[0] = 1;        amounts3[1] = 1;  amounts3[2] = 1;
        recipeCount = 3;
        _recipes[3] = Recipe(ids3, amounts3, RARE_SWORD, 1, true);
        emit RecipeAdded(3, RARE_SWORD);
    }
}
