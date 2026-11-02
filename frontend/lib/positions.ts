"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { positionManagerAbi } from "./abis-extra";
import { conditionalOrdersAbi } from "./generated/abis";
import { CORE, type Pool, POOLS, amountsFor, poolByIndex, sqrtFromX96, tokenByAddress } from "./pools";
import { type Advanced, type LaneId, type Rules, type Side, decodeRules, sideFor } from "./rules";

export type RulePosition = {
  kind: "rules";
  id: bigint;
  pool: Pool;
  tickLower: number;
  tickUpper: number;
  tick: number;
  amount0: number; // human units
  amount1: number;
  rules: Rules;
  advanced: Advanced;
  expiry: number;
  ready: Record<LaneId, boolean>;
};

export type PlainPosition = {
  kind: "plain";
  id: bigint; // PositionManager NFT id
  pool: Pool;
  tickLower: number;
  tickUpper: number;
  tick: number;
  amount0: number;
  amount1: number;
};

const c = { address: CORE.conditionalOrders, abi: conditionalOrdersAbi } as const;
type Client = NonNullable<ReturnType<typeof usePublicClient>>;

export async function loadRulePosition(client: Client, id: bigint): Promise<RulePosition | null> {
  const [order, st] = await client.readContract({ ...c, functionName: "getOrder", args: [id] });
  if (order.owner === "0x0000000000000000000000000000000000000000") return null;
  const pool = poolByIndex(Number(order.poolIndex));
  if (!pool) return null;
  const [amounts, state, readyLower, readyUpper] = await Promise.all([
    client.readContract({ ...c, functionName: "orderAmounts", args: [id] }),
    client.readContract({ ...c, functionName: "poolState", args: [order.poolIndex] }),
    client.readContract({ ...c, functionName: "canExecute", args: [id, false] }),
    client.readContract({ ...c, functionName: "canExecute", args: [id, true] }),
  ]);
  const lower = st.lower as unknown as Side;
  const upper = st.upper as unknown as Side;
  const rules = decodeRules(pool, lower, upper);
  const ready = (lane: LaneId) => (sideFor(pool, lane, rules[lane]) === "upper" ? readyUpper : readyLower);
  return {
    kind: "rules",
    id,
    pool,
    tickLower: Number(lower.edge),
    tickUpper: Number(upper.edge),
    tick: Number(state[1]),
    amount0: Number(amounts[0]) / 10 ** pool.token0.decimals,
    amount1: Number(amounts[1]) / 10 ** pool.token1.decimals,
    rules,
    advanced: {
      keeperFeeBps: Number(order.maxKeeperFeeBps),
      slippagePct: Number(order.maxSlippage) / 10,
      expiryDays: Math.max(1, Math.round((Number(order.expiry) - Date.now() / 1000) / 86400)),
    },
    expiry: Number(order.expiry),
    ready: { down: ready("down"), up: ready("up") },
  };
}

/** Plain Uniswap positions in our pools that this wallet holds (found from NFT transfer logs since our deploy). */
async function loadPlain(client: Client, owner: `0x${string}`): Promise<PlainPosition[]> {
  const logs = await client.getLogs({
    address: CORE.positionManager,
    event: positionManagerAbi.find((x) => x.type === "event" && x.name === "Transfer")!,
    args: { to: owner },
    fromBlock: BigInt(CORE.deployBlock),
    toBlock: "latest",
  });
  const ids = [...new Set(logs.map((l) => l.args.id!))];
  const out: PlainPosition[] = [];
  for (const id of ids) {
    const [holder, [key, info], liq] = await Promise.all([
      client.readContract({ address: CORE.positionManager, abi: positionManagerAbi, functionName: "ownerOf", args: [id] }),
      client.readContract({ address: CORE.positionManager, abi: positionManagerAbi, functionName: "getPoolAndPositionInfo", args: [id] }),
      client.readContract({ address: CORE.positionManager, abi: positionManagerAbi, functionName: "getPositionLiquidity", args: [id] }),
    ]);
    if (holder.toLowerCase() !== owner.toLowerCase() || liq === 0n) continue;
    const pool = POOLS.find(
      (p) => p.key.currency0.toLowerCase() === key.currency0.toLowerCase() && p.key.currency1.toLowerCase() === key.currency1.toLowerCase() && p.key.fee === key.fee && p.key.hooks.toLowerCase() === key.hooks.toLowerCase(),
    );
    if (!pool) continue;
    const s24 = (x: bigint) => {
      const v = Number(x & 0xffffffn);
      return v >= 0x800000 ? v - 0x1000000 : v;
    };
    const tickLower = s24(info >> 8n);
    const tickUpper = s24(info >> 32n);
    const [sqrtX96, tick] = await client.readContract({ ...c, functionName: "poolState", args: [pool.index] });
    const [a0, a1] = amountsFor(sqrtFromX96(sqrtX96), tickLower, tickUpper, Number(liq));
    out.push({
      kind: "plain",
      id,
      pool,
      tickLower,
      tickUpper,
      tick: Number(tick),
      amount0: a0 / 10 ** pool.token0.decimals,
      amount1: a1 / 10 ** pool.token1.decimals,
    });
  }
  return out;
}

export function useMyPositions(owner?: `0x${string}`) {
  const client = usePublicClient();
  return useQuery({
    queryKey: ["positions", owner],
    enabled: !!owner && !!client,
    queryFn: async () => {
      const ids = await client!.readContract({ ...c, functionName: "ordersOf", args: [owner!] });
      const rules = (await Promise.all([...ids].reverse().map((id) => loadRulePosition(client!, id)))).filter(Boolean) as RulePosition[];
      const plain = await loadPlain(client!, owner!).catch(() => [] as PlainPosition[]);
      // payouts held for this wallet (if a transfer to it ever failed)
      const held: { symbol: string; amount: number; currency: `0x${string}` }[] = [];
      const seen = new Set<string>(rules.flatMap((r) => [r.pool.token0.address, r.pool.token1.address]));
      for (const a of seen) {
        const amount = await client!.readContract({ ...c, functionName: "owed", args: [owner!, a as `0x${string}`] });
        if (amount > 0n) {
          const t = tokenByAddress(a);
          held.push({ symbol: t.symbol, amount: Number(amount) / 10 ** t.decimals, currency: t.address });
        }
      }
      return { rules, plain, held };
    },
  });
}

export function useRulePosition(id: bigint) {
  const client = usePublicClient();
  return useQuery({ queryKey: ["position", String(id)], enabled: !!client, queryFn: () => loadRulePosition(client!, id) });
}
