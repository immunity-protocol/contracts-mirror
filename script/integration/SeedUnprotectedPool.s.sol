// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

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

/// @notice Seeds a v4 pool that is the structural twin of the protected pool
///         from `SeedPool.s.sol`, except `hooks = address(0)`. This is the
///         "always passes" reference pool for the /dex demo: same tokens,
///         same fee, same tick spacing, but no Immunity gate. Compare swaps
///         against the protected pool to see the hook reverting.
///
/// @dev    Reuses INT_TOK_A and INT_TOK_B from `state.json` (deployed by
///         SeedPool.s.sol). Writes the resulting unprotected poolId back to
///         state.json so the frontend can pick it up.
///
///         Required env vars:
///           POOL_MANAGER (canonical Sepolia v4)
///
///         One-shot:
///           forge script script/integration/SeedUnprotectedPool.s.sol \
///             --rpc-url $SEPOLIA_RPC_URL --broadcast --account deployer
contract SeedUnprotectedPool is Script {
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

        // Reuse the tokens deployed by SeedPool.s.sol so judges can hold one
        // pair of test tokens and swap on either pool.
        string memory state = vm.readFile("./script/integration/state.json");
        address tokenA = vm.parseJsonAddress(state, ".INT_TOK_A");
        address tokenB = vm.parseJsonAddress(state, ".INT_TOK_B");

        vm.startBroadcast();

        (Currency c0, Currency c1) = tokenA < tokenB
            ? (Currency.wrap(tokenA), Currency.wrap(tokenB))
            : (Currency.wrap(tokenB), Currency.wrap(tokenA));

        _approve(IERC20(Currency.unwrap(c0)));
        _approve(IERC20(Currency.unwrap(c1)));

        // The defining difference: hooks = address(0) means swaps bypass the
        // Immunity gate entirely. PoolKey.toId() hashes hooks too, so the
        // unprotected pool gets a distinct poolId from the protected pool.
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        poolManager.initialize(key, STARTING_PRICE);
        _addLiquidity(IPositionManager(POSITION_MANAGER), key);

        vm.stopBroadcast();

        bytes32 unprotectedPoolId = PoolId.unwrap(key.toId());
        console2.log("currency0:           ", Currency.unwrap(c0));
        console2.log("currency1:           ", Currency.unwrap(c1));
        console2.log("hook:                 0x0000000000000000000000000000000000000000");
        console2.log("unprotectedPoolId:   ", vm.toString(unprotectedPoolId));

        // Patch state.json: keep every existing key untouched and add the
        // new unprotected pool fields so the /dex frontend can pick them up.
        string memory j = "state";
        vm.serializeAddress(j, "INT_TOK_A", tokenA);
        vm.serializeAddress(j, "INT_TOK_B", tokenB);
        vm.serializeAddress(j, "currency0", Currency.unwrap(c0));
        vm.serializeAddress(j, "currency1", Currency.unwrap(c1));
        vm.serializeString(j, "poolId", vm.parseJsonString(state, ".poolId"));
        vm.serializeString(j, "unprotectedPoolId", vm.toString(unprotectedPoolId));
        vm.serializeAddress(j, "unprotectedHook", address(0));
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
