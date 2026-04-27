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
