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
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {RuleSetup} from "./utils/RuleSetup.sol";
import {RuleHook} from "../src/RuleHook.sol";
import {ConditionalOrders} from "../src/ConditionalOrders.sol";
import {OrderState} from "../src/libraries/OrderState.sol";

/// @notice Anti-dust (minimum size, per-swap cap, backlog) on the ERC20 pool.
contract AntiDustTest is RuleSetup {
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    function _place(address who, int24 tl, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = hook.placeLimit(poolKey, tl, true, amount);
    }

    function _backlogUp() internal view returns (bool on, int24 lo, int24 hi) {
        (lo, hi,,, on,) = hook.backlog(poolId);
    }

    /// 0.01% of the pool's 100e18 active liquidity is 1e16. A 1e13 token bucket is ~3.3e15 liquidity: too small.
    function test_bucketBelowMinimumIsNotFilledBySwaps() public {
        uint256 small = _place(alice, 60, 1e13);
        (uint128 smallLiq,,,,,,,,,) = hook.epochs(small);
        assertLt(uint256(smallLiq) * 10_000, uint256(poolManager.getLiquidity(poolId)) * hook.MIN_FILL_BPS());
        uint256 big = _place(bob, 120, 1e18);

        _swap(false, 5e18);
        assertGe(_tick(), 180);
        assertFalse(hook.isFilled(small), "dust bucket must not cost swappers gas");
        assertTrue(hook.isFilled(big));

        vm.prank(keeper);
        uint256 reward = hook.fillBucket(poolKey, 60, true);
        assertTrue(hook.isFilled(small));
        assertEq(reward, 0, "no reward outside native-ETH pools yet");

        uint256 before = _bal(currency1, alice);
        vm.prank(alice);
        hook.claimLimit(small, alice);
        assertGt(_bal(currency1, alice), before);
    }

    /// A small join does not make a big bucket ineligible; a cancel that leaves dust removes it from swap fills.
    function test_cancelDownToDustRemovesBucketFromSwapFills() public {
        uint256 id = _place(alice, 60, 1e18); // eligible
        _place(bob, 60, 1e13); // tiny join into the same bucket
        vm.prank(alice);
        hook.cancelLimit(id, alice); // only bob's dust is left

        _swap(false, 5e18);
        assertGe(_tick(), 120);
        assertFalse(hook.isFilled(id), "a bucket left as dust is not filled inside swaps");
    }

    /// 200 dust buckets crossed by one swap: the hook adds almost nothing. Uniswap itself still pays to cross the
    /// 200 initialized ticks, exactly as it would for 200 tiny normal LP positions (that cost exists in every v4
    /// pool, with or without this hook), so the test compares against that.
    function test_dustAttackAddsAlmostNothingFromTheHook() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 200; ++i) {
            int24 tl = int24(int256(60 * (i + 1)));
            positionManager.mint(
                poolKey, tl, tl + 60, 3e12, type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
            );
        }
        uint256 gPlain = _swapGas(false, 120e18);
        int24 tPlain = _tick();
        vm.revertToState(snap);

        for (uint256 i; i < 200; ++i) {
            _place(alice, int24(int256(60 * (i + 1))), 1e10);
        }
        uint256 gDust = _swapGas(false, 120e18);
        assertGe(_tick(), 60 * 201);
        assertApproxEqAbs(_tick(), tPlain, 1);
        console.log("swap gas, 200 tiny normal LP positions:", gPlain);
        console.log("swap gas, 200 dust limit buckets:", gDust);
        assertLt(gDust, gPlain + 50_000, "the hook adds almost nothing for dust buckets");
    }

    function _swapGas(bool zeroForOne, uint256 amount) internal returns (uint256 used) {
        uint256 g = gasleft();
        _swap(zeroForOne, amount);
        used = g - gasleft();
    }

    /// 60 real buckets crossed in one swap: 50 are filled, 10 wait in the backlog, the next swap fills them.
    function test_capFillsFiftyAndBacklogFinishesTheRest() public {
        uint256[60] memory ids;
        for (uint256 i; i < 60; ++i) {
            ids[i] = _place(alice, int24(int256(60 * (i + 1))), 0.1e18);
        }
        uint256 g = gasleft();
        _swap(false, 60e18);
        uint256 used = g - gasleft();
        assertGe(_tick(), 60 * 61, "all 60 buckets fully crossed");
        console.log("swap crossing 60 buckets, gas:", used);

        for (uint256 i; i < 60; ++i) {
            assertEq(hook.isFilled(ids[i]), i < 50, "lowest 50 filled, rest waiting");
        }
        (bool on, int24 lo,) = _backlogUp();
        assertTrue(on);
        assertEq(lo, 60 * 50, "backlog starts after the last filled bucket");

        _swap(false, 0.01e18); // any later swap finishes the backlog first
        for (uint256 i; i < 60; ++i) {
            assertTrue(hook.isFilled(ids[i]));
        }
        (on,,) = _backlogUp();
        assertFalse(on, "backlog cleared");
    }

    /// Backlog buckets can also be filled by anyone with fillBucket.
    function test_backlogBucketFillableByAnyone() public {
        uint256[55] memory ids;
        for (uint256 i; i < 55; ++i) {
            ids[i] = _place(alice, int24(int256(60 * (i + 1))), 0.1e18);
        }
        _swap(false, 60e18);
        assertFalse(hook.isFilled(ids[54]));
        vm.prank(keeper);
        hook.fillBucket(poolKey, 60 * 55, true);
        assertTrue(hook.isFilled(ids[54]));

        _swap(false, 0.01e18); // the rest of the backlog; the already-filled one is skipped
        for (uint256 i; i < 55; ++i) {
            assertTrue(hook.isFilled(ids[i]));
        }
    }

    /// If the price comes back before the backlog is filled, buckets no longer fully crossed become live orders
    /// again (nothing lost); they fill the next time the price crosses them.
    function test_priceReturnsBeforeBacklog_bucketsStayLive() public {
        uint256[60] memory ids;
        for (uint256 i; i < 60; ++i) {
            ids[i] = _place(alice, int24(int256(60 * (i + 1))), 0.1e18);
        }
        _swap(false, 60e18);
        _swap(true, 3e18); // back down a little
        int24 t = _tick();
        for (uint256 i; i < 60; ++i) {
            int24 tl = int24(int256(60 * (i + 1)));
            if (tl + 60 <= t) assertTrue(hook.isFilled(ids[i]), "still fully crossed: filled");
        }
        (bool on,,) = _backlogUp();
        assertFalse(on);

        _swap(false, 20e18); // up again past everything
        for (uint256 i; i < 60; ++i) {
            assertTrue(hook.isFilled(ids[i]));
        }
        // and every user payout still adds up
        for (uint256 i; i < 60; ++i) {
            vm.prank(alice);
            hook.claimLimit(ids[i], alice);
        }
        assertLt(poolManager.balanceOf(address(hook), currency0.toId()), 100);
        assertLt(poolManager.balanceOf(address(hook), currency1.toId()), 100);
    }

    function test_claimToAnotherAddress() public {
        uint256 id = _place(alice, 60, 1e18);
        _swap(false, 5e18);
        uint256 before = _bal(currency1, bob);
        vm.prank(alice);
        (, uint256 got1) = hook.claimLimit(id, bob);
        assertEq(_bal(currency1, bob) - before, got1);
    }
}

