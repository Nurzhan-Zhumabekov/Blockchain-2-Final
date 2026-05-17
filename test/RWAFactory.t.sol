// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}      from "forge-std/Test.sol";
import {RWAFactory}          from "../src/RWAFactory.sol";
import {RWAToken}            from "../src/RWAToken.sol";
import {RWAVault}            from "../src/RWAVault.sol";
import {AssetCertificate}    from "../src/AssetCertificate.sol";
import {ERC1967Proxy}        from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockFeed}            from "./MockFeed.sol";

contract RWAFactoryTest is Test {
    RWAFactory       factory;
    MockFeed         feed;

    address admin   = address(0xC1);
    address issuer  = address(0xC2);
    address other   = address(0xC3);

    bytes32 constant ONBOARDER_ROLE = keccak256("ONBOARDER_ROLE");
    bytes32 constant ISSUER_ROLE    = keccak256("ISSUER_ROLE");

    bytes32 salt1 = keccak256("asset.v1");
    bytes32 salt2 = keccak256("asset.v2");

    function setUp() public {
        feed    = new MockFeed(1e8);
        factory = new RWAFactory(admin);
    }

    // --- Initialization ---

    function test_Constructor_DeploysTokenImpl() public view {
        assertTrue(factory.tokenImpl() != address(0));
    }

    function test_Constructor_DeploysVaultImpl() public view {
        assertTrue(factory.vaultImpl() != address(0));
    }

    function test_Constructor_DeploysCertificate() public view {
        assertTrue(address(factory.certificate()) != address(0));
    }

    function test_Constructor_AdminHasOnboarderRole() public view {
        assertTrue(factory.hasRole(ONBOARDER_ROLE, admin));
    }

    // --- onboardAsset ---

    function test_OnboardAsset_DeploysTokenProxy() public {
        vm.prank(admin);
        (address tokenProxy, ) = factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));
        assertTrue(tokenProxy != address(0));
        assertEq(RWAToken(tokenProxy).name(), "Bond Token");
    }

    function test_OnboardAsset_DeploysVaultProxy() public {
        vm.prank(admin);
        (, address vaultProxy) = factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));
        assertTrue(vaultProxy != address(0));
        assertEq(RWAVault(vaultProxy).name(), "RWA Vault Shares");
    }

    function test_OnboardAsset_MintsCertificateNFT() public {
        vm.prank(admin);
        factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));
        AssetCertificate cert = factory.certificate();
        assertEq(cert.balanceOf(issuer), 1);
    }

    function test_OnboardAsset_StoresAssetInstance() public {
        vm.prank(admin);
        (address tp, address vp) = factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));

        (address storedToken, address storedVault, address storedIssuer, uint256 deployedAt, ) = factory.assets(salt1);
        assertEq(storedToken,  tp);
        assertEq(storedVault,  vp);
        assertEq(storedIssuer, issuer);
        assertGt(deployedAt, 0);
    }

    function test_OnboardAsset_EmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(factory));
        emit RWAFactory.AssetOnboarded(salt1, address(0), address(0), issuer, 0);
        factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));
    }

    function test_OnboardAsset_RevertsOnDuplicateSalt() public {
        vm.prank(admin);
        factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RWAFactory.SaltAlreadyUsed.selector, salt1));
        factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));
    }

    function test_OnboardAsset_RevertsIfNotOnboarder() public {
        vm.prank(other);
        vm.expectRevert();
        factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));
    }

    function test_OnboardAsset_RevertsIfZeroIssuer() public {
        vm.prank(admin);
        vm.expectRevert(RWAFactory.ZeroAddress.selector);
        factory.onboardAsset(salt1, address(0), "Bond Token", "BOND", "US-TREASURY", address(feed));
    }

    function test_OnboardAsset_IncreasesCount() public {
        assertEq(factory.assetCount(), 0);
        vm.prank(admin);
        factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));
        assertEq(factory.assetCount(), 1);
        vm.prank(admin);
        factory.onboardAsset(salt2, issuer, "Gold Token", "GOLD", "COMMODITY", address(feed));
        assertEq(factory.assetCount(), 2);
    }

    // --- CREATE2 determinism ---

    function test_PredictAddresses_IsDeterministic() public view {
        // predictAssetAddresses uses empty init data for the hash — two calls with same salt
        // must return identical addresses, proving the Yul computation is deterministic.
        (address t1, address v1) = factory.predictAssetAddresses(salt1);
        (address t2, address v2) = factory.predictAssetAddresses(salt1);
        assertEq(t1, t2);
        assertEq(v1, v2);
        assertTrue(t1 != address(0));
        assertTrue(v1 != address(0));
        assertTrue(t1 != v1); // different salts → different addresses
    }

    // --- predictProxyAddress vs predictProxyAddressSolidity ---

    function test_PredictProxy_YulMatchesSolidity() public view {
        bytes32 codeHash = keccak256(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(factory.tokenImpl(), ""))
        );
        address yul     = factory.predictProxyAddress(salt1, codeHash);
        address solidity = factory.predictProxyAddressSolidity(salt1, codeHash);
        assertEq(yul, solidity);
    }

    function testFuzz_PredictProxy_YulMatchesSolidity(bytes32 fuzzSalt, bytes32 codeHash) public view {
        address yul     = factory.predictProxyAddress(fuzzSalt, codeHash);
        address solidity = factory.predictProxyAddressSolidity(fuzzSalt, codeHash);
        assertEq(yul, solidity);
    }

    // --- AssetCertificate: soulbound ---

    function test_Certificate_Soulbound() public {
        vm.prank(admin);
        factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));
        AssetCertificate cert = factory.certificate();
        uint256 tokenId = 0;

        vm.prank(issuer);
        vm.expectRevert(AssetCertificate.Soulbound.selector);
        cert.transferFrom(issuer, other, tokenId);
    }

    function test_Certificate_StoresData() public {
        vm.prank(admin);
        (address tp, ) = factory.onboardAsset(salt1, issuer, "Bond Token", "BOND", "US-TREASURY", address(feed));
        AssetCertificate cert = factory.certificate();

        (address storedToken, string memory storedType, uint256 issuedAt, ) = cert.certificates(0);
        assertEq(storedToken, tp);
        assertEq(storedType, "US-TREASURY");
        assertGt(issuedAt, 0);
    }
}
