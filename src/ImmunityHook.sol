// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IMirror} from "./interfaces/IMirror.sol";

/// @title ImmunityHook
/// @notice Uniswap v4 BeforeSwap hook that consults a chain-local Mirror
///         and reverts if the swap router (`sender`), the originating
///         EOA (`tx.origin`), or either pool token is flagged.
///
///         Reverts carry the antibody ID so explorers and wallets can
///         deep-link to the antibody page that caused the block.
///
/// @dev    Single hook permission: BEFORE_SWAP (bit 7 = 0x0080). The
///         deployed contract address must encode this in its low 14 bits
///         — use HookMiner in the deploy script.
contract ImmunityHook is BaseHook {
    IMirror public immutable mirror;

    error SenderBlocked(address sender, bytes32 keccakId);
    error OriginBlocked(address origin, bytes32 keccakId);
    error TokenBlocked(address token, bytes32 keccakId);

    constructor(IPoolManager _poolManager, IMirror _mirror) BaseHook(_poolManager) {
        mirror = _mirror;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes32 id;
        if ((id = mirror.isBlocked(sender)) != bytes32(0)) revert SenderBlocked(sender, id);
        if ((id = mirror.isBlocked(tx.origin)) != bytes32(0)) revert OriginBlocked(tx.origin, id);

        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        if (t0 != address(0) && (id = mirror.isBlocked(t0)) != bytes32(0)) revert TokenBlocked(t0, id);
        if (t1 != address(0) && (id = mirror.isBlocked(t1)) != bytes32(0)) revert TokenBlocked(t1, id);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
