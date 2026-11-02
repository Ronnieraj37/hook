"use client";

import { useQuery } from "@tanstack/react-query";
import { ArrowDown, Info } from "lucide-react";
import { useMemo, useState } from "react";
import { type Abi } from "viem";
import { useAccount, usePublicClient, useReadContract } from "wagmi";
import { Menu, TokenBox, TokenIcon, TokenPill, TxLine } from "@/components/ui";
import { QUOTER, quoterAbi } from "@/lib/abis-extra";
import { conditionalOrdersAbi, routerAbi, ruleHookAbi } from "@/lib/generated/abis";
import { CORE, POOLS, type Pool, type Token, TOKENS, fmt, priceAtTick, toRaw } from "@/lib/pools";
import { useTokenBalance, useTx } from "@/lib/tx";

const poolsFor = (a: Token, b: Token) =>
  POOLS.filter((p) => (p.token0.address === a.address && p.token1.address === b.address) || (p.token0.address === b.address && p.token1.address === a.address));
const tradable = (t: Token) => TOKENS.filter((x) => x.address !== t.address && poolsFor(t, x).length > 0);
const sym = (s: string) => s;

export default function Swap() {
  const [mode, setMode] = useState<"swap" | "limit">("swap");
  return (
    <div className="mx-auto flex max-w-[480px] flex-col gap-4 px-4 py-8">
      <div className="flex gap-1">
        {(["swap", "limit"] as const).map((m) => (
          <button
            key={m}
            onClick={() => setMode(m)}
            className={`rounded-full px-4 py-1.5 text-[15px] font-semibold ${mode === m ? "bg-[var(--line2)] text-[var(--ink)]" : "text-[var(--muted)] hover:text-[var(--ink)]"}`}
          >
            {m === "swap" ? "Swap" : "Limit"}
          </button>
        ))}
      </div>
      {mode === "swap" ? <MarketSwap /> : <LimitOrder />}
      {mode === "limit" && <MyLimitOrders />}
    </div>
  );
}

// ---------------------------------------------------------------- market swap

