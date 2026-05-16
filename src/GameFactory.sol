// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl}  from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1967Proxy}   from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GameToken}      from "./GameToken.sol";
import {GameItems}      from "./GameItems.sol";

contract GameFactory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    address public immutable tokenImpl;
    address public immutable itemsImpl;

    struct GameInstance {
        address tokenProxy;
        address itemsProxy;
        address admin;
        uint256 deployedAt;
    }

    mapping(bytes32 => GameInstance) public instances;
    bytes32[] public allSalts;

    error ZeroAddress();
    error SaltAlreadyUsed(bytes32 salt);
    error DeployFailed();

    event InstanceDeployed(
        bytes32 indexed salt,
        address indexed tokenProxy,
        address indexed itemsProxy,
        address admin
    );

    constructor(address factoryAdmin) {
        if (factoryAdmin == address(0)) revert ZeroAddress();

        tokenImpl = address(new GameToken());
        itemsImpl = address(new GameItems());

        _grantRole(DEFAULT_ADMIN_ROLE, factoryAdmin);
        _grantRole(DEPLOYER_ROLE,      factoryAdmin);
    }

    function deployInstance(
        bytes32        salt,
        address        gameAdmin,
        string calldata itemsUri
    ) external onlyRole(DEPLOYER_ROLE) returns (address tokenProxy, address itemsProxy) {
        if (gameAdmin == address(0))         revert ZeroAddress();
        if (instances[salt].deployedAt != 0) revert SaltAlreadyUsed(salt);

        bytes memory tokenInit = abi.encodeCall(GameToken.initialize, (gameAdmin));
        tokenProxy = _deployProxy(tokenImpl, tokenInit, salt);

        bytes32 itemsSalt = keccak256(abi.encode(salt, "items"));
        bytes memory itemsInit = abi.encodeCall(GameItems.initialize, (gameAdmin, itemsUri));
        itemsProxy = _deployProxy(itemsImpl, itemsInit, itemsSalt);

        instances[salt] = GameInstance({
            tokenProxy: tokenProxy,
            itemsProxy: itemsProxy,
            admin:      gameAdmin,
            deployedAt: block.timestamp
        });
        allSalts.push(salt);

        emit InstanceDeployed(salt, tokenProxy, itemsProxy, gameAdmin);
    }

    function predictProxyAddress(bytes32 salt, bytes32 creationCodeHash)
        public
        view
        returns (address predicted)
    {
        assembly {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 0x60))

            mstore8(ptr, 0xff)
            mstore(add(ptr, 0x01), shl(0x60, address()))
            mstore(add(ptr, 0x15), salt)
            mstore(add(ptr, 0x35), creationCodeHash)

            predicted := and(
                keccak256(ptr, 0x55),
                0xffffffffffffffffffffffffffffffffffffffff
            )
        }
    }

    function predictInstanceAddresses(bytes32 salt)
        external
        view
        returns (address tokenProxy, address itemsProxy)
    {
        bytes32 tokenCreationHash = keccak256(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(tokenImpl, ""))
        );
        bytes32 itemsCreationHash = keccak256(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(itemsImpl, ""))
        );

        tokenProxy = predictProxyAddress(salt, tokenCreationHash);
        itemsProxy = predictProxyAddress(keccak256(abi.encode(salt, "items")), itemsCreationHash);
    }

    function instanceCount() external view returns (uint256) {
        return allSalts.length;
    }

    function _deployProxy(address impl, bytes memory initData, bytes32 salt)
        private
        returns (address proxy)
    {
        bytes memory bytecode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(impl, initData)
        );

        assembly {
            proxy := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(proxy) {
                mstore(0x00, 0x30116425)
                revert(0x00, 0x04)
            }
        }
    }
}
