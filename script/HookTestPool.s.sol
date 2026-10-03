// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {FloorHook} from "../src/desk/FloorHook.sol";
import {HookTestPool} from "../src/testing/HookTestPool.sol";
import {V4} from "../src/desk/v4/V4.sol";

/// FloorHook's test pool on Robinhood Chain, in three steps, all from the hook's owner key:
///   forge script script/HookTestPool.s.sol --sig "deploy()" --rpc-url robinhood --broadcast --private-key $KEY
///   POOL=0x... forge script script/HookTestPool.s.sol --sig "register()" --rpc-url robinhood --broadcast --private-key $KEY
///   POOL=0x... forge script script/HookTestPool.s.sol --sig "open()" --rpc-url robinhood --broadcast --private-key $KEY
/// `open` adds 0.01 ETH against 10M test tokens. Later, `close()` then `withdraw()` on the pool return it.
contract HookTestPoolScript is Script {
    FloorHook constant HOOK = FloorHook(payable(0x7d309A342f12e7f788CCF992740E5C482D4B6044));
    /// floor.top's platform wallet: where the pool's platform share goes
    address constant PLATFORM = 0x6C87a58B5050360F29EEBb914490c25C68923394;
    uint256 constant ETH_IN = 0.01 ether;
    uint256 constant TOKENS_IN = 10_000_000e18;

    function deploy() external {
        require(block.chainid == 4663, "Robinhood Chain mainnet only");
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        HookTestPool pool = new HookTestPool(sender, HOOK);
        vm.stopBroadcast();
        console.log("HookTestPool", address(pool));
        console.log("  test token", address(pool.token()));
        console.log("  pool id");
        console.logBytes32(V4.id(pool.key()));
    }

    function register() external {
        HookTestPool pool = HookTestPool(payable(vm.envAddress("POOL")));
        vm.startBroadcast();
        HOOK.registerPool(pool.key(), address(pool), address(pool), PLATFORM, 100, 1000, 5000);
        vm.stopBroadcast();
        console.log("registered on FloorHook");
    }

    function open() external {
        HookTestPool pool = HookTestPool(payable(vm.envAddress("POOL")));
        vm.startBroadcast();
        pool.open{value: ETH_IN}(TOKENS_IN);
        vm.stopBroadcast();
        console.log("open, liquidity", uint256(pool.liquidity()));
        console.logBytes32(V4.id(pool.key()));
    }
}
