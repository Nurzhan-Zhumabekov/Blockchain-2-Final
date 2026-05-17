// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721}        from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

// Soulbound ERC-721 certificate minted when an issuer onboards a new RWA.
// One certificate per deployed RWAToken instance; non-transferable after mint.
contract AssetCertificate is ERC721, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint256 private _nextTokenId;

    struct CertificateData {
        address rwaToken;
        string  assetType;
        uint256 issuedAt;
        address issuer;
    }

    mapping(uint256 => CertificateData) public certificates;

    error ZeroAddress();
    error Soulbound();

    event CertificateMinted(uint256 indexed tokenId, address indexed rwaToken, address indexed issuer);

    constructor(address admin) ERC721("RWA Asset Certificate", "RWACERT") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE,        admin);
    }

    function mint(
        address        to,
        address        rwaToken,
        string calldata assetType
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        if (to == address(0) || rwaToken == address(0)) revert ZeroAddress();
        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        certificates[tokenId] = CertificateData({
            rwaToken:  rwaToken,
            assetType: assetType,
            issuedAt:  block.timestamp,
            issuer:    to
        });
        emit CertificateMinted(tokenId, rwaToken, to);
    }

    // Non-transferable: certificates stay with the original issuer.
    function transferFrom(address, address, uint256) public pure override {
        revert Soulbound();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
