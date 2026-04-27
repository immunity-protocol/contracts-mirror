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

contract MirrorAuxiliaryEventTest is MirrorTest {
    function _typedAntibody(uint8 abType, uint8 flavor) internal view returns (AntibodyLib.Antibody memory a) {
        a = _addressAntibody(publisher, bytes32(uint256(0xfeed)));
        a.abType = abType;
        a.flavor = flavor;
    }

    function test_AddressType_EmitsAddressBlocked() public {
        AntibodyLib.Antibody memory a = _typedAntibody(uint8(AntibodyLib.AntibodyType.ADDRESS), 0);
        bytes32 id = AntibodyLib.computeKeccakId(a);
        address target = makeAddr("target");
        bytes32 auxKey = bytes32(uint256(uint160(target)));

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit IMirror.AddressBlocked(target, id, publisher);
        mirror.mirrorAntibody(a, auxKey);
    }

    function test_CallPatternType_EmitsCallPatternBlocked() public {
        AntibodyLib.Antibody memory a = _typedAntibody(uint8(AntibodyLib.AntibodyType.CALL_PATTERN), 0);
        bytes32 id = AntibodyLib.computeKeccakId(a);
        bytes4 selector = 0xdeadbeef;
        bytes32 auxKey = bytes32(selector);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit IMirror.CallPatternBlocked(selector, id, publisher);
        mirror.mirrorAntibody(a, auxKey);
    }

    function test_BytecodeType_EmitsBytecodeBlocked() public {
        AntibodyLib.Antibody memory a = _typedAntibody(uint8(AntibodyLib.AntibodyType.BYTECODE), 0);
        bytes32 id = AntibodyLib.computeKeccakId(a);
        bytes32 bytecodeHash = keccak256("evil-runtime");

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit IMirror.BytecodeBlocked(bytecodeHash, id, publisher);
        mirror.mirrorAntibody(a, bytecodeHash);
    }

    function test_GraphType_EmitsGraphTaintAdded() public {
        AntibodyLib.Antibody memory a = _typedAntibody(uint8(AntibodyLib.AntibodyType.GRAPH), 0);
        bytes32 id = AntibodyLib.computeKeccakId(a);
        bytes32 taintSetId = keccak256("graph-cluster-7");

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit IMirror.GraphTaintAdded(taintSetId, id, publisher);
        mirror.mirrorAntibody(a, taintSetId);
    }

    function test_SemanticType_EmitsSemanticPatternAddedWithFlavor() public {
        uint8 flavor = 7;
        AntibodyLib.Antibody memory a = _typedAntibody(uint8(AntibodyLib.AntibodyType.SEMANTIC), flavor);
        bytes32 id = AntibodyLib.computeKeccakId(a);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        // auxiliaryKey is unused for SEMANTIC; emitted indexed key is `flavor`.
        emit IMirror.SemanticPatternAdded(flavor, id, publisher);
        mirror.mirrorAntibody(a, bytes32(0));
    }

    function test_AlwaysEmitsAntibodyMirrored() public {
        AntibodyLib.Antibody memory a = _typedAntibody(uint8(AntibodyLib.AntibodyType.GRAPH), 3);
        bytes32 id = AntibodyLib.computeKeccakId(a);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, false);
        emit IMirror.AntibodyMirrored(id, publisher, uint8(AntibodyLib.AntibodyType.GRAPH));
        mirror.mirrorAntibody(a, bytes32(uint256(1)));
    }
}

contract MirrorAddressIndexTest is MirrorTest {
    address internal targetA = makeAddr("targetA");

    function _mirror(bytes32 matcher) internal returns (bytes32 id, AntibodyLib.Antibody memory a) {
        a = _addressAntibody(publisher, matcher);
        id = AntibodyLib.computeKeccakId(a);
        vm.prank(relayer);
        mirror.mirrorAntibody(a, bytes32(uint256(uint160(targetA))));
    }

    function test_SetAddressBlock_Writes() public {
        (bytes32 id,) = _mirror(bytes32(uint256(1)));
        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit IMirror.AddressBlocked(targetA, id, publisher);
        mirror.setAddressBlock(targetA, id);
        assertEq(mirror.isBlocked(targetA), id);
    }

    function test_SetAddressBlock_LastWriteWins() public {
        (bytes32 idA,) = _mirror(bytes32(uint256(1)));
        (bytes32 idB,) = _mirror(bytes32(uint256(2)));
        assertTrue(idA != idB);
        vm.startPrank(relayer);
        mirror.setAddressBlock(targetA, idA);
        mirror.setAddressBlock(targetA, idB);
        vm.stopPrank();
        assertEq(mirror.isBlocked(targetA), idB);
    }

    function test_SetAddressBlock_Clears() public {
        (bytes32 id,) = _mirror(bytes32(uint256(1)));
        vm.prank(relayer);
        mirror.setAddressBlock(targetA, id);
        assertEq(mirror.isBlocked(targetA), id);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit IMirror.AddressBlocked(targetA, bytes32(0), address(0));
        mirror.setAddressBlock(targetA, bytes32(0));
        assertEq(mirror.isBlocked(targetA), bytes32(0));
    }

    function test_SetAddressBlock_RevertsIfAntibodyNotMirrored() public {
        bytes32 unknownId = keccak256("not-yet-mirrored");
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IMirror.AntibodyNotMirrored.selector, unknownId));
        mirror.setAddressBlock(targetA, unknownId);
    }

    function test_SetAddressBlock_RevertsOnZeroTarget() public {
        vm.prank(relayer);
        vm.expectRevert(IMirror.ZeroAddress.selector);
        mirror.setAddressBlock(address(0), bytes32(uint256(1)));
    }

    function test_IsBlockedReturnsZeroForUnknownAddress() public {
        assertEq(mirror.isBlocked(makeAddr("never-blocked")), bytes32(0));
    }

    function test_MirrorAddressAntibody_OneTxSetsIndexAndEmits() public {
        AntibodyLib.Antibody memory a = _addressAntibody(publisher, bytes32(uint256(0xface)));
        bytes32 id = AntibodyLib.computeKeccakId(a);

        vm.prank(relayer);
        // Expect AntibodyMirrored followed by AddressBlocked — exactly two log entries
        vm.expectEmit(true, true, true, true);
        emit IMirror.AntibodyMirrored(id, publisher, a.abType);
        vm.expectEmit(true, true, true, true);
        emit IMirror.AddressBlocked(targetA, id, publisher);
        mirror.mirrorAddressAntibody(a, targetA);

        assertEq(mirror.isBlocked(targetA), id);
        assertEq(mirror.getAntibody(id).publisher, publisher);
    }

    function test_MirrorAddressAntibody_RevertsOnZeroTarget() public {
        AntibodyLib.Antibody memory a = _addressAntibody(publisher, bytes32(uint256(1)));
        vm.prank(relayer);
        vm.expectRevert(IMirror.ZeroAddress.selector);
        mirror.mirrorAddressAntibody(a, address(0));
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
