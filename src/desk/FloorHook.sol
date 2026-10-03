// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey, SwapParams, IPoolManagerV4, IUnlockCallbackV4, V4} from "./v4/V4.sol";

/// @notice What the hook reads from, and pays into, a desk launch (DeskLaunch).
interface IFloorLaunch {
    function token() external view returns (address);
    function stock() external view returns (address);
    function recoveredTo() external view returns (address);
    function fundVault() external payable;
}

/// @notice A desk coin (DeskToken): the launch it names, and its holder burn.
interface IFloorCoin {
    function launch() external view returns (address);
    function burn(uint256 amount) external;
}

/// @title FloorHook (built 2026-09-30, reworked the same day after its first review; not deployed)
/// @notice The Uniswap v4 hook behind floor.top's pools. Each pool it serves pairs native ETH with
///         one desk coin, charges no LP fee of its own, and pays the desk's trade fee through this
///         hook instead: `feeBps` of every swap's unspecified side (the output of an exact-input
///         swap, the input of an exact-output one) is taken in `afterSwap` and held here. The fee
///         splits three ways, fixed when the pool is registered:
///         - `platformBps` of it to the platform wallet, in ETH;
///         - `buybackBps` of the rest buys the coin back in this pool and BURNS it (coin already
///           taken as a fee is burned as it stands, no swap);
///         - the remainder is paid, as ETH, into the launch's vault (`DeskLaunch.fundVault`), where
///           the launch's own sweep buys its stock under its quote floor, and a dead stock route
///           pays it to redeemers instead, like the launch's own fee ETH.
///         Swaps on the fee's behalf (coin to ETH, ETH to coin) run against the pool itself and skip
///         this hook (v4 never calls a hook on its own swaps). Each is held to half the fee's share
///         of the pool's reserve on its input side, so sandwiching one costs the sandwicher more in
///         fees than it moves the price; to one such swap per pool per block, so a sandwich cannot
///         stack several; and to MAX_IMPACT_BPS of price movement, reverting rather than filling
///         part. They are the keeper's (the operator's) or the owner's to run, and anyone's once the
///         keeper and the owner have left a pool alone for OPEN_SWEEP_AFTER; a stranger's sweep never
///         restarts that clock. Payments to the vault and the platform are anyone's at any time.
///         The owner registers pools and names the keeper and the platform wallet; it cannot touch a
///         pool's fee, its split, the fees held here, or its liquidity (this hook has no liquidity
///         permission). Only the registered initializer (the pool's seeder) can create a pool on
///         this hook. If the launch is recovered (its coin frozen, so the pool cannot trade), anyone
///         may send the ETH held for the buyback and the vault to the launch's successor.
contract FloorHook is Ownable2Step, ReentrancyGuard, IUnlockCallbackV4 {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    /// @notice A pool's fee can never pass 2% of a trade.
    uint256 public constant MAX_FEE_BPS = 200;
    /// @notice A sweep swap may move the pool's price at most this much.
    uint256 public constant MAX_IMPACT_BPS = 300;
    /// @notice After the keeper and the owner have left a pool alone this long, anyone may sweep it.
    uint256 public constant OPEN_SWEEP_AFTER = 7 days;
    /// @notice The permissions this hook's address must carry (v4 reads them from its low bits).
    uint160 public constant FLAGS = V4.BEFORE_INITIALIZE | V4.AFTER_SWAP | V4.AFTER_SWAP_RETURNS_DELTA;

    IPoolManagerV4 public immutable manager;

    struct Pool {
        // read on every swap
        address coin;
        uint16 feeBps;
        uint16 platformBps;
        uint16 buybackBps;
        bool registered;
        bool initialized;
        address launch;
        /// @dev The last sweep by the keeper or the owner (the pool's opening before any).
        uint64 lastKeeperSweepAt;
        address initializer;
        /// @dev The block of the last sweep swap: one per block.
        uint64 lastSwapBlock;
        address platform;
        // fees as taken, not yet split (written on every swap)
        uint128 pendingEth;
        uint128 pendingCoin;
        // ETH already split, waiting for its destination
        uint128 platformEth;
        uint128 buybackEth;
        uint128 vaultEth;
    }

    mapping(bytes32 poolId => Pool) internal _pools;
    /// @notice The keeper that runs sweeps.
    address public operator;
    /// @notice Contracts the owner lets register pools that they open themselves (a sale seeder): one
    ///         transaction can then register, create and fill its pool, so nobody can price an empty
    ///         pool in between (review round 1).
    mapping(address => bool) public registrars;

    error WrongHookAddress(address hook);
    error NotManager();
    error NotInitializer(address sender);
    error NotRegistered(bytes32 poolId);
    error AlreadyInitialized(bytes32 poolId);
    error BadPool(string what);
    error NotSweeper(address sender);
    error TooMuch(uint256 asked, uint256 available);
    error ZeroAmount();
    error BadImpact(uint256 bps);
    error OneSweepPerBlock();
    error PartialFill(uint256 wanted, uint256 filled);
    error Slippage(uint256 out, uint256 minOut);
    error PayFailed();
    error NotRecovered();
    error NoRenounce();
    error NotRegistrar(address sender);

    event PoolRegistered(
        bytes32 indexed poolId,
        address indexed coin,
        address indexed launch,
        address initializer,
        address platform,
        uint16 feeBps,
        uint16 platformBps,
        uint16 buybackBps
    );
    event PoolOpened(bytes32 indexed poolId, uint160 sqrtPriceX96);
    event FeeTaken(bytes32 indexed poolId, address currency, uint256 amount);
    event FeesSplit(bytes32 indexed poolId, uint256 platformEth, uint256 buybackEth, uint256 vaultEth);
    event Converted(bytes32 indexed poolId, uint256 coinIn, uint256 burned, uint256 sold, uint256 ethOut);
    event BoughtBack(bytes32 indexed poolId, uint256 ethIn, uint256 burned);
    event VaultPaid(bytes32 indexed poolId, address indexed launch, uint256 amount);
    event PlatformPaid(bytes32 indexed poolId, address indexed to, uint256 amount);
    event Rescued(bytes32 indexed poolId, address indexed successor, uint256 amount);
    event OperatorSet(address operator);
    event RegistrarSet(address indexed registrar, bool allowed);
    event PlatformSet(bytes32 indexed poolId, address platform);

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert NotManager();
        _;
    }

    constructor(address owner_, IPoolManagerV4 manager_, address operator_) Ownable(owner_) {
        // v4 calls exactly the hooks an address's low bits name: this one must name these three and no others
        if (uint160(address(this)) & V4.ALL_FLAGS != FLAGS) revert WrongHookAddress(address(this));
        if (address(manager_) == address(0)) revert BadPool("manager");
        manager = manager_;
        operator = operator_;
        emit OperatorSet(operator_);
    }

    // ---------------------------------------------------------------- owner ----

    /// @notice Register the pool `key` before its seeder creates it. Everything but the platform
    ///         wallet is fixed from the moment the pool exists; until then a registration can be
    ///         redone, so the seeder checks `pools(poolId)` against its expected terms in the same
    ///         transaction that creates the pool.
    /// @param launch the coin's own desk launch (the coin must name it): its vault takes the fee's third share
    /// @param initializer the only address that may create the pool (its seeder)
    /// @param feeBps the pool's trade fee, 1 to MAX_FEE_BPS
    /// @param platformBps the platform's share of the fee
    /// @param buybackBps the buyback-and-burn share of what the platform leaves; the rest goes to the vault
    function registerPool(
        PoolKey calldata key,
        address launch,
        address initializer,
        address platform,
        uint16 feeBps,
        uint16 platformBps,
        uint16 buybackBps
    ) external {
        bytes32 poolId = V4.id(key);
        Pool storage p = _pools[poolId];
        if (msg.sender != owner()) {
            // a registrar registers only pools it opens itself, and never takes over one registered to another
            if (!registrars[msg.sender]) revert NotRegistrar(msg.sender);
            if (initializer != msg.sender) revert BadPool("initializer");
            if (p.registered && p.initializer != msg.sender) revert BadPool("registered");
        }
        if (key.currency0 != address(0)) revert BadPool("currency0 must be native ETH");
        if (key.currency1 == address(0)) revert BadPool("coin");
        if (key.hooks != address(this)) revert BadPool("hooks");
        // the pool charges nothing itself (and no dynamic fee): the whole fee is this hook's
        if (key.fee != 0) revert BadPool("fee");
        if (key.tickSpacing <= 0) revert BadPool("tickSpacing");
        // the coin and the launch must name each other: no stand-in launch can take the vault's share
        if (IFloorCoin(key.currency1).launch() != launch || IFloorLaunch(launch).token() != key.currency1) {
            revert BadPool("launch");
        }
        // the vault share needs a vault
        if (IFloorLaunch(launch).stock() == address(0)) revert BadPool("stock");
        if (initializer == address(0)) revert BadPool("initializer");
        if (platform == address(0)) revert BadPool("platform");
        if (feeBps == 0 || feeBps > MAX_FEE_BPS) revert BadPool("feeBps");
        if (platformBps > BPS || buybackBps > BPS) revert BadPool("split");
        if (p.initialized) revert AlreadyInitialized(poolId);
        p.coin = key.currency1;
        p.feeBps = feeBps;
        p.platformBps = platformBps;
        p.buybackBps = buybackBps;
        p.registered = true;
        p.launch = launch;
        p.initializer = initializer;
        p.platform = platform;
        emit PoolRegistered(poolId, key.currency1, launch, initializer, platform, feeBps, platformBps, buybackBps);
    }

    /// @notice Where the platform's share goes from now on (what is already split goes there too).
    function setPlatform(bytes32 poolId, address platform) external onlyOwner {
        if (!_pools[poolId].registered) revert NotRegistered(poolId);
        if (platform == address(0)) revert BadPool("platform");
        _pools[poolId].platform = platform;
        emit PlatformSet(poolId, platform);
    }

    /// @notice Let `registrar` (a sale seeder, code the owner has vetted) register pools it opens itself.
    function setRegistrar(address registrar, bool allowed) external onlyOwner {
        registrars[registrar] = allowed;
        emit RegistrarSet(registrar, allowed);
    }

    function setOperator(address operator_) external onlyOwner {
        operator = operator_;
        emit OperatorSet(operator_);
    }

    /// @dev Pools registered later need an owner; renouncing would strand them.
    function renounceOwnership() public pure override {
        revert NoRenounce();
    }

    // ---------------------------------------------------------------- hooks ----

    /// @notice Only a registered pool, created by its own initializer.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyManager
        returns (bytes4)
    {
        bytes32 poolId = V4.id(key);
        Pool storage p = _pools[poolId];
        if (!p.registered) revert NotRegistered(poolId);
        if (sender != p.initializer) revert NotInitializer(sender);
        p.initialized = true;
        p.lastKeeperSweepAt = uint64(block.timestamp);
        emit PoolOpened(poolId, sqrtPriceX96);
        return this.beforeInitialize.selector;
    }

    /// @notice Take the pool's fee from the swap's unspecified side and hold it here.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, int256 delta, bytes calldata)
        external
        onlyManager
        returns (bytes4, int128)
    {
        bytes32 poolId = V4.id(key);
        Pool storage p = _pools[poolId];
        // the specified side is currency0 when an exact input sells it or an exact output buys it
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        int128 unspecified = specifiedIs0 ? V4.amount1(delta) : V4.amount0(delta);
        uint256 amount = unspecified < 0 ? uint256(-int256(unspecified)) : uint256(int256(unspecified));
        uint256 fee = (amount * p.feeBps) / BPS;
        if (fee == 0) return (this.afterSwap.selector, 0);
        address currency = specifiedIs0 ? key.currency1 : key.currency0;
        manager.take(currency, address(this), fee);
        // fee < |unspecified| <= 2^127, so the casts below cannot truncate
        if (currency == address(0)) p.pendingEth += uint128(fee);
        else p.pendingCoin += uint128(fee);
        emit FeeTaken(poolId, currency, fee);
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice ETH arrives from the pool manager (fees and sweep swaps); anything else sent here is
    ///         not counted anywhere.
    receive() external payable {}

    // --------------------------------------------------------------- sweeps ----

    /// @notice Split the ETH fees taken so far into their three destinations. Anyone; moves nothing.
    function split(bytes32 poolId) public {
        Pool storage p = _pools[poolId];
        uint256 eth = p.pendingEth;
        if (eth == 0) return;
        p.pendingEth = 0;
        uint256 platform = (eth * p.platformBps) / BPS;
        uint256 rest = eth - platform;
        uint256 buyback = (rest * p.buybackBps) / BPS;
        uint256 vault = rest - buyback;
        p.platformEth += uint128(platform);
        p.buybackEth += uint128(buyback);
        p.vaultEth += uint128(vault);
        emit FeesSplit(poolId, platform, buyback, vault);
    }

    /// @notice Handle `coinIn` of the fees taken in the coin: the buyback share of it is burned as
    ///         it stands, the rest is sold in the pool for ETH that goes to the platform and vault
    ///         shares in their proportion. The part sold is held to the pool's coin-side cap.
    function convert(PoolKey calldata key, uint256 coinIn, uint256 minEthOut, uint16 maxImpactBps)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        bytes32 poolId = V4.id(key);
        Pool storage p = _sweepSwap(poolId);
        if (coinIn == 0) revert ZeroAmount();
        if (coinIn > p.pendingCoin) revert TooMuch(coinIn, p.pendingCoin);
        p.pendingCoin -= uint128(coinIn);
        (uint256 fPlatform, uint256 fBuyback, uint256 fVault) = _shares(p);
        uint256 burned = (coinIn * fBuyback) / BPS;
        uint256 sold = coinIn - burned;
        if (burned != 0) IFloorCoin(p.coin).burn(burned);
        if (sold != 0) {
            (, uint256 coinCap) = _caps(poolId, p.feeBps);
            if (sold > coinCap) revert TooMuch(sold, coinCap);
            ethOut = _swap(key, poolId, false, sold, maxImpactBps);
            if (ethOut < minEthOut) revert Slippage(ethOut, minEthOut);
            uint256 toPlatform = fPlatform + fVault == 0 ? 0 : (ethOut * fPlatform) / (fPlatform + fVault);
            p.platformEth += uint128(toPlatform);
            p.vaultEth += uint128(ethOut - toPlatform);
        }
        emit Converted(poolId, coinIn, burned, sold, ethOut);
    }

    /// @notice Spend `ethIn` of the buyback share on the coin in the pool and burn what it buys.
    ///         Held to the pool's ETH-side cap.
    function buyback(PoolKey calldata key, uint256 ethIn, uint256 minCoinOut, uint16 maxImpactBps)
        external
        nonReentrant
        returns (uint256 burned)
    {
        bytes32 poolId = V4.id(key);
        Pool storage p = _sweepSwap(poolId);
        split(poolId);
        if (ethIn == 0) revert ZeroAmount();
        if (ethIn > p.buybackEth) revert TooMuch(ethIn, p.buybackEth);
        (uint256 ethCap,) = _caps(poolId, p.feeBps);
        if (ethIn > ethCap) revert TooMuch(ethIn, ethCap);
        p.buybackEth -= uint128(ethIn);
        burned = _swap(key, poolId, true, ethIn, maxImpactBps);
        if (burned < minCoinOut) revert Slippage(burned, minCoinOut);
        IFloorCoin(p.coin).burn(burned);
        emit BoughtBack(poolId, ethIn, burned);
    }

    /// @notice Pay the vault share so far into the launch's vault. Anyone; no swap.
    function payVault(bytes32 poolId) external nonReentrant returns (uint256 amount) {
        Pool storage p = _pools[poolId];
        if (!p.registered) revert NotRegistered(poolId);
        split(poolId);
        amount = p.vaultEth;
        if (amount == 0) revert ZeroAmount();
        p.vaultEth = 0;
        address launch = p.launch;
        IFloorLaunch(launch).fundVault{value: amount}();
        emit VaultPaid(poolId, launch, amount);
    }

    /// @notice Pay the platform its share so far. Anyone.
    function payPlatform(bytes32 poolId) external nonReentrant returns (uint256 amount) {
        Pool storage p = _pools[poolId];
        if (!p.registered) revert NotRegistered(poolId);
        split(poolId);
        amount = p.platformEth;
        if (amount == 0) revert ZeroAmount();
        p.platformEth = 0;
        address to = p.platform;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert PayFailed();
        emit PlatformPaid(poolId, to, amount);
    }

    /// @notice Once the launch has been recovered (its coin frozen, so this pool can no longer
    ///         trade), send the ETH held for the buyback and the vault to the launch's successor.
    ///         Anyone. The platform's share stays the platform's; coin held here stays frozen.
    function rescue(bytes32 poolId) external nonReentrant returns (uint256 amount) {
        Pool storage p = _pools[poolId];
        if (!p.registered) revert NotRegistered(poolId);
        address to = IFloorLaunch(p.launch).recoveredTo();
        if (to == address(0)) revert NotRecovered();
        split(poolId);
        amount = uint256(p.buybackEth) + p.vaultEth;
        if (amount == 0) revert ZeroAmount();
        p.buybackEth = 0;
        p.vaultEth = 0;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert PayFailed();
        emit Rescued(poolId, to, amount);
    }

    /// @dev The swap a sweep makes against the pool, run inside the manager's unlock.
    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) =
            abi.decode(data, (PoolKey, bool, uint256, uint160));
        int256 d = manager.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        int128 a0 = V4.amount0(d);
        int128 a1 = V4.amount1(d);
        uint256 paid = uint256(-int256(zeroForOne ? a0 : a1));
        // the price cap stopped the swap before it spent everything: sweep a smaller piece
        if (paid != amountIn) revert PartialFill(amountIn, paid);
        uint256 out = uint256(int256(zeroForOne ? a1 : a0));
        if (zeroForOne) {
            manager.settle{value: amountIn}();
            manager.take(key.currency1, address(this), out);
        } else {
            manager.sync(key.currency1);
            IERC20(key.currency1).safeTransfer(address(manager), amountIn);
            manager.settle();
            manager.take(key.currency0, address(this), out);
        }
        return abi.encode(out);
    }

    // ---------------------------------------------------------------- views ----

    function pools(bytes32 poolId) external view returns (Pool memory) {
        return _pools[poolId];
    }

    /// @notice The fee's three shares, in basis points of the fee: platform, buyback, vault.
    function shares(bytes32 poolId) external view returns (uint256 platform, uint256 buyback, uint256 vault) {
        return _shares(_pools[poolId]);
    }

    /// @notice The most one buyback may spend (ETH) and one conversion may sell (coin) right now.
    function sweepCaps(bytes32 poolId) external view returns (uint256 ethCap, uint256 coinCap) {
        return _caps(poolId, _pools[poolId].feeBps);
    }

    /// @notice Whether `who` may run this pool's sweep swaps right now.
    function canSweep(bytes32 poolId, address who) public view returns (bool) {
        Pool storage p = _pools[poolId];
        if (!p.initialized) return false;
        return _isKeeper(who) || block.timestamp >= uint256(p.lastKeeperSweepAt) + OPEN_SWEEP_AFTER;
    }

    // -------------------------------------------------------------- private ----

    function _isKeeper(address who) private view returns (bool) {
        return who == operator || who == owner();
    }

    /// @dev Checks shared by the two sweep swaps, and their bookkeeping: an open pool, a caller
    ///      allowed to sweep, one sweep swap per block, and the keeper clock (strangers never move it).
    function _sweepSwap(bytes32 poolId) private returns (Pool storage p) {
        p = _pools[poolId];
        if (!p.initialized) revert NotRegistered(poolId);
        if (!canSweep(poolId, msg.sender)) revert NotSweeper(msg.sender);
        if (p.lastSwapBlock == block.number) revert OneSweepPerBlock();
        p.lastSwapBlock = uint64(block.number);
        if (_isKeeper(msg.sender)) p.lastKeeperSweepAt = uint64(block.timestamp);
    }

    function _shares(Pool storage p) private view returns (uint256 platform, uint256 buyback, uint256 vault) {
        platform = p.platformBps;
        buyback = ((BPS - platform) * p.buybackBps) / BPS;
        vault = BPS - platform - buyback;
    }

    /// @dev Half the fee's share of the pool's in-range reserves, as they stand: a sweep that size
    ///      moves the price about as much as the fees on a sandwich's two legs cost, so sandwiching
    ///      it cannot pay. Reserves are the in-range liquidity's virtual amounts at the current price.
    function _caps(bytes32 poolId, uint256 feeBps) private view returns (uint256 ethCap, uint256 coinCap) {
        uint128 liq = V4.liquidity(manager, poolId);
        (uint160 sqrtPrice,) = V4.slot0(manager, poolId);
        if (liq == 0 || sqrtPrice == 0) return (0, 0);
        uint256 ethReserve = Math.mulDiv(liq, 1 << 96, sqrtPrice);
        uint256 coinReserve = Math.mulDiv(liq, sqrtPrice, 1 << 96);
        ethCap = (ethReserve * feeBps) / (2 * BPS);
        coinCap = (coinReserve * feeBps) / (2 * BPS);
    }

    /// @dev Exact-input swap of `amountIn` against the pool, stopped at MAX_IMPACT_BPS (or less)
    ///      from the current price; reverts rather than fill part.
    function _swap(PoolKey calldata key, bytes32 poolId, bool zeroForOne, uint256 amountIn, uint16 maxImpactBps)
        private
        returns (uint256 out)
    {
        if (maxImpactBps == 0 || maxImpactBps > MAX_IMPACT_BPS) revert BadImpact(maxImpactBps);
        (uint160 sqrtPrice,) = V4.slot0(manager, poolId);
        uint160 limit = _limit(sqrtPrice, zeroForOne, maxImpactBps);
        out = abi.decode(manager.unlock(abi.encode(key, zeroForOne, amountIn, limit)), (uint256));
    }

    /// @dev The square-root price `bps` away from `sqrtPrice`: below it for a zeroForOne swap (the
    ///      price, in currency1 per currency0, falls), above it otherwise. Kept inside v4's bounds.
    function _limit(uint160 sqrtPrice, bool zeroForOne, uint256 bps) private pure returns (uint160) {
        uint256 ratio = zeroForOne ? BPS - bps : BPS + bps;
        uint256 factor = Math.sqrt((ratio << 192) / BPS); // sqrt(ratio / BPS) in Q96
        uint256 limit = Math.mulDiv(sqrtPrice, factor, 1 << 96);
        if (limit <= V4.MIN_SQRT_PRICE) return V4.MIN_SQRT_PRICE + 1;
        if (limit >= V4.MAX_SQRT_PRICE) return V4.MAX_SQRT_PRICE - 1;
        return uint160(limit);
    }
}
