// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Mirror} from "../src/Mirror.sol";
import {ImmunityHook} from "../src/ImmunityHook.sol";
import {IMirror} from "../src/interfaces/IMirror.sol";

/// @notice Single-RPC convenience runner: deploys Mirror via CREATE2,
///         then mines the hook salt and deploys ImmunityHook against
///         the just-deployed Mirror and the per-chain PoolManager.
///         Operator iterates RPCs from a shell wrapper.
///
/// @dev    Required env vars:
///           MIRROR_ADMIN
///           MIRROR_INITIAL_RELAYER
///           POOL_MANAGER
contract BatchDeploy is Script {
    bytes32 internal constant SALT = keccak256("immunity.mirror.v1");

    function run() external returns (Mirror mirror, ImmunityHook hook) {
        address admin = vm.envAddress("MIRROR_ADMIN");
        address relayer = vm.envAddress("MIRROR_INITIAL_RELAYER");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));

        vm.startBroadcast();
        mirror = new Mirror{salt: SALT}(admin, relayer);
        vm.stopBroadcast();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(poolManager, IMirror(address(mirror)));
        (address expected, bytes32 hookSalt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(ImmunityHook).creationCode,
            args
        );

        vm.startBroadcast();
        hook = new ImmunityHook{salt: hookSalt}(poolManager, IMirror(address(mirror)));
        vm.stopBroadcast();

        require(address(hook) == expected, "BatchDeploy: hook address mismatch");

        console2.log("chainId:        ", block.chainid);
        console2.log("Mirror:         ", address(mirror));
        console2.log("ImmunityHook:   ", address(hook));
        console2.log("PoolManager:    ", address(poolManager));
    }
}
