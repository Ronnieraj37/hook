import deployment from "./generated/deployment.json";

export const CORE = deployment.core as {
  poolManager: `0x${string}`;
  positionManager: `0x${string}`;
  swapRouter: `0x${string}`;
  permit2: `0x${string}`;
  ruleHook: `0x${string}`;
  conditionalOrders: `0x${string}`;
  faucet: `0x${string}`;
  deployBlock: number;
};

export const ZERO = "0x0000000000000000000000000000000000000000" as const;

export type Token = { symbol: string; address: `0x${string}`; decimals: number; native?: boolean };

const DECIMALS: Record<string, number> = { WETH: 18, WBTC: 8, USDC: 6, USDT: 6, DAI: 18, LINK: 18 };

export const TOKENS: Token[] = [
  ...Object.entries(deployment.tokens as Record<string, string>).map(([symbol, address]) => ({
    symbol,
    address: address as `0x${string}`,
    decimals: DECIMALS[symbol] ?? 18,
  })),
  { symbol: "ETH", address: ZERO, decimals: 18, native: true },
];

export const tokenByAddress = (a: string) => TOKENS.find((t) => t.address.toLowerCase() === a.toLowerCase())!;

/** The token people think in: prices are shown as "1 base = x quote". Earlier in this list = better quote. */
const QUOTE_RANK = ["USDC", "USDT", "DAI", "WETH", "ETH", "WBTC", "LINK"];

export type Pool = {
  name: string;
  index: number;
  key: {
    currency0: `0x${string}`;
    currency1: `0x${string}`;
    fee: number;
    tickSpacing: number;
    hooks: `0x${string}`;
  };
  token0: Token;
  token1: Token;
  base: Token;
  quote: Token;
  baseIs0: boolean;
  hooked: boolean;
  label: string; // "WETH / USDC · 0.3%"
};

type RawPool = {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
  poolIndex: number;
};

export const POOLS: Pool[] = Object.entries(deployment.pools as Record<string, RawPool>)
  .map(([name, p]) => {
    const token0 = tokenByAddress(p.currency0);
    const token1 = tokenByAddress(p.currency1);
    const r0 = QUOTE_RANK.indexOf(token0.symbol);
    const r1 = QUOTE_RANK.indexOf(token1.symbol);
    const baseIs0 = r0 > r1; // the worse quote is the base
    const base = baseIs0 ? token0 : token1;
    const quote = baseIs0 ? token1 : token0;
    const hooked = p.hooks.toLowerCase() !== ZERO;
    return {
      name,
      index: p.poolIndex,
      key: {
        currency0: p.currency0 as `0x${string}`,
        currency1: p.currency1 as `0x${string}`,
        fee: p.fee,
        tickSpacing: p.tickSpacing,
        hooks: p.hooks as `0x${string}`,
      },
      token0,
      token1,
      base,
      quote,
      baseIs0,
      hooked,
      label: `${base.symbol} / ${quote.symbol} · ${p.fee / 10_000}%${hooked ? "" : " (no hook)"}`,
    };
  })
  .sort((a, b) => a.index - b.index);

export const poolByIndex = (i: number) => POOLS.find((p) => p.index === i);

/** Pools of the same pair (any fee), for "price in another pool" triggers and as swap venues. */
export const samePair = (p: Pool) =>
  POOLS.filter((q) => q.index !== p.index && q.key.currency0 === p.key.currency0 && q.key.currency1 === p.key.currency1);

// ---------------------------------------------------------------- price math

export const MIN_TICK = -887272;
export const MAX_TICK = 887272;
export const minUsable = (s: number) => Math.ceil(MIN_TICK / s) * s;
export const maxUsable = (s: number) => Math.floor(MAX_TICK / s) * s;
const LN = Math.log(1.0001);

/** Price of the base token in quote tokens at a tick. */
export function priceAtTick(p: Pool, tick: number): number {
  const t1per0 = Math.pow(1.0001, tick) * Math.pow(10, p.token0.decimals - p.token1.decimals);
  return p.baseIs0 ? t1per0 : 1 / t1per0;
}

/** Tick (not rounded) where the base token costs `price` quote tokens. */
export function tickAtPrice(p: Pool, price: number): number {
  const t1per0 = p.baseIs0 ? price : 1 / price;
  return Math.log(t1per0 * Math.pow(10, p.token1.decimals - p.token0.decimals)) / LN;
}

/** Ticks for a % move (always positive). */
export const ticksForPct = (pct: number) => Math.max(0, Math.round(Math.log(1 + pct / 100) / LN));
export const pctForTicks = (ticks: number) => (Math.pow(1.0001, ticks) - 1) * 100;

export const floorTo = (t: number, s: number) => Math.floor(t / s) * s;

/** Range around the current tick, `pct` each way in price terms, rounded outward to the spacing. */
export function rangeAround(p: Pool, tick: number, pct: number | "full"): [number, number] {
  const s = p.key.tickSpacing;
  if (pct === "full") return [minUsable(s), maxUsable(s)];
  const up = Math.round(Math.log(1 + pct / 100) / LN);
  const down = Math.round(-Math.log(1 - pct / 100) / LN);
  return [Math.max(minUsable(s), floorTo(tick - down, s)), Math.min(maxUsable(s), floorTo(tick + up, s) + s)];
}

/** Price range in base terms (low, high) for a tick range. */
export function priceRange(p: Pool, tl: number, tu: number): [number, number] {
  const a = priceAtTick(p, tl);
  const b = priceAtTick(p, tu);
  return a < b ? [a, b] : [b, a];
}

// ---------------------------------------------------------------- liquidity math (floats, fine for UI amounts)

const sq = (t: number) => Math.pow(1.0001, t / 2);

/** Raw token amounts held by liquidity L in [tl, tu] at sqrt price sp (raw units). */
export function amountsFor(sp: number, tl: number, tu: number, L: number): [number, number] {
  const a = sq(tl);
  const b = sq(tu);
  if (sp <= a) return [(L * (b - a)) / (a * b), 0];
  if (sp >= b) return [0, L * (b - a)];
  return [(L * (b - sp)) / (sp * b), L * (sp - a)];
}

/** Liquidity from a raw amount of token0 or token1 (Infinity if that token is not used at this price). */
export function liquidityFor(sp: number, tl: number, tu: number, raw: number, isToken0: boolean): number {
  const a = sq(tl);
  const b = sq(tu);
  if (isToken0) {
    if (sp >= b) return Infinity;
    const lo = Math.max(sp, a);
    return (raw * lo * b) / (b - lo);
  }
  if (sp <= a) return Infinity;
  const hi = Math.min(sp, b);
  return raw / (hi - a);
}

export const sqrtFromX96 = (x: bigint) => Number(x) / 2 ** 96;

// ---------------------------------------------------------------- formatting

export function fmt(n: number, digits = 5): string {
  if (!isFinite(n)) return "–";
  if (n === 0) return "0";
  const abs = Math.abs(n);
  if (abs >= 1e6) return n.toLocaleString("en-US", { maximumFractionDigits: 0 });
  if (abs >= 1) return n.toLocaleString("en-US", { maximumSignificantDigits: Math.max(digits, Math.ceil(Math.log10(abs)) + 2) });
  return n.toPrecision(Math.min(digits, 4)).replace(/\.?0+$/, "");
}

export const toRaw = (amount: number, decimals: number) => BigInt(Math.floor(amount * 10 ** Math.min(decimals, 12))) * 10n ** BigInt(Math.max(0, decimals - 12));
export const fromRaw = (raw: bigint, decimals: number) => Number(raw) / 10 ** decimals;
