// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {OrderState} from "./libraries/OrderState.sol";
import {RuleHook} from "./RuleHook.sol";

/// @title ConditionalOrders: LP positions with a rule, run by keepers
/// @notice An LP adds liquidity through this contract together with a rule. This contract owns the position in the
/// PoolManager (owner = this contract, salt = orderId). Positions live in pools that use RuleHook. Anyone may call `execute`; the contract re-checks the rule's
/// condition on-chain, runs the actions (remove, swap, add), pays the caller a capped fee out of the removed tokens
/// and sends everything else to the owner. The owner can cancel at any time.
///
/// Payouts never block an order: if sending to the owner fails (a contract that cannot take ETH, a blacklisted
/// address), the amount is kept here as `owed` and the owner withdraws it later to any address.
contract ConditionalOrders is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using OrderState for OrderState.Side;

    error NotPoolManager();
    error PoolNotAllowed();
    error UnknownPool();
    error CurrencyMismatch();
    error InvalidOrder();
    error InvalidSide();
    error NotOwner();
    error UnknownOrder();
    error Expired();
    error SideOff();
    error ConditionNotMet();
    error WouldRefire();
    error SwappedThisTx();
    error TooMuchIn();
    error BadMsgValue();
    error RefundFailed();
    error NothingOwed();

    uint256 internal constant BPS = 10_000;
    uint8 public constant MAX_KEEPER_FEE_BPS = 100;

    /// @dev Keeper pay = measured gas x gas price x 110%, taken from the order's removed tokens and never more than
    /// maxKeeperFeeBps of them. Gas the measurement cannot see (the 21k base cost, calldata, the final token
    /// transfers) is covered by a fixed allowance. The gas price counted is capped so a keeper cannot inflate it.
    uint256 public constant KEEPER_GAS_OVERHEAD = 60_000;
    uint256 public constant KEEPER_PREMIUM_BPS = 11_000;
    uint256 public constant MAX_PRIORITY_FEE_WEI = 0.01 gwei;
    /// @dev Gas given to the owner's address when sending it ETH, so a receiving contract cannot use up the keeper's gas.
    uint256 public constant PAYOUT_GAS = 100_000;

    /// @dev Two storage slots per order.
    struct Order {
        // slot 0, written once (160 + 24 + 24 + 32 + 8 + 8 = 256 bits)
        address owner;
        uint24 poolIndex; // pool that holds the position
        uint24 swapPoolIndex; // pool used for instant swaps (same pair)
        uint32 expiry;
        uint8 maxKeeperFeeBps; // ceiling on the keeper's pay per run, in bps of the removed tokens
        uint8 maxSlippage; // instant swaps stop this far past the trigger price, in steps of 10 ticks (~0.1%)
        // slot 1, rewritten on every run
        uint256 state; // OrderState word
    }

    struct CreateParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        uint24 swapPoolIndex; // 0 = swap in the order's own pool
        uint32 expiry;
        uint8 maxKeeperFeeBps;
        uint8 maxSlippage; // steps of 10 ticks
        OrderState.Side lower;
        OrderState.Side upper;
    }

    /// @dev New rule for an existing order. The position's range stays as it is.
    struct UpdateParams {
        uint24 swapPoolIndex; // 0 = the order's own pool
        uint32 expiry;
        uint8 maxKeeperFeeBps;
        uint8 maxSlippage;
        OrderState.Side lower;
        OrderState.Side upper;
    }

    enum Op {
        Create,
        Execute,
        Cancel
    }

    /// @dev Working data for one execution, kept in memory to avoid stack limits.
    struct Run {
        uint256 orderId;
        bool upper;
        address keeper;
        uint256 gasStart;
        Order order;
        OrderState.State st;
        PoolKey key;
        bytes32 salt;
        uint256 w0; // tokens the actions may use
        uint256 w1;
        uint256 reserve0; // set aside for the keeper (the fee ceiling); the unused part goes to the owner
        uint256 reserve1;
    }

    IPoolManager public immutable poolManager;
    RuleHook public immutable hook; // holds the pool table

    uint256 public nextOrderId = 1;
    mapping(uint256 orderId => Order) internal _orders;
    /// @dev Every order id an address created (closed ones included; their owner reads as zero).
    mapping(address owner => uint256[] orderIds) internal _ordersOf;
    /// @notice Payouts that could not be sent, waiting for the owner to withdraw them.
    mapping(address owner => mapping(Currency currency => uint256 amount)) public owed;

    event OrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        uint24 indexed poolIndex,
        uint24 swapPoolIndex,
        uint32 expiry,
        uint8 maxKeeperFeeBps,
        uint8 maxSlippage,
        uint256 state
    );
    event OrderExecuted(uint256 indexed orderId, bool upper, address indexed keeper, uint256 state);
    event OrderClosed(uint256 indexed orderId);
    event OrderUpdated(uint256 indexed orderId, uint256 state);
    event PayoutHeld(address indexed owner, Currency indexed currency, uint256 amount);
    event Withdrawn(address indexed owner, Currency indexed currency, address to, uint256 amount);

    constructor(IPoolManager _poolManager, RuleHook _hook) {
        poolManager = _poolManager;
        hook = _hook;
    }

    /// @dev Native ETH arrives here from the PoolManager when a payout is taken to this contract.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ---------------------------------------------------------------
    // User entry points
    // ---------------------------------------------------------------

    /// @notice Add liquidity with a rule attached. Approve this contract for both tokens first (for native ETH as
    /// currency0, send it as msg.value; anything not used is refunded).
    function createOrder(CreateParams calldata p) external payable returns (uint256 orderId) {
        if (address(p.key.hooks) != address(hook)) revert PoolNotAllowed();
        uint24 poolIndex = hook.poolIndexOf(p.key.toId());
        if (poolIndex == 0) revert UnknownPool();
        uint24 swapIndex = p.swapPoolIndex == 0 ? poolIndex : p.swapPoolIndex;
        if (!_samePair(p.key, swapIndex)) revert CurrencyMismatch();

        if (
            p.liquidity == 0 || p.tickLower >= p.tickUpper || p.expiry <= block.timestamp
                || p.maxKeeperFeeBps > MAX_KEEPER_FEE_BPS
        ) revert InvalidOrder();
        if (p.lower.checker == OrderState.CHECK_OFF && p.upper.checker == OrderState.CHECK_OFF) revert InvalidOrder();
        _validateSide(p.lower, p.key.tickSpacing);
        _validateSide(p.upper, p.key.tickSpacing);
        if (!p.key.currency0.isAddressZero() && msg.value != 0) revert BadMsgValue();

        OrderState.State memory st;
        st.lower = p.lower;
        st.upper = p.upper;
        st.lower.edge = p.tickLower;
        st.upper.edge = p.tickUpper;
        st.lower.lastRun = uint32(block.timestamp);
        st.upper.lastRun = uint32(block.timestamp);
        uint256 word = OrderState.encode(st);

        orderId = nextOrderId++;
        _ordersOf[msg.sender].push(orderId);
        _orders[orderId] = Order({
            owner: msg.sender,
            poolIndex: poolIndex,
            swapPoolIndex: swapIndex,
            expiry: p.expiry,
            maxKeeperFeeBps: p.maxKeeperFeeBps,
            maxSlippage: p.maxSlippage,
            state: word
        });

        bytes memory res = poolManager.unlock(
            abi.encode(Op.Create, orderId, abi.encode(p.liquidity, p.amount0Max, p.amount1Max, msg.sender))
        );
        uint256 paid0 = abi.decode(res, (uint256));

        if (p.key.currency0.isAddressZero() && msg.value > paid0) {
            (bool ok,) = msg.sender.call{value: msg.value - paid0}("");
            if (!ok) revert RefundFailed();
        }

        emit OrderCreated(
            orderId, msg.sender, poolIndex, swapIndex, p.expiry, p.maxKeeperFeeBps, p.maxSlippage, word
        );
    }

    /// @notice Change the rule of an open order (owner only). The liquidity and its range stay as they are.
    /// Timers restart now. To stop the order completely, use `cancel`.
    function updateOrder(uint256 orderId, UpdateParams calldata p) external {
        Order storage o = _orders[orderId];
        if (o.owner == address(0)) revert UnknownOrder();
        if (msg.sender != o.owner) revert NotOwner();
        PoolKey memory key = _key(o.poolIndex);
        uint24 swapIndex = p.swapPoolIndex == 0 ? o.poolIndex : p.swapPoolIndex;
        if (!_samePair(key, swapIndex)) revert CurrencyMismatch();
        if (p.expiry <= block.timestamp || p.maxKeeperFeeBps > MAX_KEEPER_FEE_BPS) revert InvalidOrder();
        if (p.lower.checker == OrderState.CHECK_OFF && p.upper.checker == OrderState.CHECK_OFF) revert InvalidOrder();
        _validateSide(p.lower, key.tickSpacing);
        _validateSide(p.upper, key.tickSpacing);

        OrderState.State memory current = OrderState.decode(o.state);
        OrderState.State memory st;
        st.lower = p.lower;
        st.upper = p.upper;
        st.lower.edge = current.lower.edge;
        st.upper.edge = current.upper.edge;
        st.lower.lastRun = uint32(block.timestamp);
        st.upper.lastRun = uint32(block.timestamp);
        uint256 word = OrderState.encode(st);

        o.swapPoolIndex = swapIndex;
        o.expiry = p.expiry;
        o.maxKeeperFeeBps = p.maxKeeperFeeBps;
        o.maxSlippage = p.maxSlippage;
        o.state = word;
        emit OrderUpdated(orderId, word);
    }

    /// @notice Run one side of an order. Anyone can call; the condition is checked here.
    function execute(uint256 orderId, bool upper) external {
        Order storage o = _orders[orderId];
        if (o.owner == address(0)) revert UnknownOrder();
        if (block.timestamp > o.expiry) revert Expired();
        poolManager.unlock(abi.encode(Op.Execute, orderId, abi.encode(upper, msg.sender)));
    }

    /// @notice Close the order and send all tokens to the owner. The owner can do this at any time,
    /// anyone else only after expiry.
    function cancel(uint256 orderId) external {
        Order storage o = _orders[orderId];
        if (o.owner == address(0)) revert UnknownOrder();
        if (msg.sender != o.owner && block.timestamp <= o.expiry) revert NotOwner();
        poolManager.unlock(abi.encode(Op.Cancel, orderId, bytes("")));
    }

    /// @notice Send payouts that could not be delivered earlier to any address.
    function withdraw(Currency currency, address to) external returns (uint256 amount) {
        amount = owed[msg.sender][currency];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender][currency] = 0;
        currency.transfer(to, amount);
        emit Withdrawn(msg.sender, currency, to, amount);
    }

    function getOrder(uint256 orderId) external view returns (Order memory order, OrderState.State memory state) {
        order = _orders[orderId];
        state = OrderState.decode(order.state);
    }

    /// @notice Every order id `owner` created. Closed orders are included; `getOrder` returns a zero owner for them.
    function ordersOf(address owner) external view returns (uint256[] memory) {
        return _ordersOf[owner];
    }

    /// @notice Token amounts the order's position holds at the current price (fees not included).
    function orderAmounts(uint256 orderId) external view returns (uint256 amount0, uint256 amount1) {
        Order storage o = _orders[orderId];
        if (o.owner == address(0)) return (0, 0);
        OrderState.State memory st = OrderState.decode(o.state);
        PoolKey memory key = _key(o.poolIndex);
        uint128 liq = _positionLiquidity(key, st.lower.edge, st.upper.edge, bytes32(orderId));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint160 a = TickMath.getSqrtPriceAtTick(st.lower.edge);
        uint160 b = TickMath.getSqrtPriceAtTick(st.upper.edge);
        if (sqrtPriceX96 <= a) {
            amount0 = SqrtPriceMath.getAmount0Delta(a, b, liq, false);
        } else if (sqrtPriceX96 >= b) {
            amount1 = SqrtPriceMath.getAmount1Delta(a, b, liq, false);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, b, liq, false);
            amount1 = SqrtPriceMath.getAmount1Delta(a, sqrtPriceX96, liq, false);
        }
    }

    /// @notice Current price and active liquidity of a pool in the table.
    function poolState(uint24 poolIndex) external view returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity) {
        PoolId id = _key(poolIndex).toId();
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(id);
        liquidity = poolManager.getLiquidity(id);
    }

    /// @notice Liquidity this contract holds for the order right now.
    function orderLiquidity(uint256 orderId) external view returns (uint128) {
        Order storage o = _orders[orderId];
        OrderState.State memory st = OrderState.decode(o.state);
        return _positionLiquidity(_key(o.poolIndex), st.lower.edge, st.upper.edge, bytes32(orderId));
    }

    /// @notice Whether `execute(orderId, upper)` would pass its condition check now (for keepers).
    function canExecute(uint256 orderId, bool upper) external view returns (bool) {
        Order storage o = _orders[orderId];
        if (o.owner == address(0) || block.timestamp > o.expiry) return false;
        OrderState.State memory st = OrderState.decode(o.state);
        OrderState.Side memory sd = upper ? st.upper : st.lower;
        if (sd.checker == OrderState.CHECK_OFF) return false;
        return _conditionMet(_key(o.poolIndex), st, sd, upper);
    }

    // ---------------------------------------------------------------
    // Unlock callback
    // ---------------------------------------------------------------

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        // Gas is measured inside this one call frame. Measuring across the call into the PoolManager would count
        // the 1/64 of gas the EVM holds back, which grows with the gas limit the keeper picks.
        uint256 gasStart = gasleft();
        (Op op, uint256 orderId, bytes memory args) = abi.decode(data, (Op, uint256, bytes));
        if (op == Op.Create) return _create(orderId, args);
        if (op == Op.Execute) {
            (bool upper, address keeper) = abi.decode(args, (bool, address));
            _execute(orderId, upper, keeper, gasStart);
        } else {
            _cancel(orderId);
        }
        return "";
    }

    function _create(uint256 orderId, bytes memory args) internal returns (bytes memory) {
        (uint128 liquidity, uint128 max0, uint128 max1, address payer) =
            abi.decode(args, (uint128, uint128, uint128, address));
        Order storage o = _orders[orderId];
        OrderState.State memory st = OrderState.decode(o.state);
        PoolKey memory key = _key(o.poolIndex);

        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: st.lower.edge,
                tickUpper: st.upper.edge,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(orderId)
            }),
            ""
        );
        uint256 pay0 = _neg(d.amount0());
        uint256 pay1 = _neg(d.amount1());
        if (pay0 > max0 || pay1 > max1) revert TooMuchIn();

        key.currency0.settle(poolManager, key.currency0.isAddressZero() ? address(this) : payer, pay0, false);
        key.currency1.settle(poolManager, payer, pay1, false);
        return abi.encode(pay0);
    }

    function _cancel(uint256 orderId) internal {
        Order memory o = _orders[orderId];
        OrderState.State memory st = OrderState.decode(o.state);
        PoolKey memory key = _key(o.poolIndex);
        _close(key, st, orderId, o.owner);
    }

    // ---------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------

    function _execute(uint256 orderId, bool upper, address keeper, uint256 gasStart) internal {
        Run memory r;
        r.orderId = orderId;
        r.upper = upper;
        r.keeper = keeper;
        r.gasStart = gasStart;
        r.order = _orders[orderId];
        r.st = OrderState.decode(r.order.state);
        r.key = _key(r.order.poolIndex);
        r.salt = bytes32(orderId);

        OrderState.Side memory sd = upper ? r.st.upper : r.st.lower;
        if (sd.checker == OrderState.CHECK_OFF) revert SideOff();
        // No execution right after a swap in the same transaction: a flash-loaned price push followed by execute
        // (then a swap back) is the cheap way to force a trigger. Covers the order's pool and, for TICK, the
        // checked pool when it uses this hook (hookless pools are never flagged).
        if (hook.swappedThisTx(r.key.toId())) revert SwappedThisTx();
        if (sd.checker == OrderState.CHECK_TICK && sd.checkPool != 0 && hook.swappedThisTx(_key(sd.checkPool).toId())) {
            revert SwappedThisTx();
        }
        if (!_conditionMet(r.key, r.st, sd, upper)) revert ConditionNotMet();
        int24 refTick = _refTick(r, sd); // read before the range can change

        _removeAndReserve(r, sd);
        if (sd.actions & OrderState.ACT_SWAP != 0) _instantSwap(r, sd, refTick);
        if (sd.actions & OrderState.ACT_ADD != 0) _add(r, sd);

        // Update the side that ran.
        sd.lastRun = uint32(block.timestamp);
        if (sd.repeat) {
            if (sd.checker == OrderState.CHECK_TICK && sd.actions & OrderState.ACT_ADD == 0) {
                int256 v = int256(sd.value) + (upper ? int256(uint256(sd.shape)) : -int256(uint256(sd.shape)));
                sd.value = int24(_clampTick(v));
            }
        } else if (upper) {
            r.st.upper.clear();
        } else {
            r.st.lower.clear();
        }

        _payKeeper(r);

        uint128 left = _positionLiquidity(r.key, r.st.lower.edge, r.st.upper.edge, r.salt);
        bool bothOff = r.st.lower.checker == OrderState.CHECK_OFF && r.st.upper.checker == OrderState.CHECK_OFF;
        if (left == 0 || bothOff) {
            _close(r.key, r.st, orderId, r.order.owner);
            return;
        }

        // A run must change something, otherwise a keeper could call it again in a loop and drain fees.
        OrderState.Side memory again = upper ? r.st.upper : r.st.lower;
        if (again.checker != OrderState.CHECK_OFF && _conditionMet(r.key, r.st, again, upper)) revert WouldRefire();

        _payOut(r.key, r.order.owner);
        uint256 word = OrderState.encode(r.st);
        _orders[orderId].state = word;
        emit OrderExecuted(orderId, upper, keeper, word);
    }

    /// @dev Remove (or just collect), set the keeper's ceiling aside, and set aside the fees the owner does not want
    /// reinvested. Everything set aside stays as a credit in this unlock and is paid out at the end.
    function _removeAndReserve(Run memory r, OrderState.Side memory sd) internal {
        uint128 liq = _positionLiquidity(r.key, r.st.lower.edge, r.st.upper.edge, r.salt);
        uint128 removeLiq =
            sd.actions & OrderState.ACT_REMOVE != 0 ? uint128((uint256(liq) * sd.removeBps) / BPS) : 0;

        (BalanceDelta out, BalanceDelta fees) = poolManager.modifyLiquidity(
            r.key,
            ModifyLiquidityParams({
                tickLower: r.st.lower.edge,
                tickUpper: r.st.upper.edge,
                liquidityDelta: -int256(uint256(removeLiq)),
                salt: r.salt
            }),
            ""
        );

        uint256 out0 = _pos(out.amount0());
        uint256 out1 = _pos(out.amount1());
        r.reserve0 = (out0 * r.order.maxKeeperFeeBps) / BPS;
        r.reserve1 = (out1 * r.order.maxKeeperFeeBps) / BPS;
        uint256 w0 = out0 - r.reserve0;
        uint256 w1 = out1 - r.reserve1;

        if (sd.actions & OrderState.ACT_KEEP_FEES == 0) {
            uint256 f0 = _pos(fees.amount0());
            uint256 f1 = _pos(fees.amount1());
            w0 -= f0 > w0 ? w0 : f0;
            w1 -= f1 > w1 ? w1 : f1;
        }
        r.w0 = w0;
        r.w1 = w1;
    }

    /// @dev Pay the keeper out of the reserve. Native-ETH pools: gas used x capped gas price x 110%, paid in ETH first,
    /// the rest in token1 at the pool price. Other pools: the whole reserve (a flat fee at the ceiling), because
    /// gas cannot be priced in their tokens without an outside price.
    function _payKeeper(Run memory r) internal {
        uint256 pay0 = r.reserve0;
        uint256 pay1 = r.reserve1;
        if (r.key.currency0.isAddressZero()) {
            uint256 cost = keeperGasCost(r.gasStart - gasleft());
            pay0 = cost < r.reserve0 ? cost : r.reserve0;
            uint256 rest = cost - pay0;
            pay1 = 0;
            if (rest > 0 && r.reserve1 > 0) {
                (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(r.key.toId());
                uint256 inToken1 = FullMath.mulDiv(FullMath.mulDiv(rest, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
                pay1 = inToken1 < r.reserve1 ? inToken1 : r.reserve1;
            }
        }
        r.key.currency0.take(poolManager, r.keeper, pay0, false);
        r.key.currency1.take(poolManager, r.keeper, pay1, false);
    }

    /// @notice What a keeper is refunded, in wei, for `gasUsed` measured inside execute.
    function keeperGasCost(uint256 gasUsed) public view returns (uint256) {
        uint256 maxPrice = block.basefee + MAX_PRIORITY_FEE_WEI;
        uint256 price = tx.gasprice < maxPrice ? tx.gasprice : maxPrice;
        return ((gasUsed + KEEPER_GAS_OVERHEAD) * price * KEEPER_PREMIUM_BPS) / BPS;
    }

    /// @dev Swap everything of one token into the other, stopping at the slippage limit. If the price is already
    /// past the limit, the swap is skipped and the owner receives the token unswapped.
    function _instantSwap(Run memory r, OrderState.Side memory sd, int24 refTick) internal {
        bool zeroForOne = sd.swapToToken1;
        uint256 amountIn = zeroForOne ? r.w0 : r.w1;
        if (amountIn == 0) return;

        PoolKey memory sk = r.order.swapPoolIndex == r.order.poolIndex ? r.key : _key(r.order.swapPoolIndex);
        int256 slip = int256(uint256(r.order.maxSlippage)) * 10;
        int24 limitTick = _clampTick(zeroForOne ? int256(refTick) - slip : int256(refTick) + slip);
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        (uint160 current,,,) = poolManager.getSlot0(sk.toId());
        if (zeroForOne ? limit >= current : limit <= current) return;

        poolManager.swap(
            sk, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), ""
        );
        if (zeroForOne) r.w0 = 0;
        else r.w1 = 0;
    }

    /// @dev Add the working tokens back: same range, or one-sided next to the current price.
    function _add(Run memory r, OrderState.Side memory sd) internal {
        int256 lower = r.st.lower.edge;
        int256 upper = r.st.upper.edge;
        uint256 a0 = r.w0;
        uint256 a1 = r.w1;

        if (sd.addMode == OrderState.ADD_ONE_SIDED) {
            (, int24 tick,,) = poolManager.getSlot0(r.key.toId());
            int256 s = r.key.tickSpacing;
            int256 floorTick = _floor(tick, r.key.tickSpacing);
            if (r.upper) {
                // price rose out of the range: we hold token1, place it just below the price
                upper = floorTick;
                lower = floorTick - int256(uint256(sd.widthBelow())) * s;
                a0 = 0;
            } else {
                // price fell out of the range: we hold token0, place it just above the price
                lower = floorTick + s;
                upper = lower + int256(uint256(sd.widthAbove())) * s;
                a1 = 0;
            }
            if (
                lower < TickMath.minUsableTick(r.key.tickSpacing) || upper > TickMath.maxUsableTick(r.key.tickSpacing)
            ) return; // no room: tokens go to the owner and the order closes
        }

        uint128 liq = _liquidityFor(r.key, int24(lower), int24(upper), a0, a1);
        if (liq == 0) return;
        poolManager.modifyLiquidity(
            r.key,
            ModifyLiquidityParams({
                tickLower: int24(lower),
                tickUpper: int24(upper),
                liquidityDelta: int256(uint256(liq)),
                salt: r.salt
            }),
            ""
        );
        r.st.lower.edge = int24(lower);
        r.st.upper.edge = int24(upper);
    }

    function _close(PoolKey memory key, OrderState.State memory st, uint256 orderId, address owner) internal {
        uint128 liq = _positionLiquidity(key, st.lower.edge, st.upper.edge, bytes32(orderId));
        if (liq > 0) {
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: st.lower.edge,
                    tickUpper: st.upper.edge,
                    liquidityDelta: -int256(uint256(liq)),
                    salt: bytes32(orderId)
                }),
                ""
            );
        }
        _payOut(key, owner);
        delete _orders[orderId];
        emit OrderClosed(orderId);
    }

    /// @dev Send whatever this contract is owed in the current unlock to `to`.
    function _payOut(PoolKey memory key, address to) internal {
        int256 d0 = poolManager.currencyDelta(address(this), key.currency0);
        int256 d1 = poolManager.currencyDelta(address(this), key.currency1);
        if (d0 > 0) _send(key.currency0, to, uint256(d0));
        if (d1 > 0) _send(key.currency1, to, uint256(d1));
    }

    /// @dev Take the tokens here first, then try to send them. If that fails, keep them as `owed`.
    function _send(Currency currency, address to, uint256 amount) internal {
        currency.take(poolManager, address(this), amount, false);
        if (!_trySend(currency, to, amount)) {
            owed[to][currency] += amount;
            emit PayoutHeld(to, currency, amount);
        }
    }

    /// @dev A transfer that reports failure instead of reverting. ETH gets PAYOUT_GAS and no return data is copied.
    function _trySend(Currency currency, address to, uint256 amount) internal returns (bool ok) {
        if (currency.isAddressZero()) {
            uint256 g = PAYOUT_GAS;
            assembly ("memory-safe") {
                ok := call(g, to, amount, 0, 0, 0, 0)
            }
            return ok;
        }
        address token = Currency.unwrap(currency);
        bytes memory ret;
        (ok, ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount)); // transfer(address,uint256)
        // tokens that return nothing count as success; tokens that return false count as failure
        if (ok && ret.length > 0) ok = ret.length >= 32 && abi.decode(ret, (bool));
    }

    // ---------------------------------------------------------------
    // Conditions
    // ---------------------------------------------------------------

    function _conditionMet(PoolKey memory key, OrderState.State memory st, OrderState.Side memory sd, bool upper)
        internal
        view
        returns (bool)
    {
        if (sd.checker == OrderState.CHECK_TIME) {
            return block.timestamp >= uint256(sd.lastRun) + uint256(uint24(sd.value)) * 60;
        }
        if (sd.checker == OrderState.CHECK_EDGE) {
            int256 t = _tick(key);
            return upper ? t >= int256(st.upper.edge) + sd.value : t < int256(st.lower.edge) - sd.value;
        }
        if (sd.checker == OrderState.CHECK_TICK) {
            int256 t = _tick(sd.checkPool == 0 ? key : _key(sd.checkPool));
            return upper ? t >= sd.value : t < sd.value;
        }
        return false;
    }

    /// @dev Price the instant swap is protected against: the trigger level when it is a price of this pair,
    /// otherwise the pool's current price.
    function _refTick(Run memory r, OrderState.Side memory sd) internal view returns (int24) {
        if (sd.checker == OrderState.CHECK_EDGE) {
            return _clampTick(
                r.upper ? int256(r.st.upper.edge) + sd.value : int256(r.st.lower.edge) - sd.value
            );
        }
        if (sd.checker == OrderState.CHECK_TICK && (sd.checkPool == 0 || _samePair(r.key, sd.checkPool))) {
            return sd.value;
        }
        return _tick(r.key);
    }

    function _validateSide(OrderState.Side calldata d, int24 tickSpacing) internal view {
        if (d.checker == OrderState.CHECK_OFF) return;
        if (d.checker > OrderState.CHECK_TIME || d.shape > OrderState.MAX_SHAPE) revert InvalidSide();
        if (d.actions == 0 || d.actions > 15 || d.removeBps > BPS) revert InvalidSide();
        if (d.actions & (OrderState.ACT_REMOVE | OrderState.ACT_KEEP_FEES | OrderState.ACT_ADD) == 0) {
            revert InvalidSide();
        }
        bool add = d.actions & OrderState.ACT_ADD != 0;
        if (add && d.actions & OrderState.ACT_SWAP != 0) revert InvalidSide(); // swap-to-ratio is not in v1

        if (d.checker == OrderState.CHECK_TIME && d.value <= 0) revert InvalidSide();
        if (d.checker == OrderState.CHECK_EDGE && d.value < 0) revert InvalidSide();
        if (d.checker == OrderState.CHECK_TICK) {
            if (d.checkPool > hook.poolCount()) revert UnknownPool();
            if (d.repeat && !add && d.shape == 0) revert InvalidSide(); // repeating level needs a step
        }

        if (add) {
            if (d.addMode > OrderState.ADD_ONE_SIDED) revert InvalidSide();
            if (d.addMode == OrderState.ADD_ONE_SIDED) {
                // one-sided re-range only makes sense after leaving the range, with everything removed
                if (d.checker != OrderState.CHECK_EDGE) revert InvalidSide();
                if (d.actions & OrderState.ACT_REMOVE == 0 || d.removeBps != BPS) revert InvalidSide();
                uint24 wBelow = d.shape & OrderState.MAX_WIDTH;
                uint24 wAbove = (d.shape >> 11) & OrderState.MAX_WIDTH;
                if (wBelow == 0 && wAbove == 0) revert InvalidSide();
                // the new range sits next to the price, so the trigger needs at least one spacing of room
                if (d.repeat && d.value < tickSpacing) revert InvalidSide();
            } else if (d.repeat && d.checker == OrderState.CHECK_EDGE) {
                revert InvalidSide(); // same range again would fire again at once
            }
        } else if (d.repeat && d.checker == OrderState.CHECK_EDGE) {
            revert InvalidSide(); // the range does not move, so it would fire again at once
        }
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _positionLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        view
        returns (uint128)
    {
        bytes32 positionId = Position.calculatePositionKey(address(this), tickLower, tickUpper, salt);
        return poolManager.getPositionLiquidity(key.toId(), positionId);
    }

    function _liquidityFor(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 a0, uint256 a1)
        internal
        view
        returns (uint128)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        // keep 1 wei back: the PoolManager rounds the amounts it asks for up
        a0 = a0 > 0 ? a0 - 1 : 0;
        a1 = a1 > 0 ? a1 - 1 : 0;
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), a0, a1
        );
    }

    function _key(uint24 index) internal view returns (PoolKey memory) {
        return hook.poolKeyAt(index);
    }

    function _samePair(PoolKey memory key, uint24 index) internal view returns (bool) {
        if (index == 0 || index > hook.poolCount()) return false;
        PoolKey memory other = hook.poolKeyAt(index);
        return other.currency0 == key.currency0 && other.currency1 == key.currency1;
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(key.toId());
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int256) {
        int256 c = int256(tick) / spacing;
        if (tick < 0 && int256(tick) % spacing != 0) c--;
        return c * spacing;
    }

    function _clampTick(int256 t) internal pure returns (int24) {
        if (t <= TickMath.MIN_TICK) return TickMath.MIN_TICK + 1;
        if (t >= TickMath.MAX_TICK) return TickMath.MAX_TICK - 1;
        return int24(t);
    }

    function _pos(int128 x) internal pure returns (uint256) {
        return x > 0 ? uint256(uint128(x)) : 0;
    }

    function _neg(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : 0;
    }
}
