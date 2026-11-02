// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {RuleSetup} from "./utils/RuleSetup.sol";
import {ConditionalOrders} from "../src/ConditionalOrders.sol";
import {OrderState} from "../src/libraries/OrderState.sol";

/// @dev Gas benchmark for the main user paths. Run with -vv to see the numbers.
contract GasBench is RuleSetup {
    function _swapGas() internal returns (uint256 used) {
        uint256 g = gasleft();
        _swap(false, 20e18);
        used = g - gasleft();
    }

    function _withBuckets(uint256 n) internal returns (uint256 used) {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < n; ++i) {
            vm.prank(alice);
            hook.placeLimit(poolKey, int24(int256(60 * (i + 1))), true, 0.1e18);
        }
        used = _swapGas();
        vm.revertToState(snap);
    }

    function test_bench_limitOrders() public {
        uint256 base = _withBuckets(0);
        console.log("swap, no buckets:", base);
        for (uint256 n = 1; n <= 4; ++n) {
            console.log("extra swap gas, buckets filled:", n, _withBuckets(n) - base);
        }

        vm.prank(alice);
        uint256 g = gasleft();
        uint256 id = hook.placeLimit(poolKey, 60, true, 1e18);
        console.log("placeLimit (new bucket):", g - gasleft());
        vm.prank(bob);
        g = gasleft();
        hook.placeLimit(poolKey, 60, true, 1e18);
        console.log("placeLimit (join bucket):", g - gasleft());
        _swap(false, 20e18);
        vm.prank(alice);
        g = gasleft();
        hook.claimLimit(id, alice);
        console.log("claimLimit:", g - gasleft());
    }

    function test_bench_conditionalOrders() public {
        OrderState.Side memory low;
        low.checker = OrderState.CHECK_EDGE;
        low.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE | OrderState.ACT_SWAP;
        low.removeBps = 10_000;
        low.swapToToken1 = true;
        OrderState.Side memory off;
        ConditionalOrders.CreateParams memory p = ConditionalOrders.CreateParams({
            key: poolKey,
            tickLower: -600,
            tickUpper: 600,
            liquidity: 10e18,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            swapPoolIndex: 0,
            expiry: uint32(block.timestamp + 1 days),
            maxKeeperFeeBps: 10,
            maxSlippage: 100, // 1,000 ticks
            lower: low,
            upper: off
        });
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 id = orders.createOrder(p);
        console.log("createOrder:", g - gasleft());

        _swap(true, 5e18);
        vm.prank(keeper);
        g = gasleft();
        orders.execute(id, false);
        console.log("execute (exit + instant swap):", g - gasleft());
    }
}
