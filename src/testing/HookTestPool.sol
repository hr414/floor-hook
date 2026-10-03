// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FloorHook} from "../desk/FloorHook.sol";
import {TickMath} from "../desk/uniswap/TickMath.sol";
import {PoolKey, ModifyLiquidityParams, IPoolManagerV4, IUnlockCallbackV4, V4} from "../desk/v4/V4.sol";

/// @notice A worthless token for FloorHook's test pool. Like a floor.top coin it names its launch (here
///         the test pool) and lets any holder burn, which FloorHook's buyback does with what it buys.
contract HookTestToken is ERC20 {
    address public immutable launch;

    constructor(uint256 supply) ERC20("floor.top hook test", "FHTEST") {
        launch = msg.sender;
        _mint(msg.sender, supply);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @title HookTestPool
/// @notice A Uniswap v4 pool on FloorHook with a test token, for Uniswap Labs' routing review ("a pool
///         that you have deployed with the hook ... can be with test tokens ... must contain some minimal
///         amount of liquidity"). It stands in for a floor.top launch where FloorHook needs one: it names
///         the token and the token names it, it reports a nonzero stock vault address (itself), and it
///         takes the vault share the hook pays (`fundVault`). Unlike a real launch's pool, its position can
///         be removed by its owner, so the test ETH comes back.
///         Use: deploy; the hook's owner registers `key()` with this contract as initializer and launch;
///         the owner calls `open` with some ETH; trade it like any v4 pool. `close` removes the position.
contract HookTestPool is Ownable, IUnlockCallbackV4 {
    using SafeERC20 for IERC20;

    int24 public constant TICK_SPACING = 200;
    int24 public constant FULL_RANGE_TICK = 887200;
    uint256 public constant SUPPLY = 1_000_000_000e18;

    FloorHook public immutable hook;
    IPoolManagerV4 public immutable manager;
    HookTestToken public immutable token;
    /// @notice The full-range position's liquidity (zero before `open` and after `close`).
    uint128 public liquidity;

    error NotManager();
    error AlreadyOpen();
    error NotOpen();
    error BadAmount();
    error PayFailed();

    event Opened(bytes32 indexed poolId, uint256 eth, uint256 tokens, uint128 liquidity);
    event Closed(bytes32 indexed poolId, uint256 eth, uint256 tokens);

    constructor(address owner_, FloorHook hook_) Ownable(owner_) {
        hook = hook_;
        manager = hook_.manager();
        token = new HookTestToken(SUPPLY);
    }

    // ------------------------------------------- what FloorHook reads from a launch ----

    /// @notice A floor.top launch's stock vault; this test pool has none, and any nonzero address passes
    ///         the hook's check.
    function stock() external view returns (address) {
        return address(this);
    }

    function recoveredTo() external pure returns (address) {
        return address(0);
    }

    /// @notice The hook pays the pool's vault share here; the owner takes it back with `withdraw`.
    function fundVault() external payable {}

    receive() external payable {}

    // ---------------------------------------------------------------------- pool ----

    function key() public view returns (PoolKey memory) {
        return PoolKey(address(0), address(token), 0, TICK_SPACING, address(hook));
    }

    function poolId() external view returns (bytes32) {
        return V4.id(key());
    }

    /// @notice Create the pool at the price of the two amounts and add them as one full-range position:
    ///         all the ETH sent against `tokens` of the test token. The hook must already have this pool
    ///         registered with this contract as its initializer.
    function open(uint256 tokens) external payable onlyOwner {
        if (liquidity != 0) revert AlreadyOpen();
        if (msg.value < 2 || tokens < 2 || tokens > token.balanceOf(address(this))) revert BadAmount();
        PoolKey memory k = key();
        uint160 sqrtPrice = uint160(Math.sqrt(Math.mulDiv(tokens, 1 << 192, msg.value)));
        manager.initialize(k, sqrtPrice);
        uint128 liq = _liquidity(sqrtPrice, msg.value - 1, tokens - 1);
        manager.unlock(abi.encode(true, liq));
        liquidity = liq;
        emit Opened(V4.id(k), msg.value, tokens, liq);
    }

    /// @notice Remove the whole position; what it returns stays here for `withdraw`.
    function close() external onlyOwner {
        uint128 liq = liquidity;
        if (liq == 0) revert NotOpen();
        liquidity = 0;
        uint256 ethBefore = address(this).balance;
        uint256 tokensBefore = token.balanceOf(address(this));
        manager.unlock(abi.encode(false, liq));
        emit Closed(V4.id(key()), address(this).balance - ethBefore, token.balanceOf(address(this)) - tokensBefore);
    }

    /// @notice Send the ETH and test tokens held here to the owner.
    function withdraw() external onlyOwner {
        uint256 tokens = token.balanceOf(address(this));
        if (tokens != 0) IERC20(address(token)).safeTransfer(owner(), tokens);
        (bool ok,) = payable(owner()).call{value: address(this).balance}("");
        if (!ok) revert PayFailed();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (bool add, uint128 liq) = abi.decode(data, (bool, uint128));
        PoolKey memory k = key();
        int256 change = add ? int256(uint256(liq)) : -int256(uint256(liq));
        (int256 delta,) = manager.modifyLiquidity(k, ModifyLiquidityParams(-FULL_RANGE_TICK, FULL_RANGE_TICK, change, 0), "");
        int128 d0 = V4.amount0(delta);
        int128 d1 = V4.amount1(delta);
        if (d0 < 0) manager.settle{value: uint256(-int256(d0))}();
        if (d1 < 0) {
            manager.sync(k.currency1);
            IERC20(k.currency1).safeTransfer(address(manager), uint256(-int256(d1)));
            manager.settle();
        }
        if (d0 > 0) manager.take(address(0), address(this), uint256(int256(d0)));
        if (d1 > 0) manager.take(k.currency1, address(this), uint256(int256(d1)));
        return "";
    }

    /// @dev Full-range liquidity the two amounts support at `sqrtPrice` (FloorSeeder's).
    function _liquidity(uint160 sqrtPrice, uint256 amount0, uint256 amount1) private pure returns (uint128) {
        uint160 lower = TickMath.getSqrtPriceAtTick(-FULL_RANGE_TICK);
        uint160 upper = TickMath.getSqrtPriceAtTick(FULL_RANGE_TICK);
        uint256 l0 = Math.mulDiv(Math.mulDiv(amount0, sqrtPrice, 1 << 96), upper, upper - sqrtPrice);
        uint256 l1 = Math.mulDiv(amount1, 1 << 96, sqrtPrice - lower);
        uint256 l = l0 < l1 ? l0 : l1;
        if (l == 0 || l > type(uint128).max) revert BadAmount();
        return uint128(l);
    }
}
