// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

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

contract ImmunityHookBlockingTest is ImmunityHookTest {
    address internal token0Addr = address(0x0000000000000000000000000000000000000a01);
    address internal token1Addr = address(0x0000000000000000000000000000000000000a02);
    address internal swapRouter = address(0x80007e8);
    address internal eoa = address(0xE0A);

    bytes32 internal idSender = keccak256("ab.sender");
    bytes32 internal idOrigin = keccak256("ab.origin");
    bytes32 internal idToken0 = keccak256("ab.token0");
    bytes32 internal idToken1 = keccak256("ab.token1");

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(token0Addr),
            currency1: Currency.wrap(token1Addr),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 4295128740});
    }

    function _callBeforeSwap() internal {
        vm.prank(address(POOL_MANAGER_PLACEHOLDER));
        vm.txGasPrice(0); // not strictly needed but keeps gas measurement reproducible
        hook.beforeSwap(swapRouter, _key(), _swapParams(), "");
    }

    function test_PassesWhenNothingBlocked() public {
        // Should not revert.
        _callBeforeSwap();
    }

    function test_RevertsOnBlockedSender() public {
        mockMirror.setBlock(swapRouter, idSender);
        vm.prank(address(POOL_MANAGER_PLACEHOLDER));
        vm.expectRevert(abi.encodeWithSelector(ImmunityHook.SenderBlocked.selector, swapRouter, idSender));
        hook.beforeSwap(swapRouter, _key(), _swapParams(), "");
    }

    function test_RevertsOnBlockedOrigin() public {
        mockMirror.setBlock(eoa, idOrigin);
        vm.prank(address(POOL_MANAGER_PLACEHOLDER), eoa); // sets msg.sender + tx.origin
        vm.expectRevert(abi.encodeWithSelector(ImmunityHook.OriginBlocked.selector, eoa, idOrigin));
        hook.beforeSwap(swapRouter, _key(), _swapParams(), "");
    }

    function test_RevertsOnBlockedToken0() public {
        mockMirror.setBlock(token0Addr, idToken0);
        vm.prank(address(POOL_MANAGER_PLACEHOLDER));
        vm.expectRevert(abi.encodeWithSelector(ImmunityHook.TokenBlocked.selector, token0Addr, idToken0));
        hook.beforeSwap(swapRouter, _key(), _swapParams(), "");
    }

    function test_RevertsOnBlockedToken1() public {
        mockMirror.setBlock(token1Addr, idToken1);
        vm.prank(address(POOL_MANAGER_PLACEHOLDER));
        vm.expectRevert(abi.encodeWithSelector(ImmunityHook.TokenBlocked.selector, token1Addr, idToken1));
        hook.beforeSwap(swapRouter, _key(), _swapParams(), "");
    }

    function test_OnlyPoolManagerCanCallBeforeSwap() public {
        vm.expectRevert(); // BaseHook.NotPoolManager
        hook.beforeSwap(swapRouter, _key(), _swapParams(), "");
    }

    function test_NativeTokenZeroAddressIsNotChecked() public {
        // currency0 = address(0) (native ETH) — must be skipped, not flagged.
        PoolKey memory key = _key();
        key.currency0 = Currency.wrap(address(0));
        // Even if address(0) were "blocked", the hook short-circuits the check.
        mockMirror.setBlock(address(0), keccak256("zero-shouldnt-matter"));

        vm.prank(address(POOL_MANAGER_PLACEHOLDER));
        hook.beforeSwap(swapRouter, key, _swapParams(), "");
    }
}

contract ImmunityHookGasTest is ImmunityHookTest {
    address internal token0Addr = address(0x0000000000000000000000000000000000000a01);
    address internal token1Addr = address(0x0000000000000000000000000000000000000a02);
    address internal swapRouter = address(0x80007e8);

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(token0Addr),
            currency1: Currency.wrap(token1Addr),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 4295128740});
    }

    /// @notice Per the plan target, the hook's overhead per swap must
    ///         remain under 25,000 gas. The uniswap-explore reference
    ///         measured 23,086 gas for a four-SLOAD trivial registry;
    ///         our reads return bytes32 instead of bool but storage
    ///         layout is the same, so we expect a similar number.
    function test_GasOverheadUnder25k() public {
        PoolKey memory key = _key();
        SwapParams memory params = _swapParams();

        // Warm storage: do one call to populate access lists, then measure.
        vm.prank(address(POOL_MANAGER_PLACEHOLDER));
        hook.beforeSwap(swapRouter, key, params, "");

        vm.prank(address(POOL_MANAGER_PLACEHOLDER));
        uint256 gasBefore = gasleft();
        hook.beforeSwap(swapRouter, key, params, "");
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("hook beforeSwap gas (warm)", gasUsed);
        assertLt(gasUsed, 25_000, "hook overhead must stay under 25k");
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
