// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Mirror} from "../src/Mirror.sol";
import {IMirror} from "../src/interfaces/IMirror.sol";
import {AntibodyLib} from "../src/libraries/Antibody.sol";

contract MirrorTest is Test {
    Mirror internal mirror;

    address internal admin = makeAddr("admin");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");
    address internal publisher = makeAddr("publisher");

    function setUp() public virtual {
        mirror = new Mirror(admin, relayer);
    }

    function _addressAntibody(address pub, bytes32 matcher) internal pure returns (AntibodyLib.Antibody memory a) {
        a.publisher = pub;
        a.primaryMatcherHash = matcher;
        a.abType = uint8(AntibodyLib.AntibodyType.ADDRESS);
        a.flavor = 0;
        a.verdict = uint8(AntibodyLib.Verdict.MALICIOUS);
        a.confidence = 90;
        a.severity = 80;
        a.status = uint8(AntibodyLib.Status.ACTIVE);
        a.createdAt = 1_700_000_000;
        a.expiresAt = 0;
    }
}

contract MirrorRoundTripTest is MirrorTest {
    function test_RoundTripAntibody() public {
        AntibodyLib.Antibody memory a = _addressAntibody(publisher, bytes32(uint256(0xdead)));
        a.evidenceCid = bytes32(uint256(0xc1d));
        a.contextHash = bytes32(uint256(0xc7c));
        a.embeddingHash = bytes32(uint256(0xe1b));
        a.attestation = bytes32(uint256(0xa11));
        a.reviewer = makeAddr("reviewer");
        a.stakeAmount = 1_000_000;
        a.stakeLockUntil = 2_000_000_000;
        a.expiresAt = 2_500_000_000;
        a.immSeq = 42;
        a.isSeeded = 1;

        bytes32 expectedId = AntibodyLib.computeKeccakId(a);
        vm.prank(relayer);
        mirror.mirrorAntibody(a, bytes32(0));

        AntibodyLib.Antibody memory got = mirror.getAntibody(expectedId);
        assertEq(got.publisher, a.publisher);
        assertEq(got.primaryMatcherHash, a.primaryMatcherHash);
        assertEq(got.evidenceCid, a.evidenceCid);
        assertEq(got.contextHash, a.contextHash);
        assertEq(got.embeddingHash, a.embeddingHash);
        assertEq(got.attestation, a.attestation);
        assertEq(got.reviewer, a.reviewer);
        assertEq(got.stakeAmount, a.stakeAmount);
        assertEq(got.stakeLockUntil, a.stakeLockUntil);
        assertEq(got.expiresAt, a.expiresAt);
        assertEq(got.immSeq, a.immSeq);
        assertEq(got.abType, a.abType);
        assertEq(got.flavor, a.flavor);
        assertEq(got.verdict, a.verdict);
        assertEq(got.confidence, a.confidence);
        assertEq(got.severity, a.severity);
        assertEq(got.status, a.status);
        assertEq(got.isSeeded, a.isSeeded);
        assertEq(got.createdAt, a.createdAt);
    }

    function test_KeccakIdMatchesRegistryAlgorithm() public pure {
        AntibodyLib.Antibody memory a;
        a.abType = 1;
        a.flavor = 2;
        a.primaryMatcherHash = bytes32(uint256(0x1234));
        a.publisher = address(0xBEEF);
        bytes32 expected = keccak256(abi.encode(uint8(1), uint8(2), bytes32(uint256(0x1234)), address(0xBEEF)));
        assertEq(AntibodyLib.computeKeccakId(a), expected);
    }

    function test_IdempotentOverwrite() public {
        AntibodyLib.Antibody memory a = _addressAntibody(publisher, bytes32(uint256(1)));
        a.severity = 50;
        bytes32 id = AntibodyLib.computeKeccakId(a);

        vm.prank(relayer);
        mirror.mirrorAntibody(a, bytes32(0));
        assertEq(mirror.getAntibody(id).severity, 50);

        a.severity = 95;
        vm.prank(relayer);
        mirror.mirrorAntibody(a, bytes32(0));
        assertEq(mirror.getAntibody(id).severity, 95, "second call overwrites");
    }

    function test_GetAntibodyReturnsZeroForUnknown() public view {
        AntibodyLib.Antibody memory got = mirror.getAntibody(bytes32(uint256(0xdead)));
        assertEq(got.publisher, address(0));
        assertEq(got.primaryMatcherHash, bytes32(0));
    }

    function testFuzz_RoundTripPreservesPackedFields(
        address pub,
        uint64 stakeLockUntil,
        uint32 immSeq,
        uint96 stakeAmount,
        bytes32 evidenceCid
    ) public {
        vm.assume(pub != address(0));
        AntibodyLib.Antibody memory a;
        a.publisher = pub;
        a.stakeLockUntil = stakeLockUntil;
        a.immSeq = immSeq;
        a.stakeAmount = stakeAmount;
        a.evidenceCid = evidenceCid;

        bytes32 id = AntibodyLib.computeKeccakId(a);
        vm.prank(relayer);
        mirror.mirrorAntibody(a, bytes32(0));

        AntibodyLib.Antibody memory got = mirror.getAntibody(id);
        assertEq(got.publisher, pub, "publisher truncated");
        assertEq(got.stakeLockUntil, stakeLockUntil, "stakeLockUntil truncated");
        assertEq(got.immSeq, immSeq, "immSeq truncated");
        assertEq(got.stakeAmount, stakeAmount, "stakeAmount truncated");
        assertEq(got.evidenceCid, evidenceCid, "evidenceCid mangled");
    }
}