/// @dev An owner that is a contract and normally refuses ETH (like some multisigs).
contract NoEthOwner {
    bool public accept;

    receive() external payable {
        require(accept, "no ETH");
    }

    function create(ConditionalOrders o, ConditionalOrders.CreateParams calldata p) external payable returns (uint256 id) {
        accept = true; // let the creation refund through
        id = o.createOrder{value: msg.value}(p);
        accept = false;
    }

    function approve(address token, address spender) external {
        MockERC20(token).approve(spender, type(uint256).max);
    }

    function cancel(ConditionalOrders o, uint256 id) external {
        o.cancel(id);
    }

    function withdraw(ConditionalOrders o, Currency c, address to) external returns (uint256) {
        return o.withdraw(c, to);
    }
}

/// @notice Payout credit and fill rewards. Uses a native-ETH pool.
contract PayoutTest is RuleSetup {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolKey ethKey;
    PoolId ethId;
    Currency constant ETH = Currency.wrap(address(0));
    NoEthOwner dao;

    receive() external payable {}

    function setUp() public override {
        super.setUp();
        vm.fee(0.0005 gwei);
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
        dao = new NoEthOwner();
        MockERC20(Currency.unwrap(currency1)).transfer(address(dao), 1_000e18);
        dao.approve(Currency.unwrap(currency1), address(orders));
        vm.deal(alice, 100 ether);
    }

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

    function _exitBelowParams(PoolKey memory key) internal view returns (ConditionalOrders.CreateParams memory p) {
        OrderState.Side memory low;
        low.checker = OrderState.CHECK_EDGE;
        low.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE;
        low.removeBps = 10_000;
        OrderState.Side memory off;
        p = ConditionalOrders.CreateParams({
            key: key,
            tickLower: -600,
            tickUpper: 600,
            liquidity: 10e18,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            swapPoolIndex: 0,
            expiry: uint32(block.timestamp + 30 days),
            maxKeeperFeeBps: 10,
            maxSlippage: 0,
            lower: low,
            upper: off
        });
    }

    /// The DAO's exit fires, the ETH cannot be sent to it, the order still completes and the ETH is held for it.
    /// A timed exit, so the test can run as one transaction with a real gas price (Foundry's isolate mode uses
    /// gas price 0, foundry-rs/foundry#7277) and still check that the keeper is paid.
    /// forge-config: default.isolate = false
    function test_executeWithOwnerThatRejectsEth_creditsAndWithdraws() public {
        ConditionalOrders.CreateParams memory p = _exitBelowParams(ethKey);
        OrderState.Side memory off;
        p.lower = off;
        p.upper.checker = OrderState.CHECK_TIME;
        p.upper.value = 60; // minutes
        p.upper.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE;
        p.upper.removeBps = 10_000;
        uint256 id = dao.create{value: 1 ether}(orders, p);
        uint256 daoEth = address(dao).balance; // the creation refund
        vm.warp(block.timestamp + 61 minutes);

        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper, keeper);
        orders.execute(id, true); // does not revert
        assertGt(keeper.balance, keeperBefore, "keeper still paid");

        uint256 held = orders.owed(address(dao), ETH);
        assertGt(held, 0.2 ether, "the DAO's ETH is held, not lost");
        assertEq(address(orders).balance, held, "contract holds exactly what it owes");
        assertEq(address(dao).balance, daoEth, "nothing reached the DAO");

        address treasury = makeAddr("treasury");
        assertEq(dao.withdraw(orders, ETH, treasury), held);
        assertEq(treasury.balance, held);
        assertEq(orders.owed(address(dao), ETH), 0);
        vm.expectRevert(ConditionalOrders.NothingOwed.selector);
        dao.withdraw(orders, ETH, treasury);
    }

    function test_cancelWithOwnerThatRejectsEth_neverStuck() public {
        uint256 id = dao.create{value: 1 ether}(orders, _exitBelowParams(ethKey));
        uint256 t1Before = _bal(currency1, address(dao));
        dao.cancel(orders, id);
        assertGt(_bal(currency1, address(dao)), t1Before, "token1 delivered directly");
        assertGt(orders.owed(address(dao), ETH), 0, "ETH held for withdrawal");
    }

    /// An owner later blacklisted by a token: the payout in that token is held, the rest still goes out.
    function test_blacklistedOwner_tokenHeld_withdrawElsewhere() public {
        vm.prank(alice);
        uint256 id = orders.createOrder(_exitBelowParams(poolKey));
        address token1 = Currency.unwrap(currency1);
        vm.mockCallRevert(token1, abi.encodeWithSelector(bytes4(0xa9059cbb), alice), "blacklisted");

        uint256 a0 = _bal(currency0, alice);
        vm.prank(alice);
        orders.cancel(id);
        assertGt(_bal(currency0, alice), a0, "token0 still delivered");
        uint256 held = orders.owed(alice, currency1);
        assertGt(held, 0, "token1 held");

        uint256 b1 = _bal(currency1, bob);
        vm.prank(alice);
        orders.withdraw(currency1, bob);
        assertEq(_bal(currency1, bob) - b1, held);
        vm.clearMockedCalls();
    }

    /// fillBucket in a native-ETH pool pays the caller its gas, from the bucket's proceeds, at most 1% of them.
    /// forge-config: default.isolate = false
    function test_fillRewardPaidFromProceeds() public {
        // a sell-ETH bucket too small for swaps (below 0.01% of the pool's liquidity)
        vm.prank(alice);
        uint256 small = hook.placeLimit{value: 1e13}(ethKey, 60, true, 1e13);
        _swapEth(false, 5e18);
        assertGe(_ethTick(), 120);
        assertFalse(hook.isFilled(small));

        uint256 before = _bal(currency1, keeper);
        vm.prank(keeper);
        uint256 reward = hook.fillBucket(ethKey, 60, true);
        assertGt(reward, 0);
        assertEq(_bal(currency1, keeper) - before, reward);

        // reward <= 1% of what the bucket produced; alice gets the rest
        vm.prank(alice);
        (, uint256 got1) = hook.claimLimit(small, alice);
        assertLe(reward * 100, got1 + reward + 1);
        console.log("fill reward (token1):", reward);
        console.log("alice receives (token1):", got1);
    }

    /// forge-config: default.isolate = false
    function test_fillRewardInEth_forBuyBucket() public {
        vm.prank(alice);
        uint256 small = hook.placeLimit(ethKey, -120, false, 1e13); // sell token1 for ETH
        _swapEth(true, 5e18);
        assertLt(_ethTick(), -120);
        assertFalse(hook.isFilled(small));

        uint256 before = keeper.balance;
        vm.prank(keeper);
        uint256 reward = hook.fillBucket(ethKey, -120, false);
        assertGt(reward, 0);
        assertEq(keeper.balance - before, reward);

        vm.prank(alice);
        (uint256 got0,) = hook.claimLimit(small, alice);
        assertLe(reward * 100, got0 + reward + 1, "reward at most 1% of the proceeds");
    }
}

