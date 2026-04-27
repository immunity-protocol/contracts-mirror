// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Mirror} from "../src/Mirror.sol";

/// @notice CREATE2-deploys the Mirror contract with a hardcoded salt so
///         that a given (admin, initialRelayer) pair lands at the same
///         address on every chain. Operator captures the address from
///         stdout and writes it into network.json.
///
/// @dev    Required env vars:
///           MIRROR_ADMIN            — admin address (multi-sig in v2)
///           MIRROR_INITIAL_RELAYER  — first relayer authorized at deploy
contract DeployMirror is Script {
    bytes32 internal constant SALT = keccak256("immunity.mirror.v1");

    function run() external returns (Mirror mirror) {
        address admin = vm.envAddress("MIRROR_ADMIN");
        address relayer = vm.envAddress("MIRROR_INITIAL_RELAYER");

        vm.startBroadcast();
        mirror = new Mirror{salt: SALT}(admin, relayer);
        vm.stopBroadcast();

        console2.log("chainId:        ", block.chainid);
        console2.log("Mirror address: ", address(mirror));
        console2.log("admin:          ", admin);
        console2.log("initialRelayer: ", relayer);
    }
}
