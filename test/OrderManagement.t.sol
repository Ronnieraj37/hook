// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RuleSetup} from "./utils/RuleSetup.sol";
import {ConditionalOrders} from "../src/ConditionalOrders.sol";
import {OrderState} from "../src/libraries/OrderState.sol";

/// @notice What the frontend relies on: listing a wallet's orders, reading amounts and prices, changing a rule.
contract OrderManagementTest is RuleSetup {
    function _exitAbove() internal pure returns (OrderState.Side memory d) {
        d.checker = OrderState.CHECK_EDGE;
        d.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE;
        d.removeBps = 10_000;
    }

    function _create(address who) internal returns (uint256 id) {
        OrderState.Side memory off;
        vm.prank(who);
        id = orders.createOrder(
            ConditionalOrders.CreateParams({
                key: poolKey,
                tickLower: -600,
                tickUpper: 600,
                liquidity: 10e18,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                swapPoolIndex: 0,
                expiry: uint32(block.timestamp + 7 days),
                maxKeeperFeeBps: 10,
                maxSlippage: 50,
                lower: off,
                upper: _exitAbove()
            })
        );
    }

    function _update(uint256 id, OrderState.Side memory lower, OrderState.Side memory upper)
        internal
        view
        returns (ConditionalOrders.UpdateParams memory p)
    {
        id;
        p = ConditionalOrders.UpdateParams({
            swapPoolIndex: 0,
            expiry: uint32(block.timestamp + 30 days),
            maxKeeperFeeBps: 20,
            maxSlippage: 30,
            lower: lower,
            upper: upper
        });
    }

    function test_ordersOfListsEachOwnersOrders() public {
        uint256 a1 = _create(alice);
        uint256 b1 = _create(bob);
        uint256 a2 = _create(alice);
        uint256[] memory ids = orders.ordersOf(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], a1);
        assertEq(ids[1], a2);
        assertEq(orders.ordersOf(bob)[0], b1);

        vm.prank(alice);
        orders.cancel(a1);
        (ConditionalOrders.Order memory o,) = orders.getOrder(orders.ordersOf(alice)[0]);
        assertEq(o.owner, address(0), "closed orders stay listed with a zero owner");
    }

    function test_orderAmountsAndPoolState() public {
        uint256 id = _create(alice);
        (uint256 a0, uint256 a1) = orders.orderAmounts(id);
        // 10e18 liquidity in [-600, 600] at price 1: ~0.2955 of each token
        assertApproxEqRel(a0, 0.2955e18, 0.001e18);
        assertApproxEqRel(a1, 0.2955e18, 0.001e18);
        (uint160 sqrtP, int24 tick, uint128 liq) = orders.poolState(hook.poolIndexOf(poolId));
        assertGt(sqrtP, 0);
        assertEq(tick, 0);
        assertEq(liq, 110e18); // 100e18 full range + this order
    }

    /// The owner swaps "exit above" for "exit below with a swap"; the range does not move, the new rule works.
    function test_updateOrderChangesRuleKeepsRange() public {
        uint256 id = _create(alice);
        OrderState.Side memory off;
        OrderState.Side memory low;
        low.checker = OrderState.CHECK_EDGE;
        low.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE | OrderState.ACT_SWAP;
        low.removeBps = 10_000;
        low.swapToToken1 = true;
        uint128 liqBefore = orders.orderLiquidity(id);

        vm.prank(alice);
        orders.updateOrder(id, _update(id, low, off));

        (ConditionalOrders.Order memory o, OrderState.State memory st) = orders.getOrder(id);
        assertEq(st.lower.edge, -600);
        assertEq(st.upper.edge, 600);
        assertEq(st.upper.checker, OrderState.CHECK_OFF);
        assertEq(st.lower.checker, OrderState.CHECK_EDGE);
        assertEq(o.maxKeeperFeeBps, 20);
        assertEq(o.maxSlippage, 30);
        assertEq(orders.orderLiquidity(id), liqBefore, "liquidity untouched");

        _swap(false, 5e18); // price up: the old rule would fire, the new one must not
        assertFalse(orders.canExecute(id, true));
        _swap(true, 12e18); // price down below the range: new rule fires
        assertTrue(orders.canExecute(id, false));
        vm.prank(keeper);
        orders.execute(id, false);
        assertEq(orders.orderLiquidity(id), 0);
    }

    function test_updateOrderRules() public {
        uint256 id = _create(alice);
        OrderState.Side memory off;

        vm.prank(bob);
        vm.expectRevert(ConditionalOrders.NotOwner.selector);
        orders.updateOrder(id, _update(id, off, _exitAbove()));

        vm.prank(alice);
        vm.expectRevert(ConditionalOrders.InvalidOrder.selector); // both sides off: use cancel instead
        orders.updateOrder(id, _update(id, off, off));

        OrderState.Side memory bad = _exitAbove();
        bad.repeat = true; // a repeating exit on a range that does not move would fire forever
        vm.prank(alice);
        vm.expectRevert(ConditionalOrders.InvalidSide.selector);
        orders.updateOrder(id, _update(id, off, bad));

        vm.prank(alice);
        orders.cancel(id);
        vm.prank(alice);
        vm.expectRevert(ConditionalOrders.UnknownOrder.selector);
        orders.updateOrder(id, _update(id, off, _exitAbove()));
    }
}