function MarketSwap() {
  const { address, isConnected } = useAccount();
  const client = usePublicClient();
  const [tokIn, setTokIn] = useState(TOKENS.find((t) => t.symbol === "WETH")!);
  const [tokOut, setTokOut] = useState(TOKENS.find((t) => t.symbol === "USDC")!);
  const [amount, setAmount] = useState("");
  const [menu, setMenu] = useState<"in" | "out" | null>(null);
  const [route, setRoute] = useState<number | null>(null); // pool index, null = best price
  const balIn = useTokenBalance(tokIn);
  const balOut = useTokenBalance(tokOut);
  const tx = useTx();
  const amt = parseFloat(amount);

  const quote = useQuery({
    queryKey: ["quote", tokIn.address, tokOut.address, amount],
    enabled: amt > 0 && !!client,
    staleTime: 10_000,
    queryFn: async () => {
      const raw = toRaw(amt, tokIn.decimals);
      const all: { pool: Pool; out: bigint }[] = [];
      for (const pool of poolsFor(tokIn, tokOut)) {
        try {
          const { result } = await client!.simulateContract({
            address: QUOTER,
            abi: quoterAbi,
            functionName: "quoteExactInputSingle",
            args: [{ poolKey: pool.key, zeroForOne: tokIn.address === pool.token0.address, exactAmount: raw, hookData: "0x" }],
          });
          all.push({ pool, out: result[0] });
        } catch {
          /* pool cannot fill this size */
        }
      }
      return all.sort((a, b) => (b.out > a.out ? 1 : -1));
    },
  });
  const chosen = quote.data?.find((x) => x.pool.index === route) ?? quote.data?.[0];
  const out = chosen ? Number(chosen.out) / 10 ** tokOut.decimals : 0;
  const minOut = chosen ? (chosen.out * 995n) / 1000n : 0n; // 0.5% slippage
  const short = balIn !== undefined && amt > 0 && toRaw(amt, tokIn.decimals) > balIn;

  const flip = () => {
    setTokIn(tokOut);
    setTokOut(tokIn);
    setAmount(out ? trim(out) : "");
  };

  const swap = () =>
    tx.run(async () => {
      if (!chosen || !address) return;
      const pool = chosen.pool;
      const raw = toRaw(amt, tokIn.decimals);
      await tx.ensureAllowance(tokIn, CORE.swapRouter, raw);
      await tx.send(`Swap ${fmt(amt)} ${tokIn.symbol}`, {
        address: CORE.swapRouter,
        abi: routerAbi as Abi,
        functionName: "swapExactTokensForTokens",
        args: [raw, minOut, tokIn.address === pool.token0.address, pool.key, "0x", address, BigInt(Math.floor(Date.now() / 1000) + 600)],
        value: tokIn.native ? raw : 0n,
      });
      setAmount("");
    }, "Swapped");

  const label = !isConnected ? "Connect wallet" : !(amt > 0) ? "Enter an amount" : short ? `Not enough ${tokIn.symbol}` : quote.isFetching ? "Getting a price…" : !chosen ? "No route for this size" : "Swap";

  return (
    <div className="card flex flex-col gap-1 p-2">
      <TokenBox label="You pay" token={tokIn} value={amount} onChange={setAmount} balance={num(balIn, tokIn.decimals)} right={<TokenPill token={tokIn} onClick={() => setMenu("in")} />} />
      <div className="relative z-10 -my-3 flex justify-center">
        <button className="grid h-9 w-9 place-items-center rounded-[12px] border-4 border-white bg-[var(--line2)] hover:bg-[var(--line)]" onClick={flip}>
          <ArrowDown className="h-4 w-4" />
        </button>
      </div>
      <TokenBox label="You receive" token={tokOut} value={out ? trim(out) : ""} readOnly balance={num(balOut, tokOut.decimals)} right={<TokenPill token={tokOut} onClick={() => setMenu("out")} />} />
      {chosen && amt > 0 && (
        <div className="flex flex-col gap-1 px-3 py-2 text-[12px] text-[var(--muted)]">
          <div className="flex justify-between">
            <span>Rate</span>
            <span className="text-[var(--ink)]">
              1 {tokIn.symbol} = {fmt(out / amt)} {tokOut.symbol}
            </span>
          </div>
          <div className="flex items-center justify-between gap-2">
            <span>Route</span>
            {quote.data!.length > 1 ? (
              <select className="rounded border border-[var(--line)] bg-white px-1 py-0.5 text-right text-[12px] text-[var(--ink)]" value={chosen.pool.index} onChange={(e) => setRoute(Number(e.target.value))}>
                {quote.data!.map((x, i) => (
                  <option key={x.pool.index} value={x.pool.index}>
                    {x.pool.label}
                    {x.pool.hooked ? " · rules hook" : ""}
                    {i === 0 ? " · best price" : ""}
                  </option>
                ))}
              </select>
            ) : (
              <span>{chosen.pool.label}</span>
            )}
          </div>
          <div className="flex justify-between">
            <span>Minimum received (0.5% slippage)</span>
            <span>
              {fmt(Number(minOut) / 10 ** tokOut.decimals)} {tokOut.symbol}
            </span>
          </div>
        </div>
      )}
      <button className="btn btn-dark m-1 !rounded-[14px] !py-3.5 !text-[15px]" disabled={label !== "Swap" || tx.state.busy} onClick={swap}>
        {tx.state.busy ? tx.state.message : label}
      </button>
      {!tx.state.busy && (
        <div className="px-2 pb-1">
          <TxLine state={tx.state} />
        </div>
      )}
      {menu && (
        <Menu
          items={menu === "in" ? TOKENS : tradable(tokIn)}
          onClose={() => setMenu(null)}
          onPick={(t) => {
            if (menu === "in") {
              setTokIn(t);
              if (!poolsFor(t, tokOut).length) setTokOut(tradable(t)[0]);
            } else setTokOut(t);
            setMenu(null);
          }}
          render={(t) => (
            <>
              <TokenIcon symbol={t.symbol} size={28} />
              <span className="font-semibold">{t.symbol}</span>
              <span className="text-[12px] text-[var(--muted)]">{t.native ? "Sepolia ETH" : `Test ${t.symbol}`}</span>
            </>
          )}
        />
      )}
    </div>
  );
}

