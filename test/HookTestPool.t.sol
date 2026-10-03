// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FloorHook} from "../src/desk/FloorHook.sol";
import {HookTestPool, HookTestToken} from "../src/testing/HookTestPool.sol";
import {PoolKey, SwapParams, IPoolManagerV4, IUnlockCallbackV4, V4} from "../src/desk/v4/V4.sol";

/// The test pool on the LIVE FloorHook, on a fork of Robinhood Chain: registered by the hook's owner,
/// opened with a little ETH, traded both ways (the hook takes 1% of each swap's output), its fees paid
/// out, then closed with the ETH back.
///   forge test --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract HookTestPoolFork is Test, IUnlockCallbackV4 {
    FloorHook constant HOOK = FloorHook(payable(0x7d309A342f12e7f788CCF992740E5C482D4B6044));
    IPoolManagerV4 constant PM = IPoolManagerV4(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PLATFORM = 0x6C87a58B5050360F29EEBb914490c25C68923394;

    address owner;
    HookTestPool pool;
    HookTestToken token;
    PoolKey key;
    bytes32 id;

    function setUp() public {
        if (block.chainid != 4663) vm.createSelectFork("robinhood");
        owner = HOOK.owner();
        pool = new HookTestPool(owner, HOOK);
        token = pool.token();
        key = pool.key();
        id = V4.id(key);
        vm.prank(owner);
        HOOK.registerPool(key, address(pool), address(pool), PLATFORM, 100, 1000, 5000);
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        pool.open{value: 0.01 ether}(10_000_000e18);
    }

    // ------------------------------------------------------------ swaps ----

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "not manager");
        (bool zeroForOne, uint256 amountIn) = abi.decode(data, (bool, uint256));
        uint160 limit = zeroForOne ? V4.MIN_SQRT_PRICE + 1 : V4.MAX_SQRT_PRICE - 1;
        int256 d = PM.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        int128 a0 = V4.amount0(d);
        int128 a1 = V4.amount1(d);
        if (zeroForOne) {
            PM.settle{value: uint256(-int256(a0))}();
            PM.take(address(token), address(this), uint256(int256(a1)));
        } else {
            PM.sync(address(token));
            IERC20(address(token)).transfer(address(PM), uint256(-int256(a1)));
            PM.settle();
            PM.take(address(0), address(this), uint256(int256(a0)));
        }
        return "";
    }

    receive() external payable {}

    // ------------------------------------------------------------ tests ----

    function test_ThePoolIsOpenOnTheHookWithLiquidity() public view {
        FloorHook.Pool memory p = HOOK.pools(id);
        assertTrue(p.registered && p.initialized);
        assertEq(p.coin, address(token));
        assertEq(p.initializer, address(pool));
        assertEq(p.feeBps, 100);
        assertGt(V4.liquidity(PM, id), 0);
        (uint160 sqrtPrice,) = V4.slot0(PM, id);
        uint256 tokensPerEth = Math.mulDiv(uint256(sqrtPrice) * sqrtPrice, 1, 1 << 192);
        assertApproxEqRel(tokensPerEth, 1_000_000_000, 1e12, "10M tokens against 0.01 ETH");
    }

    function test_SwapsBothWaysPayTheHookOnePercent() public {
        vm.deal(address(this), 0.001 ether);
        PM.unlock(abi.encode(true, 0.001 ether));
        uint256 got = token.balanceOf(address(this));
        uint256 coinFee = HOOK.pools(id).pendingCoin;
        assertApproxEqAbs(coinFee, (got + coinFee) / 100, 2, "1% of the output");

        uint256 ethBefore = address(this).balance;
        PM.unlock(abi.encode(false, got));
        uint256 ethOut = address(this).balance - ethBefore;
        uint256 ethFee = HOOK.pools(id).pendingEth;
        assertApproxEqAbs(ethFee, (ethOut + ethFee) / 100, 2, "1% of the output");

        // the fee's shares pay out: 0.10% of the trade to the platform, the vault share to the pool
        uint256 platformBefore = PLATFORM.balance;
        HOOK.payPlatform(id);
        assertGt(PLATFORM.balance, platformBefore);
        uint256 vaultBefore = address(pool).balance;
        HOOK.payVault(id);
        assertGt(address(pool).balance, vaultBefore);
    }

    function test_TheOwnerClosesItAndTakesTheEthBack() public {
        uint256 before = owner.balance;
        vm.startPrank(owner);
        pool.close();
        pool.withdraw();
        vm.stopPrank();
        assertApproxEqAbs(owner.balance - before, 0.01 ether, 1e6, "the test ETH comes back");
        assertEq(pool.liquidity(), 0);
    }

    function test_OnlyTheOwnerOpensAndCloses() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert();
        pool.close();
        vm.expectRevert();
        pool.withdraw();
        vm.stopPrank();
        // and an unregistered pool cannot be created at all
        HookTestPool other = new HookTestPool(owner, HOOK);
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert();
        other.open{value: 0.01 ether}(10_000_000e18);
    }
}
