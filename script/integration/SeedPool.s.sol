// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

/// @notice Deploys two mock ERC20s, initializes a v4 pool with our
///         ImmunityHook, and seeds 100/100 of liquidity. One-shot for
///         the live integration test on Sepolia.
///
/// @dev    Adapted from uniswap-explore/template/script/SeedPools.s.sol.
///         Sepolia v4 addresses are inlined to avoid pulling hookmate.
///
///         Required env vars:
///           POOL_MANAGER, HOOK_ADDRESS
contract SeedIntegrationPool is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant STARTING_PRICE = 2 ** 96;
    uint256 internal constant LIQ0 = 100 ether;
    uint256 internal constant LIQ1 = 100 ether;

    function run() external {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        IHooks hook = IHooks(vm.envAddress("HOOK_ADDRESS"));

        vm.startBroadcast();

        MockERC20 a = new MockERC20("Integration A", "INTA", 18);
        MockERC20 b = new MockERC20("Integration B", "INTB", 18);
        a.mint(msg.sender, 1_000_000 ether);
        b.mint(msg.sender, 1_000_000 ether);

        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));

        _approve(IERC20(Currency.unwrap(c0)));
        _approve(IERC20(Currency.unwrap(c1)));

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        poolManager.initialize(key, STARTING_PRICE);
        _addLiquidity(IPositionManager(POSITION_MANAGER), key);

        vm.stopBroadcast();

        console2.log("INT_TOK_A: ", address(a));
        console2.log("INT_TOK_B: ", address(b));
        console2.log("currency0: ", Currency.unwrap(c0));
        console2.log("currency1: ", Currency.unwrap(c1));
        console2.log("hook:      ", address(hook));
        console2.log("poolId:    ", vm.toString(PoolId.unwrap(key.toId())));

        // Write directly so run.mjs can pick it up without manual paste.
        string memory j = "state";
        vm.serializeAddress(j, "INT_TOK_A", address(a));
        vm.serializeAddress(j, "INT_TOK_B", address(b));
        vm.serializeAddress(j, "currency0", Currency.unwrap(c0));
        vm.serializeAddress(j, "currency1", Currency.unwrap(c1));
        vm.serializeString(j, "poolId", vm.toString(PoolId.unwrap(key.toId())));
        string memory out = vm.serializeUint(j, "seededAt", block.timestamp);
        vm.writeJson(out, "./script/integration/state.json");
    }

    function _approve(IERC20 t) internal {
        t.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(t), POSITION_MANAGER, type(uint160).max, type(uint48).max);
    }

    function _addLiquidity(IPositionManager pm, PoolKey memory key) internal {
        int24 currentTick = TickMath.getTickAtSqrtPrice(STARTING_PRICE);
        int24 tickLower = _truncate(currentTick - 750 * TICK_SPACING);
        int24 tickUpper = _truncate(currentTick + 750 * TICK_SPACING);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            STARTING_PRICE,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            LIQ0,
            LIQ1
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, LIQ0 + 1, LIQ1 + 1, msg.sender, new bytes(0));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, msg.sender);
        params[3] = abi.encode(key.currency1, msg.sender);

        pm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
    }

    function _truncate(int24 tick) internal pure returns (int24) {
        return (tick / TICK_SPACING) * TICK_SPACING;
    }
}