contract MirrorAccessControlTest is MirrorTest {
    function test_ConstructorSetsAdminAndRelayer() public view {
        assertEq(mirror.admin(), admin, "admin");
        assertTrue(mirror.authorizedRelayers(relayer), "initial relayer authorized");
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(IMirror.ZeroAddress.selector);
        new Mirror(address(0), relayer);
        vm.expectRevert(IMirror.ZeroAddress.selector);
        new Mirror(admin, address(0));
    }

    function test_AdminCanAuthorizeRelayer() public {
        address newRelayer = makeAddr("newRelayer");
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit IMirror.RelayerSet(newRelayer, true);
        mirror.setRelayer(newRelayer, true);
        assertTrue(mirror.authorizedRelayers(newRelayer));
    }

    function test_AdminCanRevokeRelayer() public {
        vm.prank(admin);
        mirror.setRelayer(relayer, false);
        assertFalse(mirror.authorizedRelayers(relayer));
    }

    function test_NonAdminCannotSetRelayer() public {
        vm.prank(stranger);
        vm.expectRevert(IMirror.NotAdmin.selector);
        mirror.setRelayer(stranger, true);
    }

    function test_SetRelayerRejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IMirror.ZeroAddress.selector);
        mirror.setRelayer(address(0), true);
    }

    function test_AdminCanTransferAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IMirror.AdminTransferred(admin, newAdmin);
        mirror.transferAdmin(newAdmin);
        assertEq(mirror.admin(), newAdmin);
    }

    function test_TransferAdminRejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IMirror.ZeroAddress.selector);
        mirror.transferAdmin(address(0));
    }

    function test_NonAdminCannotTransferAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(IMirror.NotAdmin.selector);
        mirror.transferAdmin(stranger);
    }

    function test_NonRelayerCannotMirrorAntibody() public {
        AntibodyLib.Antibody memory a = _addressAntibody(publisher, bytes32(uint256(1)));
        vm.prank(stranger);
        vm.expectRevert(IMirror.NotRelayer.selector);
        mirror.mirrorAntibody(a, bytes32(0));
    }

    function test_NonRelayerCannotSetAddressBlock() public {
        vm.prank(stranger);
        vm.expectRevert(IMirror.NotRelayer.selector);
        mirror.setAddressBlock(makeAddr("bad"), bytes32(uint256(1)));
    }

    function test_NonRelayerCannotUnmirror() public {
        vm.prank(stranger);
        vm.expectRevert(IMirror.NotRelayer.selector);
        mirror.unmirrorAntibody(bytes32(uint256(1)));
    }

    function test_RevokedRelayerCannotWrite() public {
        vm.prank(admin);
        mirror.setRelayer(relayer, false);
        AntibodyLib.Antibody memory a = _addressAntibody(publisher, bytes32(uint256(1)));
        vm.prank(relayer);
        vm.expectRevert(IMirror.NotRelayer.selector);
        mirror.mirrorAntibody(a, bytes32(0));
    }
}
