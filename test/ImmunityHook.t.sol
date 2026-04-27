// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {ImmunityHook} from "../src/ImmunityHook.sol";
import {IMirror} from "../src/interfaces/IMirror.sol";

/// @notice Minimal mirror stub: returns canned ids per address.
contract MockMirror {
    mapping(address => bytes32) public blocks;

    function setBlock(address target, bytes32 id) external {
        blocks[target] = id;
    }

    function isBlocked(address target) external view returns (bytes32) {
        return blocks[target];
    }
}

contract ImmunityHookTest is Test {
    MockMirror internal mockMirror;
    ImmunityHook internal hook;

    // Sepolia canonical PoolManager — never called in unit tests; we
    // etch a single STOP byte here so BaseHook's validateHookAddress
    // (which reads codeSize) accepts it.
    IPoolManager internal constant POOL_MANAGER_PLACEHOLDER =
        IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);

    function setUp() public virtual {
        mockMirror = new MockMirror();

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(POOL_MANAGER_PLACEHOLDER, IMirror(address(mockMirror)));
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(ImmunityHook).creationCode,
            args
        );

        vm.etch(address(POOL_MANAGER_PLACEHOLDER), hex"00");

        hook = new ImmunityHook{salt: salt}(POOL_MANAGER_PLACEHOLDER, IMirror(address(mockMirror)));
        assertEq(address(hook), expected, "mined address mismatch");
    }
}

contract ImmunityHookPermissionsTest is ImmunityHookTest {
    function test_HookAddressEncodesBeforeSwapFlag() public view {
        assertEq(uint160(address(hook)) & 0x3fff, Hooks.BEFORE_SWAP_FLAG, "low 14 bits must equal 0x0080");
    }

    function test_HookHoldsMirrorReference() public view {
        assertEq(address(hook.mirror()), address(mockMirror));
    }

    function test_HookPermissionsOnlyBeforeSwap() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap, "beforeSwap must be enabled");

        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }
}