// ---------------------------------------------------------------- limit order

function LimitOrder() {
  const { isConnected } = useAccount();
  const hookPools = POOLS.filter((p) => p.hooked);
  const [poolIndex, setPoolIndex] = useState(hookPools[0].index);
  const pool = hookPools.find((p) => p.index === poolIndex)!;
  const [sellBase, setSellBase] = useState(true);
  const sell = sellBase ? pool.base : pool.quote;
  const get = sellBase ? pool.quote : pool.base;
  const [amount, setAmount] = useState("");
  const [priceText, setPriceText] = useState("");
  const [menu, setMenu] = useState(false);
  const bal = useTokenBalance(sell);
  const tx = useTx();

  const { data: state } = useReadContract({ address: CORE.conditionalOrders, abi: conditionalOrdersAbi, functionName: "poolState", args: [poolIndex] });
  const tick = state ? Number(state[1]) : undefined;
  // price of what you sell, in what you get
  const market = tick === undefined ? 0 : sellBase ? priceAtTick(pool, tick) : 1 / priceAtTick(pool, tick);
  const target = parseFloat(priceText) || 0;

  /** The bucket (one tick spacing wide) that sells at or above the target price. */
  const bucket = useMemo(() => {
    if (tick === undefined || !(target > 0)) return null;
    const s = pool.key.tickSpacing;
    const sellToken0 = sell.address === pool.token0.address;
    // price of token0 in token1 at the target (raw ticks rise with it)
    const p0in1 = sellToken0 ? target : 1 / target;
    const t = Math.log(p0in1 * 10 ** (pool.token1.decimals - pool.token0.decimals)) / Math.log(1.0001);
    // selling token0 fills as the tick rises through [tl, tl+s]: start at or above the target.
    // selling token1 fills as the tick falls: end at or below the target.
    const tl = sellToken0 ? Math.ceil(t / s) * s : Math.floor(t / s) * s - s;
    const valid = sellToken0 ? tick < tl : tick >= tl + s;
    const a = sellBase ? priceAtTick(pool, tl) : 1 / priceAtTick(pool, tl);
    const b = sellBase ? priceAtTick(pool, tl + s) : 1 / priceAtTick(pool, tl + s);
    return { tl, sellToken0, valid, lo: Math.min(a, b), hi: Math.max(a, b) };
  }, [tick, target, pool, sell, sellBase]);

  const amt = parseFloat(amount);
  const receive = bucket && amt > 0 ? amt * Math.sqrt(bucket.lo * bucket.hi) : 0;
  const short = bal !== undefined && amt > 0 && toRaw(amt, sell.decimals) > bal;

  const place = () =>
    tx.run(async () => {
      if (!bucket) return;
      const raw = toRaw(amt, sell.decimals);
      await tx.ensureAllowance(sell, CORE.ruleHook, raw);
      await tx.send(`Place limit order`, {
        address: CORE.ruleHook,
        abi: ruleHookAbi as Abi,
        functionName: "placeLimit",
        args: [pool.key, bucket.tl, bucket.sellToken0, raw],
        value: sell.native ? raw : 0n,
      });
      setAmount("");
    }, "Limit order placed. It fills when a swap moves the price through it.");

  const label = !isConnected
    ? "Connect wallet"
    : !(amt > 0)
      ? "Enter an amount"
      : !(target > 0)
        ? "Set a price"
        : bucket && !bucket.valid
          ? `Price must be above the market (${fmt(market)})`
          : short
            ? `Not enough ${sell.symbol}`
            : "Place limit order";

  return (
    <div className="card flex flex-col gap-2 p-2">
      <div className="rounded-[16px] bg-[var(--line2)] p-4">
        <div className="flex items-center justify-between text-[13px] text-[var(--muted)]">
          <span>
            When 1 {sym(sell.symbol)} is worth
          </span>
          <button className="text-[var(--ink)] hover:underline" onClick={() => setPriceText(trim(market))}>
            Market {fmt(market)}
          </button>
        </div>
        <div className="mt-1 flex items-center gap-2">
          <input className="min-w-0 flex-1 bg-transparent text-[30px] font-medium outline-none" placeholder={trim(market)} value={priceText} onChange={(e) => setPriceText(e.target.value)} />
          <TokenPill token={get} />
        </div>
        <div className="mt-2 flex gap-1.5">
          {[1, 2, 5, 10].map((d) => (
            <button key={d} className="chip" onClick={() => setPriceText(trim(market * (1 + d / 100)))}>
              +{d}%
            </button>
          ))}
        </div>
      </div>
      <TokenBox label="Sell" token={sell} value={amount} onChange={setAmount} balance={num(bal, sell.decimals)} right={<TokenPill token={sell} onClick={() => setMenu(true)} />} />
      <div className="relative z-10 -my-4 flex justify-center">
        <button className="grid h-9 w-9 place-items-center rounded-[12px] border-4 border-white bg-[var(--line2)] hover:bg-[var(--line)]" onClick={() => { setSellBase(!sellBase); setPriceText(""); }}>
          <ArrowDown className="h-4 w-4" />
        </button>
      </div>
      <TokenBox label="Receive (about)" token={get} value={receive ? trim(receive) : ""} readOnly right={<TokenPill token={get} />} />
      {bucket && bucket.valid && amt > 0 && (
        <div className="flex gap-2 px-3 py-1 text-[12px] text-[var(--muted)]">
          <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          <span>
            Sells as the price moves from {fmt(bucket.lo)} to {fmt(bucket.hi)} {get.symbol} (one tick spacing), plus pool fees while it is crossed. It fills
            when a swap moves the price all the way through; then claim it below. You can cancel any time before.
          </span>
        </div>
      )}
      <button className="btn btn-dark m-1 !rounded-[14px] !py-3.5 !text-[15px]" disabled={label !== "Place limit order" || tx.state.busy} onClick={place}>
        {tx.state.busy ? tx.state.message : label}
      </button>
      {!tx.state.busy && (
        <div className="px-2 pb-1">
          <TxLine state={tx.state} />
        </div>
      )}
      {menu && (
        <Menu
          items={hookPools.flatMap((p) => [
            { p, base: true },
            { p, base: false },
          ])}
          onClose={() => setMenu(false)}
          onPick={(x) => {
            setPoolIndex(x.p.index);
            setSellBase(x.base);
            setPriceText("");
            setMenu(false);
          }}
          render={(x) => {
            const s = x.base ? x.p.base : x.p.quote;
            const g = x.base ? x.p.quote : x.p.base;
            return (
              <>
                <TokenIcon symbol={s.symbol} size={26} />
                <span className="font-semibold">
                  Sell {s.symbol} for {g.symbol}
                </span>
                <span className="ml-auto text-[11px] text-[var(--muted)]">{x.p.key.fee / 10_000}%</span>
              </>
            );
          }}
        />
      )}
    </div>
  );
}

