// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl}    from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1967Proxy}     from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RWAToken}         from "./RWAToken.sol";
import {RWAVault}         from "./RWAVault.sol";
import {AssetCertificate} from "./AssetCertificate.sol";

// Factory for onboarding new real-world assets onto the platform.
// Each onboarded asset gets its own RWAToken proxy + RWAVault proxy + a certificate NFT.
//
// CREATE  — used in the constructor to deploy the shared implementation contracts once.
// CREATE2 — used in onboardAsset() to deploy deterministic ERC-1967 proxies per salt.
contract RWAFactory is AccessControl {
    bytes32 public constant ONBOARDER_ROLE = keccak256("ONBOARDER_ROLE");

    address              public immutable tokenImpl;
    address              public immutable vaultImpl;
    AssetCertificate     public immutable certificate;

    struct AssetInstance {
        address tokenProxy;
        address vaultProxy;
        address issuer;
        uint256 deployedAt;
        uint256 certificateId;
    }

    mapping(bytes32 => AssetInstance) public assets;
    bytes32[] public allSalts;

    error ZeroAddress();
    error SaltAlreadyUsed(bytes32 salt);
    error DeployFailed();

    event AssetOnboarded(
        bytes32 indexed salt,
        address indexed tokenProxy,
        address indexed vaultProxy,
        address issuer,
        uint256 certificateId
    );

    constructor(address factoryAdmin) {
        if (factoryAdmin == address(0)) revert ZeroAddress();

        // CREATE: deploy shared implementations once
        tokenImpl   = address(new RWAToken());
        vaultImpl   = address(new RWAVault());
        // Deploy certificate with factory as initial admin so it can self-grant MINTER_ROLE
        certificate = new AssetCertificate(address(this));

        _grantRole(DEFAULT_ADMIN_ROLE, factoryAdmin);
        _grantRole(ONBOARDER_ROLE,     factoryAdmin);

        // Grant factoryAdmin DEFAULT_ADMIN_ROLE on certificate so they can manage it
        certificate.grantRole(certificate.DEFAULT_ADMIN_ROLE(), factoryAdmin);
        certificate.grantRole(certificate.MINTER_ROLE(),        factoryAdmin);
    }

    // Onboard a new real-world asset: deploys proxies + mints a certificate NFT to the issuer.
    function onboardAsset(
        bytes32         salt,
        address         issuer,
        string calldata name_,
        string calldata symbol_,
        string calldata assetType_,
        address         priceFeed_
    ) external onlyRole(ONBOARDER_ROLE) returns (address tokenProxy, address vaultProxy) {
        if (issuer == address(0))          revert ZeroAddress();
        if (assets[salt].deployedAt != 0)  revert SaltAlreadyUsed(salt);

        // CREATE2: RWAToken proxy
        bytes memory tokenInit = abi.encodeCall(
            RWAToken.initialize,
            (issuer, name_, symbol_, assetType_, priceFeed_)
        );
        tokenProxy = _deployProxy(tokenImpl, tokenInit, salt);

        // CREATE2: RWAVault proxy (derived salt prevents collision with token proxy)
        bytes32 vaultSalt = keccak256(abi.encode(salt, "vault"));
        bytes memory vaultInit = abi.encodeCall(RWAVault.initialize, (issuer, tokenProxy));
        vaultProxy = _deployProxy(vaultImpl, vaultInit, vaultSalt);

        uint256 certId = certificate.mint(issuer, tokenProxy, assetType_);

        assets[salt] = AssetInstance({
            tokenProxy:    tokenProxy,
            vaultProxy:    vaultProxy,
            issuer:        issuer,
            deployedAt:    block.timestamp,
            certificateId: certId
        });
        allSalts.push(salt);

        emit AssetOnboarded(salt, tokenProxy, vaultProxy, issuer, certId);
    }

    // Predict the CREATE2 address of a proxy without deploying it.
    // Uses inline Yul — benchmarked against the pure-Solidity equivalent below.
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

    // Pure-Solidity equivalent — used in gas benchmarks to quantify Yul savings.
    function predictProxyAddressSolidity(bytes32 salt, bytes32 creationCodeHash)
        public
        view
        returns (address)
    {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, creationCodeHash)
        ))));
    }

    function predictAssetAddresses(bytes32 salt)
        external
        view
        returns (address tokenProxy, address vaultProxy)
    {
        bytes32 tokenHash = keccak256(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(tokenImpl, ""))
        );
        bytes32 vaultHash = keccak256(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(vaultImpl, ""))
        );
        tokenProxy = predictProxyAddress(salt, tokenHash);
        vaultProxy = predictProxyAddress(keccak256(abi.encode(salt, "vault")), vaultHash);
    }

    function assetCount() external view returns (uint256) { return allSalts.length; }

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
