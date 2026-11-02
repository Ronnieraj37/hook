"use client";

import { ArrowLeft, Pencil, Play, Sparkles } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { type Abi } from "viem";
import { useAccount } from "wagmi";
import RuleEditor from "@/components/RuleEditor";
import { Empty, PoolIcons, TxLine } from "@/components/ui";
import { conditionalOrdersAbi } from "@/lib/generated/abis";
import { useRulePosition } from "@/lib/positions";
import { CORE, fmt, maxUsable, minUsable, priceAtTick, priceRange } from "@/lib/pools";
import { type Advanced, type LaneId, type Rules, describeLane, encodeRules, laneTitle, sideFor } from "@/lib/rules";
import { useTx } from "@/lib/tx";

export default function PositionDetail({ id }: { id: bigint }) {
  const router = useRouter();
  const { address } = useAccount();
  const q = useRulePosition(id);
  const tx = useTx();
  const [editor, setEditor] = useState(false);
  const p = q.data;

  if (q.isLoading) return <Wrap><Empty text="Loading…" /></Wrap>;
  if (!p) return <Wrap><Empty text="This position is closed or does not exist." /></Wrap>;

  const c = { address: CORE.conditionalOrders, abi: conditionalOrdersAbi as Abi };
  const full = p.tickLower === minUsable(p.pool.key.tickSpacing) && p.tickUpper === maxUsable(p.pool.key.tickSpacing);
  const [lo, hi] = priceRange(p.pool, p.tickLower, p.tickUpper);
  const price = priceAtTick(p.pool, p.tick);
  const inRange = p.tick >= p.tickLower && p.tick < p.tickUpper;
  const rangeLabel = full ? "Full range" : `${fmt(lo)} – ${fmt(hi)} ${p.pool.quote.symbol}`;

  const run = (lane: LaneId) =>
    tx.run(async () => {
      await tx.send("Run rule", { ...c, functionName: "execute", args: [p.id, sideFor(p.pool, lane, p.rules[lane]) === "upper"] });
      q.refetch();
    }, "Rule ran");
  const close = () =>
    tx.run(async () => {
      await tx.send("Withdraw everything", { ...c, functionName: "cancel", args: [p.id] });
      router.push("/pool");
    }, "Withdrawn to your wallet");
  const save = (rules: Rules, adv: Advanced) =>
    tx.run(async () => {
      const enc = encodeRules(p.pool, rules);
      await tx.send("Save rules", {
        ...c,
        functionName: "updateOrder",
        args: [
          p.id,
          {
            swapPoolIndex: 0,
            expiry: Math.floor(Date.now() / 1000) + adv.expiryDays * 86400,
            maxKeeperFeeBps: adv.keeperFeeBps,
            maxSlippage: Math.max(1, Math.round(adv.slippagePct * 10)),
            lower: enc.lower,
            upper: enc.upper,
          },
        ],
      });
      setEditor(false);
      q.refetch();
    }, "Rules saved");

  return (
    <Wrap>
      <Link href="/pool" className="flex items-center gap-1 text-[13px] text-[var(--muted)] hover:text-[var(--ink)]">
        <ArrowLeft className="h-4 w-4" /> Positions
      </Link>
      <div className="flex flex-wrap items-center gap-3">
        <PoolIcons pool={p.pool} />
        <h1 className="text-xl font-semibold">
          {p.pool.base.symbol} / {p.pool.quote.symbol}
        </h1>
        <span className="rounded bg-[var(--line2)] px-1.5 py-0.5 text-[11px] font-semibold">{p.pool.key.fee / 10_000}%</span>
        <span className={`text-[12px] font-semibold ${inRange ? "text-[var(--sage)]" : "text-[var(--amber)]"}`}>{inRange ? "● In range" : "● Out of range"}</span>
        <span className="text-[12px] text-[var(--muted)]">#{String(p.id)}</span>
      </div>

      <div className="grid gap-3 md:grid-cols-2">
        <div className="card p-4">
          <div className="label mb-1">Liquidity</div>
          <div className="text-[15px]">
            {fmt(p.amount0)} {p.pool.token0.symbol}
          </div>
          <div className="text-[15px]">
            {fmt(p.amount1)} {p.pool.token1.symbol}
          </div>
        </div>
        <div className="card p-4">
          <div className="label mb-1">Range</div>
          <div className="text-[15px]">{rangeLabel}</div>
          <div className="text-[13px] text-[var(--muted)]">
            Now 1 {p.pool.base.symbol} = {fmt(price)} {p.pool.quote.symbol}
          </div>
        </div>
      </div>

      <div className="card p-4">
        <div className="mb-3 flex items-center gap-2">
          <Sparkles className="h-4 w-4" />
          <div className="font-semibold">Rules</div>
          <span className="text-[12px] text-[var(--muted)]">expire {new Date(p.expiry * 1000).toLocaleDateString()}</span>
          <button className="btn btn-light ml-auto" onClick={() => setEditor(true)}>
            <Pencil className="h-3.5 w-3.5" /> Edit rules
          </button>
        </div>
        <div className="flex flex-col gap-2">
          {(["down", "up"] as LaneId[]).map((lane) => {
            const text = describeLane(p.pool, lane, p.rules[lane]);
            return (
              <div key={lane} className="flex items-center gap-3 rounded-[10px] bg-[var(--line2)] p-3 text-[13px]">
                <div className="flex-1">
                  <div className={`label mb-0.5 ${lane === "up" ? "!text-[var(--sage)]" : "!text-[var(--rose)]"}`}>{laneTitle(p.pool, lane, p.rules[lane])}</div>
                  {text ?? <span className="text-[var(--muted)]">Nothing happens.</span>}
                </div>
                {p.ready[lane] && (
                  <button className="btn btn-dark shrink-0" disabled={!address || tx.state.busy} onClick={() => run(lane)} title="Anyone can run a rule whose condition is met">
                    <Play className="h-3.5 w-3.5" /> Run now
                  </button>
                )}
              </div>
            );
          })}
        </div>
      </div>

      <div className="flex items-center gap-3">
        <button className="btn btn-danger" disabled={!address || tx.state.busy} onClick={close}>
          Withdraw everything
        </button>
        <TxLine state={tx.state} />
      </div>

      {editor && (
        <RuleEditor
          pool={p.pool}
          price={price}
          rangeLabel={rangeLabel}
          amountsLabel={`${fmt(p.amount0)} ${p.pool.token0.symbol} + ${fmt(p.amount1)} ${p.pool.token1.symbol}`}
          initialRules={p.rules}
          initialAdvanced={p.advanced}
          saveLabel={tx.state.busy ? "Saving…" : "Save rules"}
          range={full ? { full: true } : { loPct: (lo / price - 1) * 100, hiPct: (hi / price - 1) * 100 }}
          busy={tx.state.busy}
          onClose={() => setEditor(false)}
          onSave={save}
        />
      )}
    </Wrap>
  );
}

function Wrap({ children }: { children: React.ReactNode }) {
  return <div className="mx-auto flex max-w-[760px] flex-col gap-4 px-4 py-8">{children}</div>;
}