// ---------------------------------------------------------------- your limit orders

function MyLimitOrders() {
  const { address } = useAccount();
  const client = usePublicClient();
  const tx = useTx();
  const q = useQuery({
    queryKey: ["limits", address],
    enabled: !!address && !!client,
    queryFn: async () => {
      const logs = await client!.getLogs({
        address: CORE.ruleHook,
        event: ruleHookAbi.find((x) => x.type === "event" && x.name === "LimitPlaced")! as never,
        args: { owner: address } as never,
        fromBlock: BigInt(CORE.deployBlock),
        toBlock: "latest",
      });
      const byEpoch = new Map<bigint, bigint>();
      for (const l of logs as unknown as { args: { epochId: bigint; paid: bigint } }[]) byEpoch.set(l.args.epochId, (byEpoch.get(l.args.epochId) ?? 0n) + l.args.paid);
      const rows = [];
      for (const [epoch, paid] of byEpoch) {
        const [liq] = (await client!.readContract({ address: CORE.ruleHook, abi: ruleHookAbi, functionName: "shares", args: [epoch, address!] })) as readonly [bigint, bigint, bigint];
        if (liq === 0n) continue; // claimed or cancelled
        const e = (await client!.readContract({ address: CORE.ruleHook, abi: ruleHookAbi, functionName: "epochs", args: [epoch] })) as readonly unknown[];
        const poolIndex = Number(e[3]);
        const tl = Number(e[4]);
        const sellToken0 = e[5] as boolean;
        const filled = e[6] as boolean;
        const pool = POOLS.find((p) => p.index === poolIndex)!;
        let claim: readonly [bigint, bigint] = [0n, 0n];
        if (filled) claim = (await client!.readContract({ address: CORE.ruleHook, abi: ruleHookAbi, functionName: "claimable", args: [epoch, address!] })) as readonly [bigint, bigint];
        rows.push({ epoch, paid, pool, tl, sellToken0, filled, claim });
      }
      return rows;
    },
  });

  const act = (fn: "cancelLimit" | "claimLimit", epoch: bigint) =>
    tx.run(async () => {
      await tx.send(fn === "claimLimit" ? "Claim" : "Cancel order", { address: CORE.ruleHook, abi: ruleHookAbi as Abi, functionName: fn, args: [epoch, address] });
      q.refetch();
    }, fn === "claimLimit" ? "Claimed to your wallet" : "Order cancelled, tokens returned");

  if (!address) return null;
  return (
    <div className="flex flex-col gap-2">
      <div className="px-1 text-[15px] font-semibold">Your limit orders</div>
      <TxLine state={tx.state} />
      {q.isLoading && <div className="card p-4 text-center text-[13px] text-[var(--muted)]">Loading…</div>}
      {q.data && q.data.length === 0 && <div className="card p-4 text-center text-[13px] text-[var(--muted)]">No open limit orders.</div>}
      {q.data?.map((r) => {
        const sold = r.sellToken0 ? r.pool.token0 : r.pool.token1;
        const got = r.sellToken0 ? r.pool.token1 : r.pool.token0;
        const soldIsBase = sold.address === r.pool.base.address;
        const p = (t: number) => (soldIsBase ? priceAtTick(r.pool, t) : 1 / priceAtTick(r.pool, t));
        const a = p(r.tl);
        const b = p(r.tl + r.pool.key.tickSpacing);
        return (
          <div key={String(r.epoch)} className="card flex items-center gap-3 p-3 text-[13px]">
            <TokenIcon symbol={sold.symbol} size={26} />
            <div className="flex-1">
              <div className="font-semibold">
                Sell {fmt(Number(r.paid) / 10 ** sold.decimals)} {sold.symbol} → {got.symbol}
              </div>
              <div className="text-[12px] text-[var(--muted)]">
                at {fmt(Math.min(a, b))}–{fmt(Math.max(a, b))} {got.symbol} · {r.pool.label}
              </div>
            </div>
            {r.filled ? (
              <button className="btn btn-dark" disabled={tx.state.busy} onClick={() => act("claimLimit", r.epoch)}>
                Claim {fmt(Number(r.sellToken0 ? r.claim[1] : r.claim[0]) / 10 ** got.decimals)} {got.symbol}
              </button>
            ) : (
              <>
                <span className="rounded-full bg-[var(--line2)] px-2 py-0.5 text-[11px] font-semibold">Open</span>
                <button className="btn btn-light" disabled={tx.state.busy} onClick={() => act("cancelLimit", r.epoch)}>
                  Cancel
                </button>
              </>
            )}
          </div>
        );
      })}
    </div>
  );
}

const num = (raw: bigint | undefined, decimals: number) => (raw === undefined ? undefined : Number(raw) / 10 ** decimals);
function trim(n: number) {
  if (!isFinite(n) || n === 0) return "";
  return n >= 1 ? String(Number(n.toPrecision(7))) : String(Number(n.toPrecision(5)));
}
