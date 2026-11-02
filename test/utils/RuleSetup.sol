// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./libraries/EasyPosm.sol";
import {BaseTest} from "./BaseTest.sol";

import {RuleHook} from "../../src/RuleHook.sol";
import {ConditionalOrders} from "../../src/ConditionalOrders.sol";

/// @dev Deploys the hook, the conditional-order contract and one pool (fee 0.3%, spacing 60, price 1) with
/// 100e18 full-range liquidity from a normal LP. alice and bob get tokens and approve both contracts.
abstract contract RuleSetup is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;
    RuleHook hook;
    ConditionalOrders orders;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    function setUp() public virtual {
        vm.warp(1_790_000_000); // Sep 2026; order times are stored relative to 2026-01-01
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        );
        deployCodeTo("RuleHook.sol:RuleHook", abi.encode(poolManager), flags);
        hook = RuleHook(flags);
        orders = new ConditionalOrders(poolManager, hook);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        positionManager.mint(
            poolKey,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        _fund(alice);
        _fund(bob);
    }

    function _fund(address who) internal {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t0.transfer(who, 1_000e18);
        t1.transfer(who, 1_000e18);
        vm.startPrank(who);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        t0.approve(address(orders), type(uint256).max);
        t1.approve(address(orders), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(poolId);
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.balanceOf(who);
    }
}
