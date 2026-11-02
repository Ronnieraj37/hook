"use client";

import { ChevronDown, Pencil, Sparkles } from "lucide-react";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useState } from "react";
import { type Abi, encodeAbiParameters, encodePacked } from "viem";
import { useAccount, usePublicClient, useReadContract } from "wagmi";
import RuleEditor from "@/components/RuleEditor";
import { Menu, PoolIcons, TokenBox, Toggle, TxLine } from "@/components/ui";
import { ACTIONS, permit2Abi, positionManagerAbi } from "@/lib/abis-extra";
import { conditionalOrdersAbi } from "@/lib/generated/abis";
import {
  CORE,
  POOLS,
  type Pool,
  amountsFor,
  floorTo,
  fmt,
  liquidityFor,
  maxUsable,
  minUsable,
  poolByIndex,
  priceAtTick,
  priceRange,
  rangeAround,
  sqrtFromX96,
  tickAtPrice,
} from "@/lib/pools";
import { type Advanced, type LaneId, type Rules, DEFAULT_ADVANCED, describeLane, emptyRules, encodeRules, laneTitle } from "@/lib/rules";
import { useTokenBalance, useTx } from "@/lib/tx";

type Preset = "2" | "5" | "15" | "full";

export default function AddLiquidity() {
  const router = useRouter();
  const { address, isConnected } = useAccount();
  const client = usePublicClient();
  const [poolIndex, setPoolIndex] = useState(POOLS.find((p) => p.hooked)!.index);
  const pool = poolByIndex(poolIndex)!;
  const [poolMenu, setPoolMenu] = useState(false);

  const { data: state } = useReadContract({ address: CORE.conditionalOrders, abi: conditionalOrdersAbi, functionName: "poolState", args: [poolIndex] });
  const tick = state ? Number(state[1]) : undefined;
  const sp = state ? sqrtFromX96(state[0]) : undefined;
  const price = tick !== undefined ? priceAtTick(pool, tick) : 0;

  // ---------------- range
  const [preset, setPreset] = useState<Preset | null>("5");
  const [ticks, setTicks] = useState<[number, number] | null>(null);
  useEffect(() => {
    if (tick !== undefined && preset) setTicks(rangeAround(pool, tick, preset === "full" ? "full" : Number(preset)));
  }, [tick === undefined, preset, poolIndex]); // eslint-disable-line react-hooks/exhaustive-deps
  const [tl, tu] = ticks ?? [0, 0];
  const full = !!ticks && tl === minUsable(pool.key.tickSpacing) && tu === maxUsable(pool.key.tickSpacing);
  const [lo, hi] = ticks ? priceRange(pool, tl, tu) : [0, 0];

  const setPrice = (which: "lo" | "hi", text: string) => {
    const v = parseFloat(text);
    if (!(v > 0) || !ticks) return;
    const s = pool.key.tickSpacing;
    const t = tickAtPrice(pool, v);
    const other = tickAtPrice(pool, which === "lo" ? hi : lo);
    const a = Math.max(minUsable(s), floorTo(Math.min(t, other), s));
    const b = Math.min(maxUsable(s), floorTo(Math.max(t, other), s) + s);
    if (b > a) {
      setTicks([a, b]);
      setPreset(null);
    }
  };

  // ---------------- amounts (type either one)
  const [typed, setTyped] = useState<{ side: "base" | "quote"; text: string }>({ side: "base", text: "" });
  const calc = useMemo(() => {
    if (sp === undefined || !ticks) return null;
    const v = parseFloat(typed.text);
    if (!(v > 0)) return null;
    const tok = typed.side === "base" ? pool.base : pool.quote;
    const L = liquidityFor(sp, tl, tu, v * 10 ** tok.decimals, tok.address === pool.token0.address);
    if (!isFinite(L)) return null;
    const [a0, a1] = amountsFor(sp, tl, tu, L);
    return { L, a0, a1 };
  }, [sp, ticks, typed, pool, tl, tu]);
  const human = (raw: number, decimals: number) => raw / 10 ** decimals;
  const baseRaw = calc ? (pool.base.address === pool.token0.address ? calc.a0 : calc.a1) : 0;
  const quoteRaw = calc ? (pool.quote.address === pool.token0.address ? calc.a0 : calc.a1) : 0;
  const baseText = typed.side === "base" ? typed.text : calc ? trim(human(baseRaw, pool.base.decimals)) : "";
  const quoteText = typed.side === "quote" ? typed.text : calc ? trim(human(quoteRaw, pool.quote.decimals)) : "";
  // a range fully above/below the price only takes one token
  const needsBase = sp === undefined || !ticks || isFinite(liquidityFor(sp, tl, tu, 1, pool.base.address === pool.token0.address));
  const needsQuote = sp === undefined || !ticks || isFinite(liquidityFor(sp, tl, tu, 1, pool.quote.address === pool.token0.address));
  useEffect(() => {
    if (!needsBase && typed.side === "base") setTyped({ side: "quote", text: "" });
    if (!needsQuote && typed.side === "quote") setTyped({ side: "base", text: "" });
  }, [needsBase, needsQuote]); // eslint-disable-line react-hooks/exhaustive-deps

  const balBase = useTokenBalance(pool.base);
  const balQuote = useTokenBalance(pool.quote);
  const short =
    calc &&
    ((balBase !== undefined && BigInt(Math.ceil(baseRaw)) > balBase) || (balQuote !== undefined && BigInt(Math.ceil(quoteRaw)) > balQuote));

  // ---------------- rules (optional)
  const [rulesOn, setRulesOn] = useState(false);
  const [rules, setRules] = useState<Rules>(emptyRules());
  const [advanced, setAdvanced] = useState<Advanced>(DEFAULT_ADVANCED);
  const [editor, setEditor] = useState(false);
  const hasRules = !!rules.down.trigger || !!rules.up.trigger;
  useEffect(() => {
    setRules(emptyRules());
  }, [poolIndex]);

  // ---------------- submit
  const tx = useTx();
  const rangeLabel = full ? "Full range" : `${fmt(lo)} – ${fmt(hi)} ${pool.quote.symbol}`;
  const amountsLabel = calc ? `${fmt(human(baseRaw, pool.base.decimals))} ${pool.base.symbol} + ${fmt(human(quoteRaw, pool.quote.decimals))} ${pool.quote.symbol}` : "";

  const submit = () =>
    tx.run(async () => {
      if (!calc || !address) return;
      const max0 = BigInt(Math.ceil(calc.a0 * 1.02)) + 1n;
      const max1 = BigInt(Math.ceil(calc.a1 * 1.02)) + 1n;
      const liquidity = BigInt(Math.floor(calc.L * 0.9999));
      const value = pool.token0.native ? max0 : 0n;
      if (rulesOn && hasRules) {
        const enc = encodeRules(pool, rules);
        await tx.ensureAllowance(pool.token0, CORE.conditionalOrders, max0);
        await tx.ensureAllowance(pool.token1, CORE.conditionalOrders, max1);
        await tx.send("Add liquidity with rules", {
          address: CORE.conditionalOrders,
          abi: conditionalOrdersAbi as Abi,
          functionName: "createOrder",
          args: [
            {
              key: pool.key,
              tickLower: tl,
              tickUpper: tu,
              liquidity,
              amount0Max: max0,
              amount1Max: max1,
              swapPoolIndex: 0,
              expiry: Math.floor(Date.now() / 1000) + advanced.expiryDays * 86400,
              maxKeeperFeeBps: advanced.keeperFeeBps,
              maxSlippage: Math.max(1, Math.round(advanced.slippagePct * 10)),
              lower: enc.lower,
              upper: enc.upper,
            },
          ],
          value,
        });
      } else {
        // A normal Uniswap v4 position (an NFT in your wallet), through the PositionManager and Permit2.
        for (const [tok, amt] of [
          [pool.token0, max0],
          [pool.token1, max1],
        ] as const) {
          if (tok.native) continue;
          await tx.ensureAllowance(tok, CORE.permit2, amt);
          const [allowed, expiration] = await client!.readContract({ address: CORE.permit2, abi: permit2Abi, functionName: "allowance", args: [address, tok.address, CORE.positionManager] });
          if (allowed < amt || expiration < Date.now() / 1000 + 600) {
            await tx.send(`Allow Uniswap to use t${tok.symbol}`, {
              address: CORE.permit2,
              abi: permit2Abi as Abi,
              functionName: "approve",
              args: [tok.address, CORE.positionManager, (1n << 160n) - 1n, 2 ** 47],
            });
          }
        }
        const actions = encodePacked(["uint8", "uint8", "uint8"], [ACTIONS.MINT_POSITION, ACTIONS.SETTLE_PAIR, ACTIONS.SWEEP]);
        const keyType = { type: "tuple", components: [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }] } as const;
        const k = [pool.key.currency0, pool.key.currency1, pool.key.fee, pool.key.tickSpacing, pool.key.hooks] as const;
        const params = [
          encodeAbiParameters(
            [keyType, { type: "int24" }, { type: "int24" }, { type: "uint256" }, { type: "uint128" }, { type: "uint128" }, { type: "address" }, { type: "bytes" }],
            [k, tl, tu, liquidity, max0, max1, address, "0x"],
          ),
          encodeAbiParameters([{ type: "address" }, { type: "address" }], [pool.key.currency0, pool.key.currency1]),
          encodeAbiParameters([{ type: "address" }, { type: "address" }], [pool.key.currency0, address]),
        ];
        await tx.send("Add liquidity", {
          address: CORE.positionManager,
          abi: positionManagerAbi as Abi,
          functionName: "modifyLiquidities",
          args: [encodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], [actions, params]), BigInt(Math.floor(Date.now() / 1000) + 600)],
          value,
        });
      }
      router.push("/pool");
    }, "Position added");

  const buttonText = !isConnected
    ? "Connect wallet"
    : !calc
      ? "Enter an amount"
      : short
        ? "Not enough balance"
        : rulesOn && !hasRules
          ? "Add a rule, or turn rules off"
          : rulesOn
            ? "Add liquidity with rules"
            : "Add liquidity";

  return (
    <div className="mx-auto flex max-w-[520px] flex-col gap-3 px-4 py-8">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-semibold">New position</h1>
        <button className="text-[13px] text-[var(--muted)] hover:text-[var(--ink)]" onClick={() => router.push("/pool")}>
          Cancel
        </button>
      </div>

      <div className="card flex flex-col gap-5 p-5">
        {/* pool */}
        <div>
          <div className="label mb-2">Pair</div>
          <button className="flex w-full items-center gap-3 rounded-[12px] border border-[var(--line)] px-3 py-2.5 hover:border-[var(--ink)]" onClick={() => setPoolMenu(true)}>
            <PoolIcons pool={pool} />
            <span className="font-semibold">
              {pool.base.symbol} / {pool.quote.symbol}
            </span>
            <span className="rounded bg-[var(--line2)] px-1.5 py-0.5 text-[11px] font-semibold">{pool.key.fee / 10_000}%</span>
            {!pool.hooked && <span className="text-[11px] text-[var(--muted)]">no rules hook</span>}
            <ChevronDown className="ml-auto h-4 w-4 text-[var(--muted)]" />
          </button>
          <div className="mt-1.5 text-[12px] text-[var(--muted)]">
            Current price: <b className="text-[var(--ink)]">{fmt(price)} {pool.quote.symbol}</b> per {pool.base.symbol}
          </div>
        </div>

        {/* range */}
        <div>
          <div className="mb-2 flex items-center justify-between">
            <div className="label">Price range</div>
            <div className="flex gap-1">
              {(
                [
                  ["2", "±2%"],
                  ["5", "±5%"],
                  ["15", "±15%"],
                  ["full", "Full"],
                ] as [Preset, string][]
              ).map(([id, label]) => (
                <button key={id} className="chip" data-on={preset === id} onClick={() => setPreset(id)}>
                  {label}
                </button>
              ))}
            </div>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <PriceBox label="Low price" value={full ? "0" : lo} quote={pool.quote.symbol} base={pool.base.symbol} onCommit={(t) => setPrice("lo", t)} />
            <PriceBox label="High price" value={full ? "∞" : hi} quote={pool.quote.symbol} base={pool.base.symbol} onCommit={(t) => setPrice("hi", t)} />
          </div>
        </div>

        {/* amounts */}
        <div className="flex flex-col gap-1.5">
          <div className="label mb-0.5">Deposit</div>
          {needsBase ? (
            <TokenBox label={pool.base.symbol} token={pool.base} value={baseText} onChange={(t) => setTyped({ side: "base", text: t })} balance={num(balBase, pool.base.decimals)} />
          ) : (
            <NotNeeded symbol={pool.base.symbol} />
          )}
          {needsQuote ? (
            <TokenBox label={pool.quote.symbol} token={pool.quote} value={quoteText} onChange={(t) => setTyped({ side: "quote", text: t })} balance={num(balQuote, pool.quote.decimals)} />
          ) : (
            <NotNeeded symbol={pool.quote.symbol} />
          )}
        </div>

        {/* optional rules */}
        <div className={`rounded-[12px] border p-3 ${rulesOn ? "border-[var(--ink)]" : "border-[var(--line)]"}`}>
          <div className="flex items-center gap-3">
            <Sparkles className="h-4 w-4 shrink-0" />
            <div className="flex-1">
              <div className="text-[14px] font-semibold">Automate with rules</div>
              <div className="text-[12px] text-[var(--muted)]">Optional. Take profit, stop loss, follow the price, compound…</div>
            </div>
            <Toggle
              value={rulesOn}
              onChange={(on) => {
                setRulesOn(on);
                if (on && !hasRules) setEditor(true);
              }}
            />
          </div>
          {!pool.hooked && rulesOn && <div className="mt-2 text-[12px] text-[var(--amber)]">Rules need a pool that uses the rules hook. Pick another fee tier.</div>}
          {rulesOn && pool.hooked && (
            <div className="mt-3 flex flex-col gap-1.5 border-t border-[var(--line)] pt-3">
              {hasRules ? (
                (["down", "up"] as LaneId[]).map((lane) => {
                  const text = describeLane(pool, lane, rules[lane]);
                  return text ? (
                    <div key={lane} className="text-[12px]">
                      <span className={`font-semibold ${lane === "up" ? "text-[var(--sage)]" : "text-[var(--rose)]"}`}>{laneTitle(pool, lane, rules[lane])}: </span>
                      {text}
                    </div>
                  ) : null;
                })
              ) : (
                <div className="text-[12px] text-[var(--muted)]">No rules yet.</div>
              )}
              <button className="btn btn-light mt-1 self-start" onClick={() => setEditor(true)}>
                <Pencil className="h-3.5 w-3.5" /> {hasRules ? "Edit rules" : "Open rule editor"}
              </button>
            </div>
          )}
        </div>

        <button
          className="btn btn-dark w-full !rounded-[14px] !py-3.5 !text-[15px]"
          disabled={!isConnected || !calc || !!short || tx.state.busy || (rulesOn && (!hasRules || !pool.hooked))}
          onClick={submit}
        >
          {tx.state.busy ? tx.state.message : buttonText}
        </button>
        {!tx.state.busy && <TxLine state={tx.state} />}
      </div>

      {poolMenu && (
        <Menu
          items={POOLS}
          onClose={() => setPoolMenu(false)}
          onPick={(p) => {
            setPoolIndex(p.index);
            setPreset("5");
            setTyped({ side: "base", text: "" });
            setPoolMenu(false);
          }}
          render={(p) => (
            <>
              <PoolIcons pool={p} />
              <span className="font-semibold">
                {p.base.symbol} / {p.quote.symbol}
              </span>
              <span className="rounded bg-[var(--line2)] px-1.5 py-0.5 text-[11px] font-semibold">{p.key.fee / 10_000}%</span>
              {!p.hooked && <span className="ml-auto text-[11px] text-[var(--muted)]">no rules</span>}
            </>
          )}
        />
      )}

      {editor && (
        <RuleEditor
          pool={pool}
          price={price}
          rangeLabel={rangeLabel}
          amountsLabel={amountsLabel}
          initialRules={rules}
          initialAdvanced={advanced}
          saveLabel="Use these rules"
          range={full ? { full: true } : { loPct: (lo / price - 1) * 100, hiPct: (hi / price - 1) * 100 }}
          onClose={() => {
            setEditor(false);
            if (!hasRules) setRulesOn(false);
          }}
          onSave={(r, a) => {
            setRules(r);
            setAdvanced(a);
            setRulesOn(true);
            setEditor(false);
          }}
        />
      )}
    </div>
  );
}

