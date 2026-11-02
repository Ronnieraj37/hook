// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title RuleHook: pool table + limit orders filled inside the swap
/// @notice Limit orders at the same price share one position (a "bucket"): a range one tick spacing wide, holding one
/// token. When a swap moves the price fully across a bucket, `afterSwap` removes the whole bucket in one call and keeps
/// the proceeds as ERC-6909 claims inside the PoolManager. Each user then claims their share. Every bucket a swap
/// fully crosses is filled in that swap (like Uniswap crosses every initialized tick); the cost is per bucket, not
/// per user.
///
/// Anti-dust: a bucket is filled inside swaps only if it holds at least MIN_FILL_BPS (0.01%) of the pool's active
/// liquidity, and one swap fills at most MAX_FILLS_PER_SWAP buckets. Crossed buckets over that cap are kept in a
/// backlog that the next swaps finish first. Anyone can fill a crossed bucket with `fillBucket` (small ones, or ones
/// waiting in the backlog) and is paid its gas cost out of the bucket's proceeds (native-ETH pools; capped at 1%).
///
/// Fees: the shared position earns fees while the price trades inside the bucket. Fees collected when someone joins
/// or leaves belong to the holders at that moment, tracked with a fee-per-liquidity counter (like Uniswap's
/// feeGrowth), so a newcomer never gets fees earned before they joined. Fees collected at the fill belong to the
/// holders at the fill and are split by share.
contract RuleHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using TickBitmap for mapping(int16 => uint256);

    error PoolNotAllowed();
    error UnknownPool();
    error BadTick();
    error WrongSide();
    error ZeroLiquidity();
    error TooMuchIn();
    error BadMsgValue();
    error RefundFailed();
    error UnknownEpoch();
    error AlreadyFilled();
    error NotFilled();
    error NothingToClaim();
    error NotCrossed();

    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant BPS = 10_000;

    /// @notice A bucket is filled inside swaps only if its liquidity is at least this share of the pool's active
    /// liquidity (1 = 0.01%). Smaller buckets still work; they are filled with `fillBucket`.
    uint256 public constant MIN_FILL_BPS = 1;
    /// @notice Most buckets one swap fills (~69k gas each, so ~3.5M gas). The rest wait in the backlog.
    uint256 public constant MAX_FILLS_PER_SWAP = 50;

    /// @dev fillBucket reward = measured gas x capped gas price x 110% + overhead, at most 1% of the bucket's proceeds.
    uint256 public constant FILL_GAS_OVERHEAD = 50_000;
    uint256 public constant FILL_PREMIUM_BPS = 11_000;
    uint256 public constant MAX_PRIORITY_FEE_WEI = 0.01 gwei;
    uint256 public constant MAX_FILL_REWARD_BPS = 100;

    // ---------------------------------------------------------------- pool table (index 0 = none)
    // 24-bit index: room for 16.7M pools (550 tokens x 4 fee tiers is ~604k possible pairs/pools).
    uint24 public poolCount;
    mapping(uint24 index => PoolKey) internal _pools;
    mapping(PoolId poolId => uint24 index) public poolIndexOf;

    // ---------------------------------------------------------------- limit buckets
    /// @dev One epoch = one fill cycle of one bucket. Each fill amount shares a slot with a field that is already
    /// non-zero, so recording the fill rewrites existing slots (~2.9k gas) instead of filling an empty one (~20k).
    /// The fee counters (slots 2-3) are only written when someone joins or leaves, never by a swap.
    struct Epoch {
        // slot 0
        uint128 liquidityTotal; // shares outstanding; frozen once filled
        uint128 proceeds0; // token0 taken out at the fill (principal + fees since the last join/leave)
        // slot 1
        uint128 proceeds1;
        uint24 poolIndex;
        int24 tickLower; // range is [tickLower, tickLower + tickSpacing]
        bool sellToken0; // true: holds token0 above the price, fills when the price rises through it
        bool filled;
        bool inBitmap; // bucket is eligible for in-swap fills
        // slots 2-3: fees per unit of liquidity collected at joins and leaves, scaled by 2^128
        uint256 feePerLiq0;
        uint256 feePerLiq1;
    }

    /// @dev A user's part of an epoch. debt = fees per liquidity already accounted for when they joined.
    struct Share {
        uint128 liquidity;
        uint128 debt0;
        uint128 debt1;
    }

    uint256 public nextEpochId = 1;
    mapping(uint256 epochId => Epoch) public epochs;
    mapping(uint256 epochId => mapping(address owner => Share)) public shares;
    /// @notice The epoch currently collecting orders for a bucket (0 = none).
    mapping(PoolId poolId => mapping(int24 tickLower => mapping(bool sellToken0 => uint256 epochId))) public
        openEpoch;
    /// @dev One bitmap per pool and direction; a bit is set for each bucket eligible for in-swap fills.
    mapping(PoolId poolId => mapping(bool sellToken0 => mapping(int16 => uint256))) internal _bitmap;

    /// @dev Crossed buckets a swap could not fill because of the cap, per pool. Bucket tickLower ranges, low end
    /// exclusive, high end inclusive. up: sell-token0 buckets in (upLo, upHi]; down: sell-token1 buckets in
    /// (downLo, downHi]. A bucket in the range is filled once the price is fully past it. One storage slot.
    struct Backlog {
        int24 upLo;
        int24 upHi;
        int24 downLo;
        int24 downHi;
        bool up;
        bool down;
    }

    mapping(PoolId poolId => Backlog) public backlog;

    /// @dev Transient flag "this pool was swapped in this transaction", at slot keccak(poolId, SWAPPED_TAG).
    /// ConditionalOrders refuses to execute after a same-transaction swap, which blocks flash-loan price pushes.
    bytes32 internal constant SWAPPED_TAG = keccak256("RuleHook.swappedThisTx");

    /// @dev Tick before the current swap, written in beforeSwap.
    int24 transient _tickBefore;

    enum Op {
        Place,
        Cancel,
        Claim,
        Fill
    }

    event PoolRegistered(uint24 indexed index, PoolId indexed poolId);
    event LimitPlaced(
        uint256 indexed epochId, address indexed owner, int24 tickLower, bool sellToken0, uint128 liquidity, uint256 paid
    );
    event LimitCancelled(uint256 indexed epochId, address indexed owner, uint128 liquidity);
    event BucketFilled(uint256 indexed epochId, uint256 amount0, uint256 amount1);
    event LimitClaimed(uint256 indexed epochId, address indexed owner, uint256 amount0, uint256 amount1);
    event FillRewarded(uint256 indexed epochId, address indexed filler, uint256 amount);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- hook callbacks

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        _register(key);
        return this.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        _tickBefore = tick;
        bytes32 slot = _swappedSlot(id);
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        _fillCrossed(key, _tickBefore, tick);
        return (this.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------- pool table

    /// @notice Add an outside pool so orders can read its price or swap in it. Only hookless pools are accepted.
    function registerPool(PoolKey calldata key) external returns (uint24) {
        if (address(key.hooks) != address(0) && address(key.hooks) != address(this)) revert PoolNotAllowed();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert UnknownPool();
        return _register(key);
    }

    /// @notice True if the pool was swapped earlier in the current transaction.
    function swappedThisTx(PoolId id) external view returns (bool swapped) {
        bytes32 slot = _swappedSlot(id);
        assembly ("memory-safe") {
            swapped := tload(slot)
        }
    }

    function _swappedSlot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, SWAPPED_TAG));
    }

    function poolKeyAt(uint24 index) external view returns (PoolKey memory) {
        return _pools[index];
    }

    function _register(PoolKey memory key) internal returns (uint24 index) {
        PoolId id = key.toId();
        index = poolIndexOf[id];
        if (index != 0) return index;
        index = ++poolCount;
        _pools[index] = key;
        poolIndexOf[id] = index;
        emit PoolRegistered(index, id);
    }

    // ---------------------------------------------------------------- limit orders: user entry points

    /// @notice Place a limit order of `amount` tokens in the bucket starting at `tickLower`.
    /// sellToken0 = true: sell token0 when the price rises through the bucket (bucket must be above the price).
    /// sellToken0 = false: sell token1 when the price falls through the bucket (bucket must be below the price).
    /// Approve this contract for the token first; native ETH (currency0) is sent as msg.value, extra is refunded.
    function placeLimit(PoolKey calldata key, int24 tickLower, bool sellToken0, uint256 amount)
        external
        payable
        returns (uint256 epochId)
    {
        if (address(key.hooks) != address(this)) revert PoolNotAllowed();
        PoolId id = key.toId();
        uint24 poolIndex = poolIndexOf[id];
        if (poolIndex == 0) revert UnknownPool();
        int24 s = key.tickSpacing;
        if (tickLower % s != 0 || tickLower < TickMath.minUsableTick(s) || tickLower + s > TickMath.maxUsableTick(s))
        {
            revert BadTick();
        }
        Currency payCurrency = sellToken0 ? key.currency0 : key.currency1;
        if (!payCurrency.isAddressZero() && msg.value != 0) revert BadMsgValue();

        uint128 liquidity;
        {
            (, int24 tick,,) = poolManager.getSlot0(id);
            if (sellToken0 ? tick >= tickLower : tick < tickLower + s) revert WrongSide();
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickLower + s);
            uint256 usable = amount > 0 ? amount - 1 : 0; // the PoolManager rounds what it asks for up
            liquidity = sellToken0
                ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, usable)
                : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, usable);
        }
        if (liquidity == 0) revert ZeroLiquidity();

        epochId = openEpoch[id][tickLower][sellToken0];
        if (epochId == 0) {
            epochId = nextEpochId++;
            openEpoch[id][tickLower][sellToken0] = epochId;
            Epoch storage fresh = epochs[epochId];
            fresh.poolIndex = poolIndex;
            fresh.tickLower = tickLower;
            fresh.sellToken0 = sellToken0;
        }

        uint256 paid = abi.decode(
            poolManager.unlock(abi.encode(Op.Place, abi.encode(epochId, liquidity, msg.sender))), (uint256)
        );
        if (paid > amount) revert TooMuchIn();

        Epoch storage e = epochs[epochId];
        {
            // Keep fees already owed to this user, then reset their debt at the new size.
            Share storage sh = shares[epochId][msg.sender];
            (uint256 owed0, uint256 owed1) = _feesOwed(e, sh.liquidity, sh.debt0, sh.debt1);
            uint128 newLiquidity = sh.liquidity + liquidity;
            sh.liquidity = newLiquidity;
            sh.debt0 = uint128(FullMath.mulDiv(newLiquidity, e.feePerLiq0, Q128) - owed0);
            sh.debt1 = uint128(FullMath.mulDiv(newLiquidity, e.feePerLiq1, Q128) - owed1);
        }
        e.liquidityTotal += liquidity;
        if (!e.inBitmap && _bigEnough(id, e.liquidityTotal)) {
            _bitmap[id][sellToken0].flipTick(tickLower, s);
            e.inBitmap = true;
        }

        if (payCurrency.isAddressZero() && msg.value > paid) {
            (bool ok,) = msg.sender.call{value: msg.value - paid}("");
            if (!ok) revert RefundFailed();
        }
        emit LimitPlaced(epochId, msg.sender, tickLower, sellToken0, liquidity, paid);
    }

    /// @notice Take back an unfilled limit order (all of the caller's share) plus the fees it earned, sent to `to`.
    /// A partly crossed bucket returns a mix of both tokens.
    function cancelLimit(uint256 epochId, address to) external {
        Epoch storage e = epochs[epochId];
        if (e.poolIndex == 0) revert UnknownEpoch();
        if (e.filled) revert AlreadyFilled();
        Share memory sh = shares[epochId][msg.sender];
        if (sh.liquidity == 0) revert NothingToClaim();
        delete shares[epochId][msg.sender];

        uint128 liquidityBefore = e.liquidityTotal;
        e.liquidityTotal = liquidityBefore - sh.liquidity;
        PoolKey memory key = _pools[e.poolIndex];
        PoolId id = key.toId();
        if (e.inBitmap && !_bigEnough(id, e.liquidityTotal)) {
            _bitmap[id][e.sellToken0].flipTick(e.tickLower, key.tickSpacing);
            e.inBitmap = false;
        }
        if (e.liquidityTotal == 0) delete openEpoch[id][e.tickLower][e.sellToken0];

        poolManager.unlock(abi.encode(Op.Cancel, abi.encode(epochId, sh, to, liquidityBefore)));
        emit LimitCancelled(epochId, msg.sender, sh.liquidity);
    }

    /// @notice Collect your share of a filled bucket, paid out as tokens to `to`.
    function claimLimit(uint256 epochId, address to) external returns (uint256 amount0, uint256 amount1) {
        Epoch storage e = epochs[epochId];
        if (!e.filled) revert NotFilled();
        Share memory sh = shares[epochId][msg.sender];
        if (sh.liquidity == 0) revert NothingToClaim();
        delete shares[epochId][msg.sender];

        (amount0, amount1) = _claimAmounts(e, sh);
        poolManager.unlock(abi.encode(Op.Claim, abi.encode(epochId, amount0, amount1, to)));
        emit LimitClaimed(epochId, msg.sender, amount0, amount1);
    }

    /// @notice Fill a bucket the price has fully crossed but no swap filled (too small, or waiting in the backlog).
    /// The caller is paid its gas cost from the bucket's proceeds (native-ETH pools only, at most 1% of them).
    function fillBucket(PoolKey calldata key, int24 tickLower, bool sellToken0) external returns (uint256 reward) {
        if (address(key.hooks) != address(this)) revert PoolNotAllowed();
        PoolId id = key.toId();
        uint256 epochId = openEpoch[id][tickLower][sellToken0];
        if (epochId == 0 || epochs[epochId].liquidityTotal == 0) revert UnknownEpoch();
        (, int24 tick,,) = poolManager.getSlot0(id);
        if (sellToken0 ? tick < tickLower + key.tickSpacing : tick >= tickLower) revert NotCrossed();
        reward = abi.decode(poolManager.unlock(abi.encode(Op.Fill, abi.encode(epochId, msg.sender))), (uint256));
    }

    /// @notice What `fillBucket` pays, in wei of ETH, for `gasUsed` measured inside the fill.
    function fillGasCost(uint256 gasUsed) public view returns (uint256) {
        uint256 maxPrice = block.basefee + MAX_PRIORITY_FEE_WEI;
        uint256 price = tx.gasprice < maxPrice ? tx.gasprice : maxPrice;
        return ((gasUsed + FILL_GAS_OVERHEAD) * price * FILL_PREMIUM_BPS) / BPS;
    }

    function isFilled(uint256 epochId) external view returns (bool) {
        return epochs[epochId].filled;
    }

    /// @notice Your share of an epoch and what it would pay now if filled.
    function claimable(uint256 epochId, address owner) external view returns (uint256 amount0, uint256 amount1) {
        Epoch storage e = epochs[epochId];
        if (!e.filled || e.liquidityTotal == 0) return (0, 0);
        (amount0, amount1) = _claimAmounts(e, shares[epochId][owner]);
    }

    /// @dev After a fill: share of the fill proceeds + fees collected at earlier joins/leaves since this user joined.
    function _claimAmounts(Epoch storage e, Share memory sh) internal view returns (uint256 amount0, uint256 amount1) {
        (uint256 owed0, uint256 owed1) = _feesOwed(e, sh.liquidity, sh.debt0, sh.debt1);
        amount0 = FullMath.mulDiv(e.proceeds0, sh.liquidity, e.liquidityTotal) + owed0;
        amount1 = FullMath.mulDiv(e.proceeds1, sh.liquidity, e.liquidityTotal) + owed1;
    }

    function _feesOwed(Epoch storage e, uint128 liquidity, uint128 debt0, uint128 debt1)
        internal
        view
        returns (uint256 owed0, uint256 owed1)
    {
        if (liquidity == 0) return (0, 0);
        owed0 = FullMath.mulDiv(liquidity, e.feePerLiq0, Q128) - debt0;
        owed1 = FullMath.mulDiv(liquidity, e.feePerLiq1, Q128) - debt1;
    }

    /// @notice Position id the PoolManager uses for an epoch's shared position.
    function epochSalt(uint256 epochId) public pure returns (bytes32) {
        return bytes32((uint256(1) << 255) | epochId);
    }

    // ---------------------------------------------------------------- unlock callback

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 gasStart = gasleft(); // measured inside this frame, see ConditionalOrders.unlockCallback
        (Op op, bytes memory args) = abi.decode(data, (Op, bytes));
        if (op == Op.Place) {
            (uint256 epochId, uint128 liquidity, address payer) = abi.decode(args, (uint256, uint128, address));
            return abi.encode(_placeInPool(epochId, liquidity, payer));
        }
        if (op == Op.Cancel) {
            (uint256 epochId, Share memory sh, address owner, uint128 liquidityBefore) =
                abi.decode(args, (uint256, Share, address, uint128));
            _cancelInPool(epochId, sh, owner, liquidityBefore);
        } else if (op == Op.Claim) {
            (uint256 epochId, uint256 amount0, uint256 amount1, address owner) =
                abi.decode(args, (uint256, uint256, uint256, address));
            PoolKey memory key = _pools[epochs[epochId].poolIndex];
            _payFromClaims(key.currency0, owner, amount0);
            _payFromClaims(key.currency1, owner, amount1);
        } else {
            (uint256 epochId, address filler) = abi.decode(args, (uint256, address));
            PoolKey memory key = _pools[epochs[epochId].poolIndex];
            _fill(key, key.toId(), epochId);
            return abi.encode(_payFillReward(key, epochId, filler, gasStart));
        }
        return "";
    }

    /// @dev Pay the filler its gas cost out of the bucket's proceeds, before anyone can claim them. Only in pools
    /// where one token is native ETH: other tokens cannot be priced in gas without an outside price.
    function _payFillReward(PoolKey memory key, uint256 epochId, address filler, uint256 gasStart)
        internal
        returns (uint256 reward)
    {
        if (!key.currency0.isAddressZero()) return 0;
        Epoch storage e = epochs[epochId];
        uint256 cost = fillGasCost(gasStart - gasleft());
        if (e.sellToken0) {
            // proceeds are token1: convert the ETH cost at the pool price
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            cost = FullMath.mulDiv(FullMath.mulDiv(cost, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
            uint256 cap = (uint256(e.proceeds1) * MAX_FILL_REWARD_BPS) / BPS;
            reward = cost < cap ? cost : cap;
            e.proceeds1 -= uint128(reward);
            _payFromClaims(key.currency1, filler, reward);
        } else {
            uint256 cap = (uint256(e.proceeds0) * MAX_FILL_REWARD_BPS) / BPS;
            reward = cost < cap ? cost : cap;
            e.proceeds0 -= uint128(reward);
            _payFromClaims(key.currency0, filler, reward);
        }
        if (reward > 0) emit FillRewarded(epochId, filler, reward);
    }

    function _placeInPool(uint256 epochId, uint128 liquidity, address payer) internal returns (uint256 paid) {
        Epoch storage e = epochs[epochId];
        PoolKey memory key = _pools[e.poolIndex];
        (BalanceDelta d, BalanceDelta fees) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: e.tickLower,
                tickUpper: e.tickLower + key.tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: epochSalt(epochId)
            }),
            ""
        );
        // The payer covers the principal; fees the shared position had earned stay with the epoch.
        uint256 pay0 = _neg(d.amount0() - fees.amount0());
        uint256 pay1 = _neg(d.amount1() - fees.amount1());
        key.currency0.settle(poolManager, key.currency0.isAddressZero() ? address(this) : payer, pay0, false);
        key.currency1.settle(poolManager, payer, pay1, false);
        _collectFees(key, e, e.liquidityTotal, fees);
        paid = pay0 + pay1; // one of them is zero: the bucket holds a single token
    }

    function _cancelInPool(uint256 epochId, Share memory sh, address owner, uint128 liquidityBefore) internal {
        Epoch storage e = epochs[epochId];
        PoolKey memory key = _pools[e.poolIndex];
        (BalanceDelta d, BalanceDelta fees) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: e.tickLower,
                tickUpper: e.tickLower + key.tickSpacing,
                liquidityDelta: -int256(uint256(sh.liquidity)),
                salt: epochSalt(epochId)
            }),
            ""
        );
        // Fees just collected belong to everyone who held the bucket until now, this user included.
        _collectFees(key, e, liquidityBefore, fees);
        (uint256 owed0, uint256 owed1) = _feesOwed(e, sh.liquidity, sh.debt0, sh.debt1);

        key.currency0.take(poolManager, owner, _pos(d.amount0() - fees.amount0()), false);
        key.currency1.take(poolManager, owner, _pos(d.amount1() - fees.amount1()), false);
        _payFromClaims(key.currency0, owner, owed0);
        _payFromClaims(key.currency1, owner, owed1);
    }

    // ---------------------------------------------------------------- filling

    /// @dev Fill eligible buckets the price moved fully across, at most MAX_FILLS_PER_SWAP per swap.
    ///   price rose: sell-token0 buckets with tickLower in (from - s, to - s]
    ///   price fell: sell-token1 buckets with tickLower in (to, from]
    /// The new range is merged with any backlog left by earlier swaps, then filled while the cap allows. Any bucket
    /// in the range that the price is fully past is safe to fill whenever: its tokens are already fully converted.
    /// Storage is written only when a backlog exists or is created, so ordinary swaps pay one extra read.
    function _fillCrossed(PoolKey memory key, int24 from, int24 to) internal {
        PoolId id = key.toId();
        Backlog memory b = backlog[id];
        bool hadBacklog = b.up || b.down;
        if (to == from && !hadBacklog) return;
        int24 s = key.tickSpacing;

        if (to > from) {
            int24 lo = from - s;
            int24 hi = to - s;
            if (b.up) {
                if (lo < b.upLo) b.upLo = lo;
                if (hi > b.upHi) b.upHi = hi;
            } else {
                (b.upLo, b.upHi, b.up) = (lo, hi, true);
            }
        } else if (to < from) {
            if (b.down) {
                if (to < b.downLo) b.downLo = to;
                if (from > b.downHi) b.downHi = from;
            } else {
                (b.downLo, b.downHi, b.down) = (to, from, true);
            }
        }

        // Filling only removes liquidity, it never moves the price, so `to` stays valid for the whole walk.
        uint256 budget = MAX_FILLS_PER_SWAP;
        if (b.up) budget = _drainUp(key, id, b, to, budget);
        if (b.down) _drainDown(key, id, b, to, budget);
        if (hadBacklog || b.up || b.down) backlog[id] = b;
    }

    /// @dev Fill sell-token0 buckets in (upLo, min(upHi, tick - s)]. Buckets above that are not fully crossed any
    /// more (the price came back), so they are dropped from the backlog: they are live orders again.
    function _drainUp(PoolKey memory key, PoolId id, Backlog memory b, int24 tick, uint256 budget)
        internal
        returns (uint256)
    {
        int24 s = key.tickSpacing;
        int24 last = b.upHi < tick - s ? b.upHi : tick - s;
        int24 cursor = b.upLo;
        mapping(int16 => uint256) storage bm = _bitmap[id][true];
        while (cursor < last) {
            (int24 next, bool initialized) = bm.nextInitializedTickWithinOneWord(cursor, s, false);
            if (next > last) break;
            if (initialized) {
                if (budget == 0) {
                    (b.upLo, b.upHi) = (cursor, last);
                    return 0;
                }
                _fill(key, id, openEpoch[id][next][true]);
                --budget;
            }
            cursor = next;
        }
        b.up = false;
        return budget;
    }

    /// @dev Fill sell-token1 buckets in (max(downLo, tick), downHi].
    function _drainDown(PoolKey memory key, PoolId id, Backlog memory b, int24 tick, uint256 budget) internal {
        int24 s = key.tickSpacing;
        int24 floor = b.downLo > tick ? b.downLo : tick;
        int24 cursor = b.downHi;
        mapping(int16 => uint256) storage bm = _bitmap[id][false];
        while (cursor > floor) {
            (int24 next, bool initialized) = bm.nextInitializedTickWithinOneWord(cursor, s, true);
            if (next <= floor) break;
            if (initialized) {
                if (budget == 0) {
                    (b.downLo, b.downHi) = (floor, cursor);
                    return;
                }
                _fill(key, id, openEpoch[id][next][false]);
                --budget;
            }
            cursor = next - 1;
        }
        b.down = false;
    }

    /// @dev Remove the whole bucket and keep the proceeds as claims. Works inside a swap (the PoolManager is already
    /// unlocked) and from fillBucket. Must not revert: the swap would revert with it.
    function _fill(PoolKey memory key, PoolId id, uint256 epochId) internal {
        Epoch storage e = epochs[epochId];
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: e.tickLower,
                tickUpper: e.tickLower + key.tickSpacing,
                liquidityDelta: -int256(uint256(e.liquidityTotal)),
                salt: epochSalt(epochId)
            }),
            ""
        );
        uint256 a0 = _pos(d.amount0());
        uint256 a1 = _pos(d.amount1());
        if (a0 > 0) {
            poolManager.mint(address(this), key.currency0.toId(), a0);
            e.proceeds0 = uint128(a0);
        }
        if (a1 > 0) {
            poolManager.mint(address(this), key.currency1.toId(), a1);
            e.proceeds1 = uint128(a1);
        }
        e.filled = true;

        if (e.inBitmap) {
            _bitmap[id][e.sellToken0].flipTick(e.tickLower, key.tickSpacing);
            e.inBitmap = false;
        }
        delete openEpoch[id][e.tickLower][e.sellToken0];
        emit BucketFilled(epochId, a0, a1);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Bucket large enough to be filled inside swaps: at least MIN_FILL_BPS of the pool's active liquidity.
    function _bigEnough(PoolId id, uint128 bucketLiquidity) internal view returns (bool) {
        return bucketLiquidity > 0
            && uint256(bucketLiquidity) * BPS >= uint256(poolManager.getLiquidity(id)) * MIN_FILL_BPS;
    }

    /// @dev Keep fees collected at a join or leave as ERC-6909 claims, owed to the `holders` liquidity that earned
    /// them.
    function _collectFees(PoolKey memory key, Epoch storage e, uint128 holders, BalanceDelta fees) internal {
        uint256 f0 = _pos(fees.amount0());
        uint256 f1 = _pos(fees.amount1());
        // A fresh position has no fees, so holders == 0 only ever comes with zero fees.
        if (f0 > 0) {
            poolManager.mint(address(this), key.currency0.toId(), f0);
            if (holders > 0) e.feePerLiq0 += FullMath.mulDiv(f0, Q128, holders);
        }
        if (f1 > 0) {
            poolManager.mint(address(this), key.currency1.toId(), f1);
            if (holders > 0) e.feePerLiq1 += FullMath.mulDiv(f1, Q128, holders);
        }
    }

    /// @dev Burn this hook's claims and send the tokens.
    function _payFromClaims(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        currency.settle(poolManager, address(this), amount, true);
        currency.take(poolManager, to, amount, false);
    }

    function _pos(int128 x) internal pure returns (uint256) {
        return x > 0 ? uint256(uint128(x)) : 0;
    }

    function _neg(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : 0;
    }
}
