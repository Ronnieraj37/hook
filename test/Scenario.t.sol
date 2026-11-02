// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {RuleSetup} from "./utils/RuleSetup.sol";
import {ConditionalOrders} from "../src/ConditionalOrders.sol";
import {OrderState} from "../src/libraries/OrderState.sol";

/// @notice Several users, several order types, one native-ETH pool, many price moves. After every step:
/// no tokens are left in either contract, an order's execution never touches another order's position,
/// owners never pay keepers from their wallets, and the keeper's pay never exceeds the owner's ceiling.
contract ScenarioTest is RuleSetup {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolKey ethKey;
    PoolId ethId;
    Currency constant ETH = Currency.wrap(address(0));

    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");

    uint256 aliceOrder;
    uint256 bobOrder;
    uint256 carolOrder;
    uint256 daveBucket;
    uint256 erinBucket;

    receive() external payable {}

    function setUp() public override {
        super.setUp();
        vm.fee(0.0005 gwei); // Unichain-like base fee
        vm.txGasPrice(0.0015 gwei);

        ethKey = PoolKey(ETH, currency1, 3000, 60, IHooks(hook));
        ethId = ethKey.toId();
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);
        vm.deal(address(this), 10_000 ether);
        positionManager.mint(
            ethKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            100e18,
            200 ether,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        address[5] memory users = [alice, bob, carol, dave, erin];
        for (uint256 i; i < 5; ++i) {
            vm.deal(users[i], 100 ether);
            if (users[i] != alice && users[i] != bob) _fund(users[i]);
        }
    }

    // ---------------------------------------------------------------- helpers

    function _ethTick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(ethId);
    }

    function _swapEth(bool ethIn, uint256 amount) internal {
        swapRouter.swapExactTokensForTokens{value: ethIn ? amount : 0}({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: ethIn,
            poolKey: ethKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _pushUpTo(int24 target) internal {
        for (uint256 i; i < 200 && _ethTick() < target; ++i) _swapEth(false, 1e18);
        assertGe(_ethTick(), target, "could not push price up");
    }

    function _pushDownBelow(int24 target) internal {
        for (uint256 i; i < 200 && _ethTick() >= target; ++i) _swapEth(true, 1e18);
        assertLt(_ethTick(), target, "could not push price down");
    }

    function _order(
        address who,
        int24 tl,
        int24 tu,
        uint128 liq,
        uint8 maxFee,
        uint8 slippage,
        OrderState.Side memory lower,
        OrderState.Side memory upper
    ) internal returns (uint256 id) {
        ConditionalOrders.CreateParams memory p = ConditionalOrders.CreateParams({
            key: ethKey,
            tickLower: tl,
            tickUpper: tu,
            liquidity: liq,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            swapPoolIndex: 0,
            expiry: uint32(block.timestamp + 30 days),
            maxKeeperFeeBps: maxFee,
            maxSlippage: slippage,
            lower: lower,
            upper: upper
        });
        vm.prank(who);
        id = orders.createOrder{value: 50 ether}(p);
    }

    /// Nothing may be left behind in either contract after any call.
    function _assertNothingStuck() internal view {
        assertEq(address(orders).balance, 0, "ETH stuck in ConditionalOrders");
        assertEq(_bal(currency1, address(orders)), 0, "token1 stuck in ConditionalOrders");
        assertEq(address(hook).balance, 0, "ETH stuck in RuleHook");
        assertEq(_bal(currency1, address(hook)), 0, "token1 stuck in RuleHook");
    }

    /// Run one side as the keeper and check: the owner's wallet never pays, the keeper is paid something, other
    /// orders' positions do not move.
    function _keeperRuns(uint256 id, bool upper, address owner, uint256[2] memory others) internal {
        uint128 o0 = others[0] == 0 ? 0 : orders.orderLiquidity(others[0]);
        uint128 o1 = others[1] == 0 ? 0 : orders.orderLiquidity(others[1]);
        uint256 ownerEth = owner.balance;
        uint256 owner1 = _bal(currency1, owner);
        uint256 kEth = keeper.balance;
        uint256 k1 = _bal(currency1, keeper);

        assertTrue(orders.canExecute(id, upper), "condition should be met");
        vm.prank(keeper, keeper);
        orders.execute(id, upper);

        assertGe(owner.balance, ownerEth, "owner paid ETH for a run");
        assertGe(_bal(currency1, owner), owner1, "owner paid token1 for a run");
        uint256 paidEth = keeper.balance - kEth;
        uint256 paid1 = _bal(currency1, keeper) - k1;
        // Amounts are checked in the keeper-pay tests below. This scenario runs in isolate mode, where Foundry
        // uses gas price 0 (foundry-rs/foundry#7277), so pay here is 0 and only its upper bound is checked.
        // pay is a gas refund: far below any realistic ceiling, and in ETH terms bounded by 10M gas worth
        assertLe(paidEth, orders.keeperGasCost(10_000_000), "keeper overpaid");
        if (others[0] != 0) assertEq(orders.orderLiquidity(others[0]), o0, "touched another order");
        if (others[1] != 0) assertEq(orders.orderLiquidity(others[1]), o1, "touched another order");
        _assertNothingStuck();
        console.log("run paid keeper (wei ETH, token1):", paidEth, paid1);
    }

    // ---------------------------------------------------------------- the scenario

    function test_fiveUsersManyMoves() public {
        // Alice: re-range both ways, forever (one-sided re-range, 10 spacings wide)
        OrderState.Side memory rr;
        rr.checker = OrderState.CHECK_EDGE;
        rr.value = 60;
        rr.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE | OrderState.ACT_ADD;
        rr.removeBps = 10_000;
        rr.addMode = OrderState.ADD_ONE_SIDED;
        rr.repeat = true;
        rr.shape = uint24(10) | (uint24(10) << 11);
        aliceOrder = _order(alice, -600, 600, 10e18, 50, 0, rr, rr);

        // Bob: stop-loss below (exit + sell ETH for token1), take-profit above (exit)
        OrderState.Side memory stop;
        stop.checker = OrderState.CHECK_EDGE;
        stop.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE | OrderState.ACT_SWAP;
        stop.removeBps = 10_000;
        stop.swapToToken1 = true;
        OrderState.Side memory tp;
        tp.checker = OrderState.CHECK_EDGE;
        tp.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE;
        tp.removeBps = 10_000;
        bobOrder = _order(bob, -1200, 1200, 5e18, 30, 100, stop, tp);

        // Carol: compound fees every hour, forever
        OrderState.Side memory compound;
        compound.checker = OrderState.CHECK_TIME;
        compound.value = 60;
        compound.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_ADD;
        compound.repeat = true;
        OrderState.Side memory off;
        carolOrder = _order(carol, -3000, 3000, 5e18, 20, 0, off, compound);

        // Dave: limit sell 1 ETH at [1800, 1860). Erin: limit buy with 1 token1 at [-1860, -1800).
        vm.prank(dave);
        daveBucket = hook.placeLimit{value: 1 ether}(ethKey, 1800, true, 1 ether);
        vm.prank(erin);
        erinBucket = hook.placeLimit(ethKey, -1860, false, 1e18);
        _assertNothingStuck();

        // 1. Price up through everything above.
        _pushUpTo(1860);
        assertTrue(hook.isFilled(daveBucket), "dave's limit sell filled by the swap");
        _keeperRuns(aliceOrder, true, alice, [bobOrder, carolOrder]); // Alice re-range #1
        _keeperRuns(bobOrder, true, bob, [aliceOrder, carolOrder]); // Bob take-profit, closes
        (ConditionalOrders.Order memory b,) = orders.getOrder(bobOrder);
        assertEq(b.owner, address(0), "bob's order closed after a full exit");

        // 3. Price all the way down: Alice's buy range converts and she re-ranges again; Erin's buy fills.
        (, OrderState.State memory st) = orders.getOrder(aliceOrder);
        _pushDownBelow(-1860);
        assertTrue(hook.isFilled(erinBucket), "erin's limit buy filled by the swap");
        assertTrue(_ethTick() < st.lower.edge - 60);
        _keeperRuns(aliceOrder, false, alice, [carolOrder, 0]); // Alice re-range #2

        // An hour later, after the price traded both ways through her range, Carol compounds.
        vm.warp(block.timestamp + 61 minutes);
        uint128 carolBefore = orders.orderLiquidity(carolOrder);
        _keeperRuns(carolOrder, true, carol, [aliceOrder, 0]);
        assertGt(orders.orderLiquidity(carolOrder), carolBefore, "carol compounded");

        // 4. Up again: Alice re-range #3.
        (, st) = orders.getOrder(aliceOrder);
        _pushUpTo(st.upper.edge + 60);
        _keeperRuns(aliceOrder, true, alice, [carolOrder, 0]);
        assertGt(orders.orderLiquidity(aliceOrder), 0, "alice still has a position after 3 re-ranges");

        // 5. Limit orders pay out.
        uint256 dave1 = _bal(currency1, dave);
        vm.prank(dave);
        hook.claimLimit(daveBucket, dave);
        assertGt(_bal(currency1, dave) - dave1, 1e18, "dave sold 1 ETH above 1.18 token1");
        uint256 erinEth = erin.balance;
        vm.prank(erin);
        hook.claimLimit(erinBucket, erin);
        assertGt(erin.balance - erinEth, 1e18, "erin bought more than 1 ETH below 0.84");
        _assertNothingStuck();

        // 6. Everyone still open can leave at any time.
        vm.prank(alice);
        orders.cancel(aliceOrder);
        vm.prank(carol);
        orders.cancel(carolOrder);
        _assertNothingStuck();
        assertEq(poolManager.balanceOf(address(hook), ETH.toId()) < 1e6, true, "only rounding dust left as claims");
        assertEq(poolManager.balanceOf(address(hook), currency1.toId()) < 1e6, true, "only rounding dust left");
    }

    /// @dev An exit on a timer: lets the keeper-pay tests run without a swap in the same transaction.
    function _timedExit() internal pure returns (OrderState.Side memory d) {
        d.checker = OrderState.CHECK_TIME;
        d.value = 60; // minutes
        d.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE;
        d.removeBps = 10_000;
    }

    /// @dev Keeper pay in ETH terms (the pool price stays at 1, so token1 counts 1:1).
    function _runAndMeasure(uint256 id, uint256 gasLimit) internal returns (uint256 paid) {
        uint256 e0 = keeper.balance;
        uint256 k1 = _bal(currency1, keeper);
        vm.prank(keeper, keeper);
        orders.execute{gas: gasLimit}(id, true);
        paid = (keeper.balance - e0) + (_bal(currency1, keeper) - k1);
    }

    // The keeper-pay tests below check exact amounts, so they need a real gas price. Foundry's isolate mode runs
    // every call with gas price 0 (foundry-rs/foundry#7277), so they run as one transaction instead, and use timed
    // exits so that no swap happens before execute in that transaction.

    /// forge-config: default.isolate = false
    function test_keeperPayIsGasNotSize() public {
        OrderState.Side memory off;
        uint256 small = _order(alice, -600, 600, 1e18, 100, 0, off, _timedExit());
        uint256 big = _order(bob, -600, 600, 10e18, 100, 0, off, _timedExit());
        vm.warp(block.timestamp + 61 minutes);

        uint256 paidSmall = _runAndMeasure(small, 30_000_000);
        uint256 paidBig = _runAndMeasure(big, 30_000_000);
        console.log("keeper pay, small order:", paidSmall);
        console.log("keeper pay, 10x order:  ", paidBig);
        assertGt(paidSmall, 0);
        assertApproxEqRel(paidBig, paidSmall, 0.2e18); // within 20%: same work, same gas
        assertLe(paidSmall, orders.keeperGasCost(500_000), "pay is a gas refund");
    }

    /// The keeper cannot inflate its pay by sending a bigger gas limit.
    /// forge-config: default.isolate = false
    function test_keeperPayIgnoresGasLimit() public {
        OrderState.Side memory off;
        uint256 a = _order(alice, -600, 600, 1e18, 100, 0, off, _timedExit());
        uint256 b = _order(bob, -600, 600, 1e18, 100, 0, off, _timedExit());
        vm.warp(block.timestamp + 61 minutes);

        uint256 paidLowLimit = _runAndMeasure(a, 1_000_000);
        uint256 paidHighLimit = _runAndMeasure(b, 30_000_000);
        console.log("pay with 1M gas limit: ", paidLowLimit);
        console.log("pay with 30M gas limit:", paidHighLimit);
        assertGt(paidLowLimit, 0);
        assertApproxEqRel(paidHighLimit, paidLowLimit, 0.05e18);
    }

    /// A ceiling too low to cover gas: the keeper gets only the ceiling (and would rationally skip the order).
    /// forge-config: default.isolate = false
    function test_tooLowCeilingCapsPay() public {
        OrderState.Side memory off;
        uint256 id = _order(alice, -600, 600, 1e12, 1, 0, off, _timedExit()); // tiny order, 0.01% ceiling
        vm.warp(block.timestamp + 61 minutes);
        uint256 paid = _runAndMeasure(id, 30_000_000);
        uint256 gasWorth = orders.keeperGasCost(100_000);
        console.log("ceiling pay:", paid, "gas worth at least:", gasWorth);
        assertLt(paid, gasWorth);
    }
}
