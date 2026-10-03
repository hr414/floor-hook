// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The slice of Uniswap v4 that floor.top's pool contracts talk to, written here against the
///         deployed PoolManager's ABI (Robinhood Chain 0x8366a39CC670B4001A1121B8F6A443A643e40951) so
///         the desk carries no v4 library. v4's own `Currency`, `BalanceDelta` and `PoolId` are value
///         types over `address`, `int256` and `bytes32`; they appear here as those plain types, which
///         is what the ABI and every selector see.

/// @dev A pool's identity. `currency0 < currency1`; native ETH is `address(0)`, so it is always currency0.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    /// @dev Negative: exact input of that many. Positive: exact output.
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface IPoolManagerV4 {
    function unlock(bytes calldata data) external returns (bytes memory);
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    /// @return callerDelta packed (amount0 << 128 | amount1), from the caller's side: positive is owed to it
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    /// @return swapDelta packed like `modifyLiquidity`'s, from the swapper's side
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32 value);
}

interface IUnlockCallbackV4 {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice Small helpers over the types above.
library V4 {
    /// @dev The PoolManager's `pools` mapping sits at storage slot 6; a pool's state struct starts at
    ///      keccak256(poolId, 6) with slot0 first and the in-range liquidity three words on. Checked
    ///      against a live pool on Robinhood Chain (2026-09-30) and pinned by the fork tests.
    uint256 internal constant POOLS_SLOT = 6;
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    /// @dev v4's price bounds (TickMath MIN_SQRT_PRICE / MAX_SQRT_PRICE) and tick bounds.
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    int24 internal constant MAX_TICK = 887272;

    /// @dev Hook permission bits: v4 reads a hook's permissions from the low 14 bits of its address.
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA = 1 << 2;
    uint160 internal constant ALL_FLAGS = (1 << 14) - 1;

    function id(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function stateSlot(bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, bytes32(POOLS_SLOT)));
    }

    /// @notice The pool's current price and tick (zero price: not initialized).
    function slot0(IPoolManagerV4 manager, bytes32 poolId) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        uint256 word = uint256(manager.extsload(stateSlot(poolId)));
        sqrtPriceX96 = uint160(word);
        tick = int24(int256(word >> 160));
    }

    function liquidity(IPoolManagerV4 manager, bytes32 poolId) internal view returns (uint128) {
        return uint128(uint256(manager.extsload(bytes32(uint256(stateSlot(poolId)) + LIQUIDITY_OFFSET))));
    }

    function amount0(int256 delta) internal pure returns (int128) {
        return int128(delta >> 128);
    }

    function amount1(int256 delta) internal pure returns (int128) {
        return int128(delta);
    }
}
