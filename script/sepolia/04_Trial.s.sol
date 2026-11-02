// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {RuleHook} from "../../src/RuleHook.sol";
import {ConditionalOrders} from "../../src/ConditionalOrders.sol";
import {OrderState} from "../../src/libraries/OrderState.sol";

/// @notice Try conditional and limit orders on Sepolia, in phases (each phase is its own run, so swaps and
/// executions land in separate transactions):
///   PHASE=orders  create one order of each kind + two limit orders, remember the starting ticks
///   PHASE=up      push prices ~6% up in the test pools
///   PHASE=down    push prices ~6% below the starting price
///   PHASE=keep    act as a keeper: execute every order whose condition is met, claim filled limit orders
///   PHASE=keep forge script script/sepolia/04_Trial.s.sol --rpc-url sepolia --broadcast --isolate
contract Trial is Script {
    using PoolIdLibrary for PoolKey;

    string constant TRIAL = "./deployments/sepolia-trial.json";

    ConditionalOrders orders;
    RuleHook hook;
    IUniswapV4Router04 router;
    IPoolManager poolManager;
    string pools;
    address me;
    address usdc;

    function run() external {
        string memory core = vm.readFile("./deployments/sepolia-core.json");
        pools = vm.readFile("./deployments/sepolia-pools.json");
        orders = ConditionalOrders(payable(vm.parseJsonAddress(core, ".conditionalOrders")));
        hook = RuleHook(vm.parseJsonAddress(core, ".ruleHook"));
        router = IUniswapV4Router04(payable(vm.parseJsonAddress(core, ".swapRouter")));
        poolManager = IPoolManager(vm.parseJsonAddress(core, ".poolManager"));
        usdc = vm.parseJsonAddress(vm.readFile("./deployments/sepolia-tokens.json"), ".USDC");

        string memory phase = vm.envString("PHASE");
        vm.startBroadcast();
        me = msg.sender;
        if (_eq(phase, "orders")) _orders();
        else if (_eq(phase, "up")) _move(true);
        else if (_eq(phase, "down")) _move(false);
        else if (_eq(phase, "keep")) _keep();
        else revert("PHASE must be orders, up, down or keep");
        vm.stopBroadcast();
    }

    // ---------------------------------------------------------------- phases

    function _orders() internal {
        _approveAll();
        PoolKey memory weth = _key("WETH_USDC_3000");
        PoolKey memory wbtc = _key("WBTC_USDC_3000");
        PoolKey memory eth = _key("ETH_USDC_3000");
        int24 tW = _tick(weth);
        int24 tB = _tick(wbtc);
        int24 tE = _tick(eth);
        OrderState.Side memory off;

        // A. take profit: exit when the price leaves the range upward
        uint256 a = _create(weth, tW - 180, tW + 180, 20_000, off, _exit(false));
        // B. stop loss: exit below the range and sell everything into token1, at most 1% past the trigger
        uint256 b = _create(weth, tW - 180, tW + 180, 20_000, _exit(true), off);
        // C. follow the price up: when it leaves the range, move it just below the new price, again and again
        OrderState.Side memory follow = _exit(false);
        follow.value = 60; // one tick spacing past the edge
        follow.actions |= OrderState.ACT_ADD;
        follow.addMode = OrderState.ADD_ONE_SIDED;
        follow.shape = 4; // 4 spacings wide
        follow.repeat = true;
        uint256 c = _create(weth, tW - 120, tW + 120, 20_000, off, follow);
        // D. compound fees back into the position every minute
        OrderState.Side memory compound;
        compound.checker = OrderState.CHECK_TIME;
        compound.value = 1;
        compound.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_ADD;
        compound.repeat = true;
        uint256 d = _create(weth, tW - 600, tW + 600, 20_000, off, compound);
        // E. exit the WBTC position when the price in another pool (hookless WETH/USDC) falls 3%
        OrderState.Side memory cross = _exit(false);
        cross.checker = OrderState.CHECK_TICK;
        uint24 noHook = _index("WETH_USDC_500_NOHOOK");
        cross.checkPool = noHook;
        cross.value = _tick(_key("WETH_USDC_500_NOHOOK")) - 300;
        uint256 e = _create(wbtc, tB - 600, tB + 600, 20_000, cross, off);
        // F. native ETH pool: take profit, keeper paid exact gas
        uint256 f = _create(eth, tE - 120, tE + 120, 4, off, _exit(false));

        // limit orders in WETH-USDC-0.3: one above the price (sells token0), one below (sells token1)
        int24 above = _floor(tW, 60) + 180;
        int24 below = _floor(tW, 60) - 240;
        uint256 l1 = hook.placeLimit(weth, above, true, _usdAmount(weth, true, 2_000));
        uint256 l2 = hook.placeLimit(weth, below, false, _usdAmount(weth, false, 2_000));

        string memory j = vm.serializeUint("trial", "A_takeProfit", a);
        j = vm.serializeUint("trial", "B_stopLossSwap", b);
        j = vm.serializeUint("trial", "C_followUp", c);
        j = vm.serializeUint("trial", "D_compound", d);
        j = vm.serializeUint("trial", "E_crossPoolStop", e);
        j = vm.serializeUint("trial", "F_nativeTakeProfit", f);
        j = vm.serializeUint("trial", "limitSell", l1);
        j = vm.serializeUint("trial", "limitBuy", l2);
        j = vm.serializeInt("trial", "startTickWeth", tW);
        j = vm.serializeInt("trial", "startTickWbtc", tB);
        j = vm.serializeInt("trial", "startTickEth", tE);
        j = vm.serializeInt("trial", "startTickNoHook", _tick(_key("WETH_USDC_500_NOHOOK")));
        vm.writeJson(j, TRIAL);
        console.log("orders A-F:", a, f);
        console.log("limit sell / buy epochs:", l1, l2);
    }

    /// Push each test pool to its start tick +-600 (~6%) with repeated swaps.
    function _move(bool up) internal {
        string memory t = vm.readFile(TRIAL);
        _push(_key("WETH_USDC_3000"), vm.parseJsonInt(t, ".startTickWeth"), up);
        _push(_key("WBTC_USDC_3000"), vm.parseJsonInt(t, ".startTickWbtc"), up);
        _push(_key("WETH_USDC_500_NOHOOK"), vm.parseJsonInt(t, ".startTickNoHook"), up);
        _push(_key("ETH_USDC_3000"), vm.parseJsonInt(t, ".startTickEth"), up);
    }

    function _keep() internal {
        uint256[] memory ids = orders.ordersOf(me);
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 s; s < 2; ++s) {
                bool upper = s == 1;
                if (orders.canExecute(ids[i], upper)) {
                    orders.execute(ids[i], upper);
                    console.log("executed order", ids[i], upper ? "upper" : "lower");
                }
            }
        }
        string memory t = vm.readFile(TRIAL);
        uint256[2] memory epochs = [vm.parseJsonUint(t, ".limitSell"), vm.parseJsonUint(t, ".limitBuy")];
        for (uint256 i; i < 2; ++i) {
            (uint128 liq,,) = hook.shares(epochs[i], me);
            if (hook.isFilled(epochs[i]) && liq > 0) {
                (uint256 a0, uint256 a1) = hook.claimLimit(epochs[i], me);
                console.log("claimed limit order", epochs[i], a0, a1);
            }
        }
    }

    // ---------------------------------------------------------------- helpers

    function _exit(bool lower) internal pure returns (OrderState.Side memory d) {
        d.checker = OrderState.CHECK_EDGE;
        d.actions = OrderState.ACT_KEEP_FEES | OrderState.ACT_REMOVE;
        d.removeBps = 10_000;
        if (lower) {
            d.actions |= OrderState.ACT_SWAP;
            d.swapToToken1 = true;
        }
    }

    function _create(
        PoolKey memory key,
        int24 lo,
        int24 hi,
        uint256 usdPerSide,
        OrderState.Side memory lower,
        OrderState.Side memory upper
    ) internal returns (uint256 id) {
        ConditionalOrders.CreateParams memory p;
        p.key = key;
        p.tickLower = _floor(lo, key.tickSpacing);
        p.tickUpper = _floor(hi, key.tickSpacing);
        _fillAmounts(p, usdPerSide);
        p.expiry = uint32(block.timestamp + 30 days);
        p.maxKeeperFeeBps = 10;
        p.maxSlippage = 10; // 100 ticks, ~1%
        p.lower = lower;
        p.upper = upper;
        uint256 value = key.currency0.isAddressZero() ? p.amount0Max : 0;
        id = orders.createOrder{value: value}(p);
    }

    function _fillAmounts(ConditionalOrders.CreateParams memory p, uint256 usdPerSide) internal view {
        (uint160 sqrtP,,) = orders.poolState(hook.poolIndexOf(p.key.toId()));
        uint256 a0 = _usdAmount(p.key, true, usdPerSide);
        uint256 a1 = _usdAmount(p.key, false, usdPerSide);
        p.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(p.tickLower), TickMath.getSqrtPriceAtTick(p.tickUpper), a0, a1
        );
        p.amount0Max = uint128(a0 + a0 / 50 + 1);
        p.amount1Max = uint128(a1 + a1 / 50 + 1);
    }

    /// Token amount worth `usd` dollars. Every pool used here pairs with USDC (counted as $1); the other side is
    /// converted at the pool price.
    function _usdAmount(PoolKey memory key, bool token0, uint256 usd) internal view returns (uint256) {
        bool usdcIs0 = Currency.unwrap(key.currency0) == usdc;
        uint256 usdcAmount = usd * 1e6;
        if (token0 == usdcIs0) return usdcAmount;
        (uint160 sqrtP,,) = orders.poolState(hook.poolIndexOf(key.toId()));
        uint256 priceX96 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 96); // token1 per token0, x 2^96
        return token0 ? FullMath.mulDiv(usdcAmount, 1 << 96, priceX96) : FullMath.mulDiv(usdcAmount, priceX96, 1 << 96);
    }

    function _push(PoolKey memory key, int256 start, bool up) internal {
        int256 target = up ? start + 600 : start - 600;
        bool zeroForOne = !up;
        Currency payC = zeroForOne ? key.currency0 : key.currency1;
        for (uint256 i; i < 40; ++i) {
            int24 t = _tick(key);
            if (up ? t >= target : t <= target) break;
            uint256 chunk = _usdAmount(key, zeroForOne, key.currency0.isAddressZero() ? 2 : 100_000);
            router.swapExactTokensForTokens{value: payC.isAddressZero() ? chunk : 0}({
                amountIn: chunk,
                amountOutMin: 0,
                zeroForOne: zeroForOne,
                poolKey: key,
                hookData: "",
                receiver: me,
                deadline: block.timestamp + 3600
            });
        }
        console.log("pool tick now", int256(_tick(key)));
    }

    function _approveAll() internal {
        string memory toks = vm.readFile("./deployments/sepolia-tokens.json");
        string[6] memory syms = ["WETH", "WBTC", "USDC", "USDT", "DAI", "LINK"];
        for (uint256 i; i < syms.length; ++i) {
            IERC20 t = IERC20(vm.parseJsonAddress(toks, string.concat(".", syms[i])));
            t.approve(address(orders), type(uint256).max);
            t.approve(address(hook), type(uint256).max);
            t.approve(address(router), type(uint256).max);
        }
    }

    function _key(string memory name) internal view returns (PoolKey memory) {
        string memory p = string.concat(".", name);
        return PoolKey(
            Currency.wrap(vm.parseJsonAddress(pools, string.concat(p, ".currency0"))),
            Currency.wrap(vm.parseJsonAddress(pools, string.concat(p, ".currency1"))),
            uint24(vm.parseJsonUint(pools, string.concat(p, ".fee"))),
            int24(vm.parseJsonInt(pools, string.concat(p, ".tickSpacing"))),
            IHooks(vm.parseJsonAddress(pools, string.concat(p, ".hooks")))
        );
    }

    function _index(string memory name) internal view returns (uint24) {
        return uint24(vm.parseJsonUint(pools, string.concat(".", name, ".poolIndex")));
    }

    function _tick(PoolKey memory key) internal view returns (int24 t) {
        (, t,) = orders.poolState(hook.poolIndexOf(key.toId()));
    }

    function _floor(int24 t, int24 s) internal pure returns (int24) {
        int24 c = t / s;
        if (t < 0 && t % s != 0) c--;
        return c * s;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
