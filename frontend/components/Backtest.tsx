"use client";

import { useQuery } from "@tanstack/react-query";
import { ArrowLeft, Info, Loader2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { usePublicClient } from "wagmi";
import { conditionalOrdersAbi } from "@/lib/generated/abis";
import { CORE, type Pool, fmt, poolByIndex, priceAtTick } from "@/lib/pools";
import { type Advanced, type LaneId, type Rules, describeLane, laneTitle } from "@/lib/rules";

// Series colors: validated with the dataviz palette checker (contrast, chroma, color-blind separation).
const C_RULES = "#0a9a8b";
const C_PLAIN = "#6d5bd0";
const C_HOLD = "#b5651d";

export type BacktestRange = { loPct: number; hiPct: number } | { full: true };

type Single = {
  poolLabel: string;
  start: number;
  end: number;
  dataFrom: number;
  dataTo: number;
  swaps: number;
  entryPrice: number;
  endPrice: number;
  deposit: number;
  range: { lo: number; hi: number; full: boolean };
  rules: { final: number; fees: number; keeperPaid: number; runs: number; timeInRange: number; closed: boolean };
  noRules: { final: number; fees: number; timeInRange: number };
  hold: { final: number };
  series: { t: number[]; price: number[]; rules: number[]; noRules: number[]; hold: number[]; lo: (number | null)[]; hi: (number | null)[] };
  events: { t: number; price: number; side: string; note: string[] }[];
  caveats: string[];
};
type Windows = {
  windows: { start: number; rules: number; noRules: number; hold: number; runs: number }[];
  count: number;
  beatNoRules: number;
  beatHold: number;
  medianVsNoRules: number;
  worstVsNoRules: number;
  bestVsNoRules: number;
  windowDays: number;
};

const HISTORY = [
  { key: "eth_usdc_030", label: "ETH/USDC 0.30%", hint: "96k swaps" },
  { key: "eth_usdc_005", label: "ETH/USDC 0.05%", hint: "1M swaps" },
];
const CHAINS = [
  { id: "unichain", label: "Unichain", cost: 0.01, hint: "~$0.01 a run" },
  { id: "ethereum", label: "Ethereum", cost: 1, hint: "~$1 a run" },
];
// recorded window: 2026-04-05 to 2026-10-03 (lp_study)
const DATA_START = 1775347200;

function encode(req: object) {
  const json = JSON.stringify(req);
  return btoa(json).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export default function Backtest({
  pool,
  price,
  range,
  rules,
  advanced,
  onClose,
}: {
  pool: Pool;
  price: number;
  range: BacktestRange;
  rules: Rules;
  advanced: Advanced;
  onClose: () => void;
}) {
  const client = usePublicClient();
  const [history, setHistory] = useState(pool.key.fee <= 500 ? "eth_usdc_005" : "eth_usdc_030");
  const [days, setDays] = useState(90);
  const [startMonth, setStartMonth] = useState(0); // months after the data start
  const [allWindows, setAllWindows] = useState(false);
  const [deposit, setDeposit] = useState(10_000);
  const [chain, setChain] = useState(CHAINS[0]);

  const ethLike = pool.base.symbol === "WETH" || pool.base.symbol === "ETH";

  const q = useQuery({
    queryKey: ["backtest", history, days, startMonth, allWindows, deposit, chain.id, JSON.stringify(rules), JSON.stringify(range), JSON.stringify(advanced)],
    staleTime: Infinity,
    queryFn: async () => {
      // Price triggers are sent relative to today's price of the pool they watch, so they apply to a past window.
      const lanes: Record<string, unknown> = {};
      for (const id of ["down", "up"] as LaneId[]) {
        const L = rules[id];
        if (!L.trigger || !L.actions.length) continue;
        const t = { ...L.trigger } as Record<string, unknown>;
        if (L.trigger.kind === "price" || L.trigger.kind === "otherPool") {
          let ref = price;
          if (L.trigger.kind === "otherPool" && L.trigger.poolIndex && client) {
            const w = poolByIndex(L.trigger.poolIndex);
            if (w) {
              const [, tick] = await client.readContract({ address: CORE.conditionalOrders, abi: conditionalOrdersAbi, functionName: "poolState", args: [w.index] });
              ref = priceAtTick(w, Number(tick));
            }
          }
          t.pricePct = ((L.trigger.price ?? ref) / ref - 1) * 100;
          delete t.price;
        }
        lanes[id] = { ...L, trigger: t };
      }
      const req = {
        pool: history,
        days,
        start: DATA_START + startMonth * 30 * 86400,
        depositUsd: deposit,
        range,
        rules: lanes,
        keeperFeeBps: advanced.keeperFeeBps,
        slippagePct: advanced.slippagePct,
        delaySec: 12,
        keeperCostUsd: chain.cost,
        keeperMode: "gas",
        ...(allWindows ? { mode: "windows", windowDays: 30, everyDays: 7 } : {}),
      };
      const res = await fetch(`/api/backtest?q=${encode(req)}`);
      const body = await res.json();
      if (!res.ok) throw new Error(body.error ?? `backtest failed (${res.status})`);
      return body as Single | Windows;
    },
  });

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-[var(--paper)]">
      <div className="flex h-14 shrink-0 items-center gap-3 border-b border-[var(--line)] bg-white px-4">
        <button className="btn btn-light !px-2.5" onClick={onClose}>
          <ArrowLeft className="h-4 w-4" /> Back to rules
        </button>
        <div className="min-w-0">
          <div className="truncate text-sm font-semibold">Backtest on real swap history</div>
          <div className="text-[11px] text-[var(--muted)]">Every recorded swap is replayed against your position and its rules, the way the contract would run them.</div>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto">
        <div className="mx-auto flex max-w-[1100px] flex-col gap-4 p-4">
          {/* settings: one row */}
          <div className="card flex flex-wrap items-end gap-4 p-3">
            <Control label="History">
              <Seg value={history} onChange={setHistory} items={HISTORY.map((h) => ({ id: h.key, label: h.label, title: h.hint }))} />
            </Control>
            <Control label="Period">
              <Seg
                value={allWindows ? "all" : String(days)}
                onChange={(v) => {
                  if (v === "all") setAllWindows(true);
                  else {
                    setAllWindows(false);
                    setDays(Number(v));
                    if (Number(v) === 180) setStartMonth(0);
                  }
                }}
                items={[
                  { id: "30", label: "30 days" },
                  { id: "90", label: "90 days" },
                  { id: "180", label: "180 days" },
                  { id: "all", label: "Every 30-day window" },
                ]}
              />
            </Control>
            {!allWindows && days < 180 && (
              <Control label="Starting">
                <select className="input !w-auto !py-1.5 text-[13px]" value={startMonth} onChange={(e) => setStartMonth(Number(e.target.value))}>
                  {Array.from({ length: days === 90 ? 4 : 6 }, (_, m) => (
                    <option key={m} value={m}>
                      {new Date((DATA_START + m * 30 * 86400) * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}
                    </option>
                  ))}
                </select>
              </Control>
            )}
            <Control label="Deposit">
              <div className="relative">
                <span className="absolute left-2.5 top-1.5 text-[13px] text-[var(--muted)]">$</span>
                <input
                  className="input !w-[110px] !py-1.5 !pl-5 text-[13px]"
                  inputMode="numeric"
                  value={deposit}
                  onChange={(e) => setDeposit(Math.max(100, Number(e.target.value.replace(/\D/g, "")) || 0))}
                />
              </div>
            </Control>
            <Control label="Gas per run">
              <Seg value={chain.id} onChange={(v) => setChain(CHAINS.find((c) => c.id === v)!)} items={CHAINS.map((c) => ({ id: c.id, label: c.label, title: c.hint }))} />
            </Control>
          </div>

          {!ethLike && (
            <div className="flex gap-2 rounded-[10px] bg-[var(--amber-lt)] p-3 text-[12px] text-[var(--amber)]">
              <Info className="mt-0.5 h-4 w-4 shrink-0" />
              Your pool is {pool.base.symbol}/{pool.quote.symbol}; the recorded history is ETH/USDC. This shows how your rules behave on ETH’s real price path, with
              your range and triggers scaled to it.
            </div>
          )}

          <RulesSummary pool={pool} rules={rules} />

          {q.isLoading && (
            <div className="card flex items-center justify-center gap-2 p-16 text-[13px] text-[var(--muted)]">
              <Loader2 className="h-4 w-4 animate-spin" /> Replaying swaps…
            </div>
          )}
          {q.error && <div className="card p-4 text-[13px] text-[var(--rose)]">{(q.error as Error).message}</div>}
          {q.data && "windows" in q.data && <WindowsResult r={q.data} />}
          {q.data && "series" in q.data && <SingleResult r={q.data} />}
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- pieces

function Control({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="label mb-1">{label}</div>
      {children}
    </div>
  );
}

function Seg({ value, onChange, items }: { value: string; onChange: (v: string) => void; items: { id: string; label: string; title?: string }[] }) {
  return (
    <div className="flex rounded-[10px] bg-[var(--line2)] p-0.5">
      {items.map((it) => (
        <button
          key={it.id}
          title={it.title}
          onClick={() => onChange(it.id)}
          className={`rounded-[8px] px-2.5 py-1 text-[12px] font-medium ${value === it.id ? "bg-white text-[var(--ink)] shadow-sm" : "text-[var(--muted)] hover:text-[var(--ink)]"}`}
        >
          {it.label}
        </button>
      ))}
    </div>
  );
}

function RulesSummary({ pool, rules }: { pool: Pool; rules: Rules }) {
  return (
    <div className="flex flex-wrap gap-x-6 gap-y-1 px-1 text-[12px] text-[var(--muted)]">
      {(["down", "up"] as LaneId[]).map((l) => {
        const t = describeLane(pool, l, rules[l]);
        return t ? (
          <div key={l}>
            <span className="font-semibold text-[var(--ink)]">{laneTitle(pool, l, rules[l])}: </span>
            {t}
          </div>
        ) : null;
      })}
    </div>
  );
}

const usd = (n: number) => `$${n.toLocaleString("en-US", { maximumFractionDigits: n >= 1000 ? 0 : 2 })}`;
const signed = (n: number) => `${n >= 0 ? "+" : "−"}${usd(Math.abs(n))}`;
const day = (t: number) => new Date(t * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" });

function Tile({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: "good" | "bad" }) {
  return (
    <div className="card p-3">
      <div className="text-[12px] text-[var(--muted)]">{label}</div>
      <div className="text-[22px] font-semibold tracking-tight">{value}</div>
      {sub && <div className={`text-[12px] ${tone === "good" ? "text-[var(--sage)]" : tone === "bad" ? "text-[var(--rose)]" : "text-[var(--muted)]"}`}>{sub}</div>}
    </div>
  );
}

function SingleResult({ r }: { r: Single }) {
  const diff = r.rules.final - r.noRules.final;
  return (
    <>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Tile label="With your rules" value={usd(r.rules.final)} sub={`${signed(diff)} vs no rules`} tone={diff >= 0 ? "good" : "bad"} />
        <Tile label="Same position, no rules" value={usd(r.noRules.final)} sub={`fees earned ${usd(r.noRules.fees)}`} />
        <Tile label="Just holding the tokens" value={usd(r.hold.final)} sub={`${signed(r.rules.final - r.hold.final)} for your rules`} tone={r.rules.final >= r.hold.final ? "good" : "bad"} />
        <Tile
          label="Rules ran"
          value={`${r.rules.runs}×`}
          sub={`fees ${usd(r.rules.fees)} · keepers ${usd(r.rules.keeperPaid)}${r.rules.closed ? " · closed" : ""}`}
        />
      </div>

      <div className="card p-4">
        <div className="mb-1 flex flex-wrap items-baseline justify-between gap-2">
          <div className="text-[14px] font-semibold">Position value</div>
          <div className="text-[12px] text-[var(--muted)]">
            {day(r.start)} – {day(r.end)} · {r.swaps.toLocaleString()} swaps · {r.poolLabel}
          </div>
        </div>
        <Legend />
        <LineChart
          t={r.series.t}
          series={[
            { name: "With rules", color: C_RULES, values: r.series.rules },
            { name: "No rules", color: C_PLAIN, values: r.series.noRules },
            { name: "Hold", color: C_HOLD, values: r.series.hold, dashed: true },
          ]}
          markers={r.events.map((e) => e.t)}
          format={usd}
          height={260}
        />
      </div>

      <div className="card p-4">
        <div className="mb-1 flex items-baseline justify-between">
          <div className="text-[14px] font-semibold">ETH price (USDC) and your range</div>
          <div className="text-[12px] text-[var(--muted)]">
            {fmt(r.entryPrice)} → {fmt(r.endPrice)} USDC · in range {Math.round(r.rules.timeInRange * 100)}% of the time with rules, {Math.round(r.noRules.timeInRange * 100)}% without
          </div>
        </div>
        <LineChart
          t={r.series.t}
          series={[{ name: "ETH price", color: "#0b1f2a", values: r.series.price }]}
          band={{ lo: r.series.lo, hi: r.series.hi }}
          markers={r.events.map((e) => e.t)}
          format={(n) => fmt(n)}
          height={170}
        />
      </div>

      {r.events.length > 0 && (
        <div className="card p-4">
          <div className="mb-2 text-[14px] font-semibold">When your rules ran</div>
          <div className="max-h-[260px] overflow-y-auto text-[12px]">
            <table className="w-full">
              <thead className="text-left text-[var(--muted)]">
                <tr>
                  <th className="py-1 font-medium">Time</th>
                  <th className="py-1 font-medium">ETH price</th>
                  <th className="py-1 font-medium">What happened</th>
                </tr>
              </thead>
              <tbody>
                {r.events.map((e, i) => (
                  <tr key={i} className="border-t border-[var(--line2)]">
                    <td className="py-1.5">{new Date(e.t * 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</td>
                    <td className="py-1.5">{fmt(e.price)}</td>
                    <td className="py-1.5 text-[var(--muted)]">{e.note.length ? e.note.join(", ") : "ran"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      <Caveats items={r.caveats} />
    </>
  );
}

function WindowsResult({ r }: { r: Windows }) {
  const rows = r.windows;
  return (
    <>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Tile label={`Windows of ${r.windowDays} days`} value={String(r.count)} sub="one starting every week" />
        <Tile label="Rules beat no rules" value={`${r.beatNoRules} of ${r.count}`} />
        <Tile label="Rules beat holding" value={`${r.beatHold} of ${r.count}`} />
        <Tile
          label="Median vs no rules"
          value={signed(r.medianVsNoRules)}
          sub={`worst ${signed(r.worstVsNoRules)} · best ${signed(r.bestVsNoRules)}`}
          tone={r.medianVsNoRules >= 0 ? "good" : "bad"}
        />
      </div>
      <div className="card p-4">
        <div className="mb-1 text-[14px] font-semibold">Final value by start date</div>
        <Legend />
        <LineChart
          t={rows.map((w) => w.start)}
          series={[
            { name: "With rules", color: C_RULES, values: rows.map((w) => w.rules) },
            { name: "No rules", color: C_PLAIN, values: rows.map((w) => w.noRules) },
            { name: "Hold", color: C_HOLD, values: rows.map((w) => w.hold), dashed: true },
          ]}
          format={usd}
          height={240}
          dots
        />
      </div>
      <Caveats items={["Each point is a separate backtest that starts on that date and runs for 30 days.", "Past results do not predict future ones."]} />
    </>
  );
}

function Legend() {
  return (
    <div className="mb-2 flex gap-4 text-[12px] text-[var(--muted)]">
      {[
        ["With rules", C_RULES, false],
        ["No rules", C_PLAIN, false],
        ["Just holding", C_HOLD, true],
      ].map(([n, c, d]) => (
        <span key={n as string} className="flex items-center gap-1.5">
          <svg width="18" height="6">
            <line x1="0" y1="3" x2="18" y2="3" stroke={c as string} strokeWidth="2" strokeDasharray={d ? "4 3" : undefined} />
          </svg>
          {n}
        </span>
      ))}
    </div>
  );
}

function Caveats({ items }: { items: string[] }) {
  return (
    <div className="flex flex-col gap-1 px-1 pb-6 text-[11px] text-[var(--muted)]">
      {items.map((c) => (
        <div key={c} className="flex gap-1.5">
          <Info className="mt-0.5 h-3 w-3 shrink-0" />
          {c}
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- chart (plain SVG, crosshair tooltip)

type S = { name: string; color: string; values: number[]; dashed?: boolean };

function LineChart({
  t,
  series,
  band,
  markers = [],
  format,
  height,
  dots,
}: {
  t: number[];
  series: S[];
  band?: { lo: (number | null)[]; hi: (number | null)[] };
  markers?: number[];
  format: (n: number) => string;
  height: number;
  dots?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [w, setW] = useState(800);
  const [hover, setHover] = useState<number | null>(null);
  useEffect(() => {
    if (!ref.current) return;
    const ro = new ResizeObserver((e) => setW(e[0].contentRect.width));
    ro.observe(ref.current);
    return () => ro.disconnect();
  }, []);

  const pad = { l: 64, r: 12, t: 8, b: 22 };
  const { x, y, yTicks, xTicks } = useMemo(() => {
    const all = series.flatMap((s) => s.values).concat(band ? (band.lo.concat(band.hi).filter((v) => v !== null) as number[]) : []);
    let lo = Math.min(...all);
    let hi = Math.max(...all);
    if (band) {
      // keep the price readable when the range is far wider than the price move (full range)
      const p = series[0].values;
      const pl = Math.min(...p);
      const ph = Math.max(...p);
      lo = Math.max(lo, pl - (ph - pl) * 0.6);
      hi = Math.min(hi, ph + (ph - pl) * 0.6);
    }
    const span = hi - lo || Math.abs(hi) * 0.01 || 1;
    lo -= span * 0.06;
    hi += span * 0.06;
    const t0 = t[0];
    const t1 = t[t.length - 1];
    const x = (v: number) => pad.l + ((v - t0) / (t1 - t0 || 1)) * (w - pad.l - pad.r);
    const y = (v: number) => pad.t + (1 - (v - lo) / (hi - lo)) * (height - pad.t - pad.b);
    const yTicks = Array.from({ length: 4 }, (_, i) => lo + ((hi - lo) * (i + 0.5)) / 4);
    const xTicks = Array.from({ length: 5 }, (_, i) => t0 + ((t1 - t0) * i) / 4);
    return { x, y, yTicks, xTicks };
  }, [series, band, t, w, height, pad.l, pad.r, pad.t, pad.b]);

  const path = (vals: (number | null)[]) =>
    vals.reduce((d, v, i) => (v === null ? d : d + `${d === "" || vals[i - 1] === null ? "M" : "L"}${x(t[i]).toFixed(1)},${y(v).toFixed(1)}`), "");

  const bandPath = band
    ? (() => {
        const segs: string[] = [];
        let top: string[] = [];
        let bot: string[] = [];
        const flush = () => {
          if (top.length) segs.push(`M${top.join("L")}L${bot.reverse().join("L")}Z`);
          top = [];
          bot = [];
        };
        band.lo.forEach((lo, i) => {
          const hi = band.hi[i];
          if (lo === null || hi === null) return flush();
          top.push(`${x(t[i]).toFixed(1)},${y(hi).toFixed(1)}`);
          bot.push(`${x(t[i]).toFixed(1)},${y(lo).toFixed(1)}`);
        });
        flush();
        return segs.join("");
      })()
    : "";

  const onMove = (e: React.MouseEvent<SVGSVGElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const px = e.clientX - rect.left;
    let best = 0;
    let bd = Infinity;
    t.forEach((v, i) => {
      const d = Math.abs(x(v) - px);
      if (d < bd) {
        bd = d;
        best = i;
      }
    });
    setHover(best);
  };

  return (
    <div ref={ref} className="relative w-full">
      <svg width={w} height={height} onMouseMove={onMove} onMouseLeave={() => setHover(null)} className="block">
        {yTicks.map((v) => (
          <g key={v}>
            <line x1={pad.l} x2={w - pad.r} y1={y(v)} y2={y(v)} stroke="var(--line2)" />
            <text x={pad.l - 8} y={y(v) + 4} textAnchor="end" fontSize="11" fill="var(--muted)">
              {format(v)}
            </text>
          </g>
        ))}
        {xTicks.map((v, i) => (
          <text key={v} x={x(v)} y={height - 6} textAnchor={i === 0 ? "start" : i === xTicks.length - 1 ? "end" : "middle"} fontSize="11" fill="var(--muted)">
            {day(v)}
          </text>
        ))}
        {bandPath && <path d={bandPath} fill={C_RULES} opacity={0.12} />}
        {markers.map((m, i) => (
          <line key={i} x1={x(m)} x2={x(m)} y1={pad.t} y2={height - pad.b} stroke={C_RULES} strokeOpacity={0.25} strokeDasharray="2 3" />
        ))}
        {series.map((s) => (
          <path key={s.name} d={path(s.values)} fill="none" stroke={s.color} strokeWidth={2} strokeDasharray={s.dashed ? "5 4" : undefined} strokeLinejoin="round" />
        ))}
        {dots &&
          series.map((s) => s.values.map((v, i) => <circle key={`${s.name}${i}`} cx={x(t[i])} cy={y(v)} r={4} fill={s.color} stroke="white" strokeWidth={2} />))}
        {hover !== null && (
          <g>
            <line x1={x(t[hover])} x2={x(t[hover])} y1={pad.t} y2={height - pad.b} stroke="var(--muted2)" />
            {series.map((s) => (
              <circle key={s.name} cx={x(t[hover])} cy={y(s.values[hover])} r={4} fill={s.color} stroke="white" strokeWidth={2} />
            ))}
          </g>
        )}
      </svg>
      {hover !== null && (
        <div
          className="pointer-events-none absolute top-1 rounded-[8px] border border-[var(--line)] bg-white px-2.5 py-1.5 text-[12px] shadow-sm"
          style={{ left: Math.min(Math.max(x(t[hover]) + 10, 0), w - 190) }}
        >
          <div className="mb-0.5 text-[var(--muted)]">{new Date(t[hover] * 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</div>
          {series.map((s) => (
            <div key={s.name} className="flex items-center gap-2">
              <span className="h-2 w-2 rounded-full" style={{ background: s.color }} />
              <span className="text-[var(--muted)]">{s.name}</span>
              <span className="ml-auto font-semibold">{format(s.values[hover])}</span>
            </div>
          ))}
          {band && band.lo[hover] !== null && (
            <div className="text-[var(--muted)]">
              range {fmt(band.lo[hover]!)}–{fmt(band.hi[hover]!)}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
