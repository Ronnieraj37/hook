// Encodes every template on every ruled pool with the frontend code and dry-runs createOrder on Sepolia
// (eth_call from the deployer, which holds test tokens and has approved the contract). Nothing is sent.
// Also checks decode(encode(rules)) describes the same thing.  Run: npx tsx scripts/check-rules.ts
import { createPublicClient, http } from "viem";
import { sepolia } from "viem/chains";
import { conditionalOrdersAbi } from "../lib/generated/abis";
import { CORE, POOLS, amountsFor, liquidityFor, priceAtTick, rangeAround, sqrtFromX96 } from "../lib/pools";
import { TEMPLATES, decodeRules, describeLane, encodeRules, isValid, validate, type Rules } from "../lib/rules";

const DEPLOYER = "0x02847D22C33f5F060Bd27e69F1a413AD44cab213";
const client = createPublicClient({ chain: sepolia, transport: http("https://ethereum-sepolia-rpc.publicnode.com") });
const c = { address: CORE.conditionalOrders, abi: conditionalOrdersAbi } as const;

async function main() {
  let ok = 0;
  let bad = 0;
  for (const pool of POOLS.filter((p) => p.hooked)) {
    const [sqrtX96, tickB] = await client.readContract({ ...c, functionName: "poolState", args: [pool.index] });
    const tick = Number(tickB);
    const sp = sqrtFromX96(sqrtX96);
    const price = priceAtTick(pool, tick);
    const [tl, tu] = rangeAround(pool, tick, 5);
    const usd = pool.base.symbol === "ETH" ? 0.001 : 1; // a small position
    const L = liquidityFor(sp, tl, tu, usd * 10 ** pool.base.decimals, pool.base.address === pool.token0.address);
    const [a0, a1] = amountsFor(sp, tl, tu, L);
    const extra: [string, Rules][] = [
      ["price in other pool", { down: { trigger: { kind: "otherPool", poolIndex: 7, price: 1500 }, actions: [{ kind: "withdraw", pct: 100 }], repeat: false }, up: { trigger: null, actions: [], repeat: false } }],
      ["collect fees only", { down: { trigger: null, actions: [], repeat: false }, up: { trigger: { kind: "timer", hours: 6 }, actions: [{ kind: "collect" }], repeat: true } }],
      ["price ladder", { down: { trigger: null, actions: [], repeat: false }, up: { trigger: { kind: "price", price: price * 1.03 }, actions: [{ kind: "withdraw", pct: 25 }], repeat: true, stepPct: 3 } }],
    ];
    const cases: [string, Rules][] = [...TEMPLATES.map((t) => [t.name, t.build(pool, price)] as [string, Rules]), ...extra];
    for (const [name, rules] of cases) {
      const v = validate(pool, rules);
      if (!isValid(v)) {
        console.log(`  skip ${pool.label} / ${name}: ${JSON.stringify(v)}`);
        continue;
      }
      const enc = encodeRules(pool, rules);
      const max0 = BigInt(Math.ceil(a0 * 1.05)) + 1n;
      const max1 = BigInt(Math.ceil(a1 * 1.05)) + 1n;
      try {
        await client.simulateContract({
          ...c,
          account: DEPLOYER,
          functionName: "createOrder",
          args: [
            {
              key: pool.key,
              tickLower: tl,
              tickUpper: tu,
              liquidity: BigInt(Math.floor(L * 0.999)),
              amount0Max: max0,
              amount1Max: max1,
              swapPoolIndex: 0,
              expiry: Math.floor(Date.now() / 1000) + 86400,
              maxKeeperFeeBps: 10,
              maxSlippage: 10,
              lower: enc.lower,
              upper: enc.upper,
            },
          ],
          value: pool.token0.native ? max0 : 0n,
        });
        // decode what we would store and compare the plain-English meaning
        const back = decodeRules(pool, { ...enc.lower, edge: tl }, { ...enc.upper, edge: tu });
        // Prices snap to ticks and widths to the spacing, so compare contract data: encode(decode(x)) must equal x.
        const again = encodeRules(pool, back);
        const strip = (x: object) => JSON.stringify({ ...x, edge: 0, lastRun: 0 });
        const same = strip(again.lower) === strip(enc.lower) && strip(again.upper) === strip(enc.upper);
        if (!same) {
          bad++;
          console.log(`  DECODE MISMATCH ${pool.label} / ${name}`);
          console.log("    sent   ", strip(enc.lower), strip(enc.upper));
          console.log("    decoded", strip(again.lower), strip(again.upper));
        } else ok++;
      } catch (e) {
        bad++;
        console.log(`  REVERT ${pool.label} / ${name}: ${(e as Error).message.split("\n").slice(0, 3).join(" ")}`);
      }
    }
  }
  console.log(`\n${ok} accepted by the contract and decoded back the same, ${bad} problems`);
  process.exit(bad ? 1 : 0);
}
main();