/// @dev Flash-loan style attacker: push the price and call execute in one transaction.
contract PushAndExecute {
    function attack(IUniswapV4Router04 router, PoolKey calldata key, ConditionalOrders orders, uint256 id) external {
        MockERC20(Currency.unwrap(key.currency0)).approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens({
            amountIn: 30e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        orders.execute(id, false);
    }
}

/// @notice Fix 1: no execute after a swap in the same transaction (runs in isolate mode: one call = one transaction).
contract SameTxGuardTest is RuleSetup {
    function _stopLossOrder() internal returns (uint256 id) {
        OrderState.Side memory low;
        low.checker = OrderState.CHECK_EDGE;
        low.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE | OrderState.ACT_SWAP;
        low.removeBps = 10_000;
        low.swapToToken1 = true;
        OrderState.Side memory off;
        vm.prank(bob);
        id = orders.createOrder(
            ConditionalOrders.CreateParams({
                key: poolKey,
                tickLower: -600,
                tickUpper: 600,
                liquidity: 10e18,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                swapPoolIndex: 0,
                expiry: uint32(block.timestamp + 1 days),
                maxKeeperFeeBps: 10,
                maxSlippage: 10,
                lower: low,
                upper: off
            })
        );
    }

    function test_pushThenExecuteInOneTransactionReverts() public {
        uint256 id = _stopLossOrder();
        PushAndExecute attacker = new PushAndExecute();
        MockERC20(Currency.unwrap(currency0)).transfer(address(attacker), 30e18);

        vm.expectRevert(); // SwappedThisTx, wrapped by the PoolManager's unlock
        attacker.attack(swapRouter, poolKey, orders, id);
        assertGt(orders.orderLiquidity(id), 0, "order untouched");
    }

    function test_executeInALaterTransactionWorks() public {
        uint256 id = _stopLossOrder();
        _swap(true, 30e18); // transaction 1: the price really falls
        assertLt(_tick(), -600);
        assertFalse(hook.swappedThisTx(poolId), "flag cleared at the end of the transaction");
        vm.prank(keeper);
        orders.execute(id, false); // transaction 2
        assertEq(orders.orderLiquidity(id), 0);
    }
}
