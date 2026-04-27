// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {ImmunityHook} from "../src/ImmunityHook.sol";
import {IMirror} from "../src/interfaces/IMirror.sol";

/// @notice Mines a CREATE2 salt that produces a hook address with the
///         BEFORE_SWAP_FLAG bit (0x0080) set in its low 14 bits, then
///         deploys ImmunityHook against an existing Mirror and the
///         per-chain canonical PoolManager.
///
/// @dev    Required env vars:
///           POOL_MANAGER     — chain-local Uniswap v4 PoolManager
///           MIRROR_ADDRESS   — Mirror deployed by DeployMirror
contract DeployHook is Script {
    function run() external returns (ImmunityHook hook) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        IMirror mirror = IMirror(vm.envAddress("MIRROR_ADDRESS"));

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(poolManager, mirror);
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(ImmunityHook).creationCode,
            args
        );

        vm.startBroadcast();
        hook = new ImmunityHook{salt: salt}(poolManager, mirror);
        vm.stopBroadcast();

        require(address(hook) == expected, "DeployHook: address mismatch");

        console2.log("chainId:           ", block.chainid);
        console2.log("PoolManager:       ", address(poolManager));
        console2.log("Mirror:            ", address(mirror));
        console2.log("ImmunityHook:      ", address(hook));
        console2.log("hook flags (low 14):", uint160(address(hook)) & 0x3fff);
    }
}
