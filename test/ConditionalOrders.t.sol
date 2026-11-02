// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {RuleSetup} from "./utils/RuleSetup.sol";
import {ConditionalOrders} from "../src/ConditionalOrders.sol";
import {OrderState} from "../src/libraries/OrderState.sol";

contract ConditionalOrdersTest is RuleSetup {
    using StateLibrary for IPoolManager;

    int24 constant TL = -600;
    int24 constant TU = 600;
    uint128 constant LIQ = 10e18;

    // ------------------------------------------------------------------ helpers

    function _off() internal pure returns (OrderState.Side memory s) {}

    function _side(uint8 checker, int24 value, uint8 actions, uint16 removeBps)
        internal
        pure
        returns (OrderState.Side memory s)
    {
        s.checker = checker;
        s.value = value;
        s.actions = actions;
        s.removeBps = removeBps;
    }

    function _create(OrderState.Side memory lower, OrderState.Side memory upper, uint8 feeBps, uint8 slippage)
        internal
        returns (uint256 id)
    {
        ConditionalOrders.CreateParams memory p = ConditionalOrders.CreateParams({
            key: poolKey,
            tickLower: TL,
            tickUpper: TU,
            liquidity: LIQ,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            swapPoolIndex: 0,
            expiry: uint32(block.timestamp + 30 days),
            maxKeeperFeeBps: feeBps,
            maxSlippage: slippage,
            lower: lower,
            upper: upper
        });
        vm.prank(alice);
        id = orders.createOrder(p);
    }

    function _hookLiquidity(int24 tl, int24 tu, uint256 id) internal view returns (uint128) {
        return poolManager.getPositionLiquidity(
            poolId, Position.calculatePositionKey(address(orders), tl, tu, bytes32(id))
        );
    }

    // ------------------------------------------------------------------ tests

    function test_poolRegisteredOnInitialize() public view {
        assertEq(hook.poolCount(), 1);
        assertEq(hook.poolIndexOf(poolId), 1);
    }

    function test_createHoldsPositionAndCancelReturnsTokens() public {
        uint256 a0 = _bal(currency0, alice);
        uint256 a1 = _bal(currency1, alice);

        uint256 id = _create(_off(), _side(OrderState.CHECK_EDGE, 0, OrderState.ACT_REMOVE, 10_000), 10, 0);
        assertEq(_hookLiquidity(TL, TU, id), LIQ);
        assertEq(orders.orderLiquidity(id), LIQ);
        assertLt(_bal(currency0, alice), a0);

        vm.prank(keeper);
        vm.expectRevert(ConditionalOrders.NotOwner.selector);
        orders.cancel(id);

        vm.prank(alice);
        orders.cancel(id);
        assertEq(_hookLiquidity(TL, TU, id), 0);
        // back to the start, less rounding
        assertApproxEqAbs(_bal(currency0, alice), a0, 2);
        assertApproxEqAbs(_bal(currency1, alice), a1, 2);
        (ConditionalOrders.Order memory o,) = orders.getOrder(id);
        assertEq(o.owner, address(0));
    }

    function test_upperExit_onlyWhenPriceLeavesRange() public {
        uint256 id = _create(_off(), _side(OrderState.CHECK_EDGE, 0, OrderState.ACT_REMOVE, 10_000), 10, 0);

        vm.prank(keeper);
        vm.expectRevert();
        orders.execute(id, true);
        assertFalse(orders.canExecute(id, true));

        _swap(false, 20e18); // price up
        assertGe(_tick(), TU);
        assertTrue(orders.canExecute(id, true));

        uint256 a0 = _bal(currency0, alice);
        uint256 a1 = _bal(currency1, alice);
        vm.prank(keeper);
        orders.execute(id, true);

        // above the range the position is all token1
        uint256 got1 = _bal(currency1, alice) - a1;
        assertEq(_bal(currency0, alice), a0);
        assertGt(got1, 0);
        uint256 fee1 = _bal(currency1, keeper);
        assertGt(fee1, 0);
        assertApproxEqRel(fee1 * 10_000, (got1 + fee1) * 10, 1e15); // keeper got 10 bps
        assertEq(_hookLiquidity(TL, TU, id), 0);
        (ConditionalOrders.Order memory o,) = orders.getOrder(id);
        assertEq(o.owner, address(0)); // closed
    }

    function test_lowerExit_instantSwapToToken1() public {
        // keep-fees bit set, so the earned fees are swapped too
        OrderState.Side memory low = _side(
            OrderState.CHECK_EDGE,
            0,
            OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE | OrderState.ACT_SWAP,
            10_000
        );
        low.swapToToken1 = true;
        uint256 id = _create(low, _off(), 10, 100); // 1,000 ticks

        _swap(true, 5e18); // price down below the range
        assertLt(_tick(), TL);

        uint256 a0 = _bal(currency0, alice);
        uint256 a1 = _bal(currency1, alice);
        vm.prank(keeper);
        orders.execute(id, false);

        assertEq(_bal(currency0, alice), a0); // all token0 was sold
        assertGt(_bal(currency1, alice) - a1, 0);
    }

    function test_lowerExit_swapSkippedWhenPricePastLimit() public {
        OrderState.Side memory low =
            _side(OrderState.CHECK_EDGE, 0, OrderState.ACT_REMOVE | OrderState.ACT_SWAP, 10_000);
        low.swapToToken1 = true;
        uint256 id = _create(low, _off(), 10, 10); // limit = -600 - 100 = -700

        _swap(true, 5e18);
        assertLt(_tick(), -700);

        uint256 a0 = _bal(currency0, alice);
        uint256 a1 = _bal(currency1, alice);
        vm.prank(keeper);
        orders.execute(id, false);

        assertGt(_bal(currency0, alice) - a0, 0); // kept token0, not sold at a bad price
        assertEq(_bal(currency1, alice), a1);
    }

    function test_rerangeOneSided_repeats() public {
        uint8 acts = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE | OrderState.ACT_ADD;
        OrderState.Side memory up = _side(OrderState.CHECK_EDGE, 60, acts, 10_000);
        up.addMode = OrderState.ADD_ONE_SIDED;
        up.repeat = true;
        up.shape = uint24(10) | (uint24(10) << 11); // 10 spacings below, 10 above
        OrderState.Side memory low = up;
        uint256 id = _create(low, up, 10, 0);

        _swap(false, 20e18);
        int24 t = _tick();
        assertGe(t, TU + 60);

        vm.prank(keeper);
        orders.execute(id, true);

        int24 floorTick = (t / 60) * 60;
        (ConditionalOrders.Order memory o, OrderState.State memory st) = orders.getOrder(id);
        assertEq(o.owner, alice); // still open
        assertEq(st.upper.edge, floorTick);
        assertEq(st.lower.edge, floorTick - 600);
        assertEq(st.upper.lastRun, 0); // only TIME sides keep a last-run time
        assertEq(_hookLiquidity(TL, TU, id), 0);
        assertGt(_hookLiquidity(st.lower.edge, st.upper.edge, id), 0);
        assertEq(st.upper.checker, OrderState.CHECK_EDGE); // repeat kept the side

        // cannot be run again straight away
        assertFalse(orders.canExecute(id, true));
        vm.prank(keeper);
        vm.expectRevert();
        orders.execute(id, true);
    }

    function test_timeCompound() public {
        OrderState.Side memory up =
            _side(OrderState.CHECK_TIME, 60, OrderState.ACT_KEEP_FEES | OrderState.ACT_ADD, 0);
        up.repeat = true;
        uint256 id = _create(_off(), up, 10, 0);

        _swap(true, 1e18);
        _swap(false, 1e18);

        vm.prank(keeper);
        vm.expectRevert();
        orders.execute(id, true);

        vm.warp(block.timestamp + 61 minutes);
        uint128 before = _hookLiquidity(TL, TU, id);
        vm.prank(keeper);
        orders.execute(id, true);
        assertGt(_hookLiquidity(TL, TU, id), before);

        (, OrderState.State memory st) = orders.getOrder(id);
        assertGe(st.upper.lastRun, block.timestamp);
        assertLt(st.upper.lastRun, block.timestamp + 60);
    }

    function test_tickStopLoss_otherSideStaysActive() public {
        // lower: stop at a fixed level, sell everything; upper: take profit at the range edge
        OrderState.Side memory low =
            _side(OrderState.CHECK_TICK, -300, OrderState.ACT_REMOVE | OrderState.ACT_SWAP, 10_000);
        low.swapToToken1 = true;
        uint256 id = _create(low, _side(OrderState.CHECK_EDGE, 0, OrderState.ACT_REMOVE, 10_000), 10, 50);

        _swap(true, 2e18);
        assertLt(_tick(), -300);
        assertFalse(orders.canExecute(id, true));

        vm.prank(keeper);
        orders.execute(id, false);
        (ConditionalOrders.Order memory o,) = orders.getOrder(id);
        assertEq(o.owner, address(0)); // full exit closes the order
    }

    function test_rejectsBadSides() public {
        ConditionalOrders.CreateParams memory p;
        p.key = poolKey;
        p.tickLower = TL;
        p.tickUpper = TU;
        p.liquidity = LIQ;
        p.amount0Max = type(uint128).max;
        p.amount1Max = type(uint128).max;
        p.expiry = uint32(block.timestamp + 1 days);

        // EDGE + repeat without moving the range
        p.upper = _side(OrderState.CHECK_EDGE, 0, OrderState.ACT_REMOVE, 5_000);
        p.upper.repeat = true;
        vm.prank(alice);
        vm.expectRevert(ConditionalOrders.InvalidSide.selector);
        orders.createOrder(p);

        // swap and add together (swap-to-ratio is not in v1)
        p.upper = _side(OrderState.CHECK_EDGE, 0, OrderState.ACT_REMOVE | OrderState.ACT_SWAP | OrderState.ACT_ADD, 10_000);
        vm.prank(alice);
        vm.expectRevert(ConditionalOrders.InvalidSide.selector);
        orders.createOrder(p);

        // keeper fee above the cap
        p.upper = _side(OrderState.CHECK_EDGE, 0, OrderState.ACT_REMOVE, 10_000);
        p.maxKeeperFeeBps = 101;
        vm.prank(alice);
        vm.expectRevert(ConditionalOrders.InvalidOrder.selector);
        orders.createOrder(p);
    }

    function _sideFrom(uint256 seed, int24 edge, uint32 minutesAfterBase)
        internal
        pure
        returns (OrderState.Side memory d)
    {
        d.edge = edge;
        d.checker = uint8(seed % 16);
        d.value = int24(uint24(seed >> 8));
        // aux holds the pool for TICK and lastRun for TIME; other checkers leave both zero
        if (d.checker == OrderState.CHECK_TICK) d.checkPool = uint24(seed >> 32);
        d.actions = uint8((seed >> 48) % 16);
        d.removeBps = uint16((seed >> 56) % 10_001);
        d.swapToToken1 = (seed >> 72) & 1 == 1;
        d.addMode = uint8((seed >> 80) % 4);
        d.repeat = (seed >> 88) & 1 == 1;
        d.shape = uint24((seed >> 96) % (OrderState.MAX_SHAPE + 1));
        if (d.checker == OrderState.CHECK_TIME) {
            d.lastRun = uint32(OrderState.BASE_TIME + uint256(minutesAfterBase % 0xFFFFFF + 1) * 60);
        }
    }

    /// Any tick, either sign, on either side, round-trips; the two halves never mix.
    function testFuzz_orderStateRoundTrip(int24 tl, int24 tu, uint32 m1, uint32 m2, uint256 seedA, uint256 seedB)
        public
        pure
    {
        OrderState.State memory st;
        st.lower = _sideFrom(seedA, int24(bound(tl, TickMath.MIN_TICK, TickMath.MAX_TICK)), m1);
        st.upper = _sideFrom(seedB, int24(bound(tu, TickMath.MIN_TICK, TickMath.MAX_TICK)), m2);

        uint256 word = OrderState.encode(st);
        OrderState.State memory back = OrderState.decode(word);
        assertEq(abi.encode(back), abi.encode(st));

        // each half decodes on its own
        assertEq(abi.encode(OrderState.side(word, false)), abi.encode(st.lower));
        assertEq(abi.encode(OrderState.side(word, true)), abi.encode(st.upper));
        // changing the upper side leaves the lower 128 bits untouched
        st.upper.edge = -st.upper.edge / 2;
        st.upper.checker = 0;
        assertEq(OrderState.encode(st) & type(uint128).max, word & type(uint128).max);
    }

    /// A TICK side can point at any of 16.7M pools, e.g. pool #603,900 (550 tokens, 4 fee tiers).
    function test_checkPoolIndexAbove255() public pure {
        OrderState.State memory st;
        st.lower.edge = -600;
        st.lower.checker = OrderState.CHECK_TICK;
        st.lower.value = -300;
        st.lower.checkPool = 603_900;
        st.upper.edge = 600;
        st.upper.checker = OrderState.CHECK_TIME;
        st.upper.value = 10_080; // 7 days in minutes
        st.upper.lastRun = uint32(OrderState.BASE_TIME + 1_000 * 60);
        OrderState.State memory back = OrderState.decode(OrderState.encode(st));
        assertEq(back.lower.checkPool, 603_900);
        assertEq(back.lower.value, -300);
        assertEq(back.upper.lastRun, st.upper.lastRun);
        assertEq(back.upper.value, 10_080);
    }

    /// Your examples: ranges on either side of zero.
    function test_layoutExamples() public pure {
        int24[2][4] memory ranges = [
            [int24(900), int24(1100)], // both positive
            [int24(-100), int24(2000)], // straddles zero
            [int24(-202560), int24(-198480)], // both negative (an ETH/USDC-style raw price)
            [TickMath.MIN_TICK, TickMath.MAX_TICK] // the extremes
        ];
        for (uint256 i; i < 4; ++i) {
            OrderState.State memory st;
            st.lower.edge = ranges[i][0];
            st.upper.edge = ranges[i][1];
            uint256 word = OrderState.encode(st);
            assertEq(OrderState.side(word, false).edge, ranges[i][0]);
            assertEq(OrderState.side(word, true).edge, ranges[i][1]);
            // lower edge sits in bits 0-23, upper edge in bits 128-151, as plain 24-bit two's complement
            assertEq(word & 0xFFFFFF, uint256(uint24(ranges[i][0])));
            assertEq((word >> 128) & 0xFFFFFF, uint256(uint24(ranges[i][1])));
        }
    }
}