function PriceBox({ label, value, quote, base, onCommit }: { label: string; value: number | string; quote: string; base: string; onCommit: (t: string) => void }) {
  const shown = typeof value === "number" ? (value >= 1000 ? value.toFixed(2) : String(Number(value.toPrecision(6)))) : value;
  const [text, setText] = useState(shown);
  useEffect(() => setText(shown), [shown]);
  return (
    <div className="rounded-[12px] bg-[var(--line2)] p-3 text-center">
      <div className="text-[12px] text-[var(--muted)]">{label}</div>
      <input
        className="w-full bg-transparent text-center text-[20px] font-semibold outline-none"
        value={text}
        onChange={(e) => setText(e.target.value)}
        onBlur={() => onCommit(text)}
        onKeyDown={(e) => e.key === "Enter" && onCommit(text)}
      />
      <div className="text-[11px] text-[var(--muted)]">
        {quote} per {base}
      </div>
    </div>
  );
}

function NotNeeded({ symbol }: { symbol: string }) {
  return <div className="rounded-[16px] bg-[var(--line2)] p-4 text-[13px] text-[var(--muted)]">No {symbol} needed: the whole range is on one side of the current price.</div>;
}

const num = (raw: bigint | undefined, decimals: number) => (raw === undefined ? undefined : Number(raw) / 10 ** decimals);
function trim(n: number) {
  if (!isFinite(n)) return "";
  if (n === 0) return "0";
  return n >= 1 ? String(Number(n.toPrecision(8))) : String(Number(n.toPrecision(6)));
}
