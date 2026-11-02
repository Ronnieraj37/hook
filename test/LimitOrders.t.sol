// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {console} from "forge-std/console.sol";
import {RuleSetup} from "./utils/RuleSetup.sol";
import {RuleHook} from "../src/RuleHook.sol";
import {ConditionalOrders} from "../src/ConditionalOrders.sol";
import {OrderState} from "../src/libraries/OrderState.sol";

contract LimitOrdersTest is RuleSetup {
    using StateLibrary for IPoolManager;

    function _place(address who, int24 tickLower, bool sellToken0, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = hook.placeLimit(poolKey, tickLower, sellToken0, amount);
    }

    function _filled(uint256 id) internal view returns (bool) {
        return hook.isFilled(id);
    }

    function _bucketLiquidity(uint256 id, int24 tickLower) internal view returns (uint128) {
        return poolManager.getPositionLiquidity(
            poolId, Position.calculatePositionKey(address(hook), tickLower, tickLower + 60, hook.epochSalt(id))
        );
    }

    function test_place_mustBeOnTheRightSide() public {
        vm.prank(alice);
        vm.expectRevert(RuleHook.WrongSide.selector); // tick 0 is not below [0, 60]
        hook.placeLimit(poolKey, 0, true, 1e18);

        vm.prank(alice);
        vm.expectRevert(RuleHook.WrongSide.selector); // a sell-token1 bucket must be below the price
        hook.placeLimit(poolKey, 0, false, 1e18);

        vm.prank(alice);
        vm.expectRevert(RuleHook.BadTick.selector); // not a multiple of the spacing
        hook.placeLimit(poolKey, 61, true, 1e18);

        uint256 before = _bal(currency0, alice);
        uint256 id = _place(alice, 60, true, 1e18);
        assertLe(before - _bal(currency0, alice), 1e18);
        assertGt(_bucketLiquidity(id, 60), 0);
        assertEq(hook.openEpoch(poolId, 60, true), id);
    }

    function test_swapUpFillsSellBucket_thenClaim() public {
        uint256 id = _place(alice, 60, true, 1e18);

        _swap(false, 5e18); // price up through [60, 120]
        assertGe(_tick(), 120);

        assertTrue(_filled(id));
        assertEq(_bucketLiquidity(id, 60), 0);
        assertEq(hook.openEpoch(poolId, 60, true), 0);

        uint256 b1 = _bal(currency1, alice);
        vm.prank(alice);
        (uint256 got0, uint256 got1) = hook.claimLimit(id, alice);
        assertEq(got0, 0);
        // sold 1 token0 at prices between 1.0060 and 1.0121, plus fees
        assertGt(got1, 1.006e18);
        assertLt(got1, 1.02e18);
        assertEq(_bal(currency1, alice) - b1, got1);

        vm.prank(alice);
        vm.expectRevert(RuleHook.NothingToClaim.selector);
        hook.claimLimit(id, alice);
    }

    function test_swapDownFillsBuyBucket() public {
        uint256 id = _place(alice, -120, false, 1e18); // sell token1 in [-120, -60]

        _swap(true, 5e18);
        assertLt(_tick(), -120);
        assertTrue(_filled(id));

        vm.prank(alice);
        (uint256 got0, uint256 got1) = hook.claimLimit(id, alice);
        assertGt(got0, 1e18); // bought token0 below 1.0
        assertEq(got1, 0);
    }

    function test_usersShareOneBucketProRata() public {
        uint256 idA = _place(alice, 60, true, 1e18);
        uint256 idB = _place(bob, 60, true, 3e18);
        assertEq(idA, idB); // same bucket, same position

        _swap(false, 10e18);
        assertTrue(_filled(idA));

        vm.prank(alice);
        (, uint256 a1) = hook.claimLimit(idA, alice);
        vm.prank(bob);
        (, uint256 b1) = hook.claimLimit(idB, bob);
        assertApproxEqRel(b1, a1 * 3, 1e15);
    }

    function test_partlyCrossedBucketIsNotFilled_cancelReturnsMix() public {
        uint256 id = _place(alice, 60, true, 1e18);

        _swap(false, 0.5e18); // ends inside the bucket
        int24 t = _tick();
        assertGe(t, 60);
        assertLt(t, 120);
        assertFalse(_filled(id));

        uint256 b0 = _bal(currency0, alice);
        uint256 b1 = _bal(currency1, alice);
        vm.prank(alice);
        hook.cancelLimit(id, alice);
        assertGt(_bal(currency0, alice) - b0, 0);
        assertGt(_bal(currency1, alice) - b1, 0);
        assertEq(_bucketLiquidity(id, 60), 0);
        assertEq(hook.openEpoch(poolId, 60, true), 0);
    }

    function test_everyCrossedBucketIsFilled() public {
        uint256[10] memory ids;
        for (uint256 i; i < 10; ++i) {
            ids[i] = _place(alice, int24(int256(60 * (i + 1))), true, 1e18);
        }
        // one more bucket the swap will only partly cross
        uint256 partlyCrossed = _place(alice, 1_200, true, 1e18);

        _swap(false, 14e18);
        int24 t = _tick();
        assertGe(t, 660); // all ten buckets [60,120) .. [600,660) fully crossed
        for (uint256 i; i < 10; ++i) {
            assertTrue(_filled(ids[i]));
        }
        if (t < 1_260) assertFalse(_filled(partlyCrossed)); // not fully crossed, so not filled
    }

    /// Alice is alone in the bucket while the price trades inside it, so she alone earns those fees.
    /// Bob joins later with 3x her size. Fees earned before Bob joined must all go to Alice.
    function test_feesEarnedBeforeAJoinStayWithEarlierHolders() public {
        uint256 id = _place(alice, 60, true, 1e18);

        _swap(false, 0.5e18); // into the bucket: Alice's position trades and earns fees
        assertGe(_tick(), 60);
        _swap(true, 0.6e18); // back below it: bucket is all token0 again, fees still inside the position
        assertLt(_tick(), 60);

        _place(bob, 60, true, 3e18); // joining collects the fees so far and credits them to Alice only
        (,,,,,,,, uint256 perLiq0, uint256 perLiq1) = hook.epochs(id);
        assertGt(perLiq0 + perLiq1, 0);

        _swap(false, 10e18); // fill
        assertTrue(_filled(id));

        (uint256 a0, uint256 a1) = hook.claimable(id, alice);
        (uint256 b0, uint256 b1) = hook.claimable(id, bob);
        (uint128 aliceLiq,,) = hook.shares(id, alice);
        uint256 preJoin0 = (uint256(aliceLiq) * perLiq0) >> 128;
        uint256 preJoin1 = (uint256(aliceLiq) * perLiq1) >> 128;
        console.log("fees earned before Bob joined, token0:", preJoin0);
        console.log("fees earned before Bob joined, token1:", preJoin1);
        console.log("alice gets token0, token1:", a0, a1);
        console.log("bob   gets token0, token1:", b0, b1);

        // Everything after the join is split 1:3, so alice - bob/3 = what she earned alone.
        assertApproxEqAbs(a0 - b0 / 3, preJoin0, 2);
        assertApproxEqAbs(a1 - b1 / 3, preJoin1, 2);
        assertGt(preJoin0, 0); // the move back down paid fees in token0, only Alice was there
        assertEq(b0, 0);
    }

    function test_fillBucket_needsFullCross() public {
        _place(alice, 60, true, 1e18);
        vm.prank(keeper);
        vm.expectRevert(RuleHook.NotCrossed.selector);
        hook.fillBucket(poolKey, 60, true);
    }

    function test_conditionalOrderSwapFillsBuckets() public {
        // alice: buy bucket in [-240, -180]
        uint256 bucket = _place(alice, -240, false, 0.01e18);

        // bob: exit below -120 and sell everything into token1
        OrderState.Side memory low;
        low.checker = OrderState.CHECK_EDGE;
        low.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE | OrderState.ACT_SWAP;
        low.removeBps = 10_000;
        low.swapToToken1 = true;
        OrderState.Side memory off;
        ConditionalOrders.CreateParams memory p = ConditionalOrders.CreateParams({
            key: poolKey,
            tickLower: -120,
            tickUpper: 120,
            liquidity: 150e18,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            swapPoolIndex: 0,
            expiry: uint32(block.timestamp + 1 days),
            maxKeeperFeeBps: 10,
            maxSlippage: 100, // 1,000 ticks
            lower: low,
            upper: off
        });
        vm.prank(bob);
        uint256 orderId = orders.createOrder(p);

        _swap(true, 1.6e18); // price just below bob's range, above the bucket
        int24 t = _tick();
        assertLt(t, -120);
        assertGt(t, -180);
        assertFalse(_filled(bucket));

        vm.prank(keeper);
        orders.execute(orderId, false); // bob's instant swap pushes the price through the bucket
        assertLt(_tick(), -240);
        assertTrue(_filled(bucket));
    }

    /// Random sizes, a random wiggle inside the bucket, a random leaver: every payout succeeds, nobody is paid more
    /// than the hook holds, and only rounding dust is left behind.
    function testFuzz_payoutsNeverExceedWhatTheHookHolds(uint96 aAmt, uint96 bAmt, uint96 wiggle, bool bobLeaves)
        public
    {
        uint256 a = bound(aAmt, 1e15, 50e18);
        uint256 b = bound(bAmt, 1e15, 50e18);
        uint256 w = bound(wiggle, 0, 0.3e18);

        uint256 id = _place(alice, 60, true, a);
        if (w > 0) {
            _swap(false, w); // maybe into the bucket
            if (_tick() >= 60) _swap(true, w + 0.1e18); // and back out
        }
        if (_tick() < 60) {
            _place(bob, 60, true, b);
            if (bobLeaves) {
                vm.prank(bob);
                hook.cancelLimit(id, bob);
            }
        }

        _swap(false, 200e18);
        assertTrue(_filled(id));
        uint256 id0 = currency0.toId();
        uint256 id1 = currency1.toId();
        vm.prank(alice);
        hook.claimLimit(id, alice);
        (uint128 bobLiq,,) = hook.shares(id, bob);
        if (bobLiq > 0) {
            vm.prank(bob);
            hook.claimLimit(id, bob);
        }
        // everything owed was paid out of the hook's own claims; what is left is rounding dust
        assertLt(poolManager.balanceOf(address(hook), id0), 10);
        assertLt(poolManager.balanceOf(address(hook), id1), 10);
    }
}
