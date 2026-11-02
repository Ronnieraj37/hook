// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {RuleHook} from "../../src/RuleHook.sol";

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Creates test pools at today's Chainlink (Sepolia) prices and adds a normal LP's liquidity: some pools
/// full range (low concentration), some tight around the price (high concentration). Most pools use RuleHook; one
/// hookless pool is added to the hook's pool table so orders can read its price and swap in it.
///   forge script script/sepolia/03_CreatePools.s.sol --rpc-url sepolia --broadcast
contract CreatePools is Script {
    using PoolIdLibrary for PoolKey;

    string constant OUT = "./deployments/sepolia-pools.json";

    struct Tok {
        address addr; // address(0) = native ETH
        uint8 decimals;
        uint256 usd; // price, 8 decimals
    }

    IPoolManager poolManager;
    IPositionManager posm;
    IPermit2 permit2;
    RuleHook hook;
    address me;
    string poolsJson;
    uint256 poolCount;

    function run() external {
        string memory core = vm.readFile("./deployments/sepolia-core.json");
        string memory toks = vm.readFile("./deployments/sepolia-tokens.json");
        poolManager = IPoolManager(vm.parseJsonAddress(core, ".poolManager"));
        posm = IPositionManager(vm.parseJsonAddress(core, ".positionManager"));
        permit2 = IPermit2(vm.parseJsonAddress(core, ".permit2"));
        hook = RuleHook(vm.parseJsonAddress(core, ".ruleHook"));

        // Chainlink feeds on Sepolia (8 decimals). There is no USDT feed there: USDT is priced at $1.
        uint256 ethUsd = _feed(0x694AA1769357215DE4FAC081bf1f309aDC325306);
        Tok memory WETH = Tok(vm.parseJsonAddress(toks, ".WETH"), 18, ethUsd);
        Tok memory WBTC = Tok(vm.parseJsonAddress(toks, ".WBTC"), 8, _feed(0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43));
        Tok memory USDC = Tok(vm.parseJsonAddress(toks, ".USDC"), 6, _feed(0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E));
        Tok memory USDT = Tok(vm.parseJsonAddress(toks, ".USDT"), 6, 1e8);
        Tok memory DAI = Tok(vm.parseJsonAddress(toks, ".DAI"), 18, _feed(0x14866185B1962B63C3Ea9E03Bc1da838bab34C19));
        Tok memory LINK = Tok(vm.parseJsonAddress(toks, ".LINK"), 18, _feed(0xc59E3633BAAC79493d908e63626716e204A45EdF));
        Tok memory ETH = Tok(address(0), 18, ethUsd);

        vm.startBroadcast();
        me = msg.sender;
        address[6] memory erc20s = [WETH.addr, WBTC.addr, USDC.addr, USDT.addr, DAI.addr, LINK.addr];
        for (uint256 i; i < erc20s.length; ++i) {
            IERC20(erc20s[i]).approve(address(permit2), type(uint256).max);
            permit2.approve(erc20s[i], address(posm), type(uint160).max, type(uint48).max);
        }

        // name, token A, token B, fee, spacing, hooked, positions: (half width in ticks, 0 = full range; $ per side)
        _pool(Spec("WETH_USDC_3000", WETH, USDC, 3000, 60, true, 0, 5_000_000, 488, 2_000_000)); // full + +-5%
        _pool(Spec("WBTC_USDC_3000", WBTC, USDC, 3000, 60, true, 0, 5_000_000, 1000, 2_000_000)); // full + +-10%
        _pool(Spec("WETH_WBTC_500", WETH, WBTC, 500, 10, true, 200, 2_000_000, 0, 0)); // +-2%
        _pool(Spec("USDC_USDT_100", USDC, USDT, 100, 1, true, 20, 5_000_000, 0, 0)); // +-0.2%
        _pool(Spec("LINK_WETH_10000", LINK, WETH, 10000, 200, true, 0, 2_000_000, 0, 0)); // full
        _pool(Spec("DAI_USDC_100", DAI, USDC, 100, 1, true, 50, 3_000_000, 0, 0)); // +-0.5%
        _pool(Spec("WETH_USDC_500_NOHOOK", WETH, USDC, 500, 10, false, 0, 5_000_000, 0, 0)); // full, no hook
        // Native ETH: small, it uses real Sepolia ETH. Here the keeper is paid exact gas cost.
        _pool(Spec("ETH_USDC_3000", ETH, USDC, 3000, 60, true, 0, 10, 488, 10)); // ~$10 per side each
        vm.stopBroadcast();

        vm.writeJson(poolsJson, OUT);
    }

    function _feed(address f) internal view returns (uint256) {
        (, int256 answer,,,) = IFeed(f).latestRoundData();
        require(answer > 0, "bad feed");
        return uint256(answer);
    }

    struct Spec {
        string name;
        Tok a;
        Tok b;
        uint24 fee;
        int24 spacing;
        bool hooked;
        int24 w1; // half width in ticks of the first position (0 = full range)
        uint256 usd1; // $ per side
        int24 w2; // second position (usd2 = 0: none)
        uint256 usd2;
    }

    function _pool(Spec memory sp) internal {
        (Tok memory t0, Tok memory t1) = sp.a.addr < sp.b.addr ? (sp.a, sp.b) : (sp.b, sp.a);
        PoolKey memory key = PoolKey(
            Currency.wrap(t0.addr),
            Currency.wrap(t1.addr),
            sp.fee,
            sp.spacing,
            IHooks(sp.hooked ? address(hook) : address(0))
        );
        // price = token1 units per token0 unit
        uint160 sqrtP = uint160(
            FixedPointMathLib.sqrt(FullMath.mulDiv(t0.usd * 10 ** t1.decimals, 1 << 192, t1.usd * 10 ** t0.decimals))
        );
        int24 tick = poolManager.initialize(key, sqrtP);
        if (!sp.hooked) hook.registerPool(key);

        if (sp.usd1 > 0) _add(key, t0, t1, sqrtP, _range(tick, sp.w1, sp.spacing), sp.usd1);
        if (sp.usd2 > 0) _add(key, t0, t1, sqrtP, _range(tick, sp.w2, sp.spacing), sp.usd2);
        _record(sp.name, key);
    }

    function _record(string memory name, PoolKey memory key) internal {
        vm.serializeAddress(name, "currency0", Currency.unwrap(key.currency0));
        vm.serializeAddress(name, "currency1", Currency.unwrap(key.currency1));
        vm.serializeUint(name, "fee", key.fee);
        vm.serializeInt(name, "tickSpacing", key.tickSpacing);
        vm.serializeAddress(name, "hooks", address(key.hooks));
        vm.serializeBytes32(name, "poolId", PoolId.unwrap(key.toId()));
        string memory out = vm.serializeUint(name, "poolIndex", hook.poolIndexOf(key.toId()));
        poolsJson = vm.serializeString("pools", name, out);
        console.log(name, hook.poolIndexOf(key.toId()));
    }

    function _range(int24 tick, int24 halfWidth, int24 s) internal pure returns (int24[2] memory r) {
        if (halfWidth == 0) {
            r[0] = TickMath.minUsableTick(s);
            r[1] = TickMath.maxUsableTick(s);
        } else {
            r[0] = _floor(tick - halfWidth, s);
            r[1] = _floor(tick + halfWidth, s) + s;
        }
    }

    function _add(
        PoolKey memory key,
        Tok memory t0,
        Tok memory t1,
        uint160 sqrtP,
        int24[2] memory r,
        uint256 usdPerSide
    ) internal {
        uint256 amt0 = usdPerSide * 1e8 * 10 ** t0.decimals / t0.usd;
        uint256 amt1 = usdPerSide * 1e8 * 10 ** t1.decimals / t1.usd;
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(r[0]), TickMath.getSqrtPriceAtTick(r[1]), amt0, amt1
        );
        _mint(key, r, liq, amt0 + amt0 / 100 + 1, amt1 + amt1 / 100 + 1);
    }

    /// @dev Mint a position NFT to the deployer: MINT_POSITION, SETTLE_PAIR, and SWEEP the unused ETH back.
    function _mint(PoolKey memory key, int24[2] memory r, uint128 liq, uint256 max0, uint256 max1) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, r[0], r[1], uint256(liq), uint128(max0), uint128(max1), me, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, me);
        uint256 value = key.currency0.isAddressZero() ? max0 : 0;
        posm.modifyLiquidities{value: value}(abi.encode(actions, params), block.timestamp + 600);
    }

    function _floor(int24 t, int24 s) internal pure returns (int24) {
        int24 c = t / s;
        if (t < 0 && t % s != 0) c--;
        return c * s;
    }
}
