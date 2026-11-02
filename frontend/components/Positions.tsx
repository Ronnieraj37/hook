"use client";

import { Plus, Sparkles, Wallet } from "lucide-react";
import Link from "next/link";
import { useEffect, useState } from "react";
import { type Abi } from "viem";
import { useAccount } from "wagmi";
import { Empty, PoolIcons, TxLine } from "@/components/ui";
import { conditionalOrdersAbi } from "@/lib/generated/abis";
import { type PlainPosition, type RulePosition, useMyPositions } from "@/lib/positions";
import { CORE, fmt, maxUsable, minUsable, priceAtTick, priceRange } from "@/lib/pools";
import { useTx } from "@/lib/tx";

export default function Positions() {
  const { address: connected } = useAccount();
  // Read-only view of any wallet: /pool?as=0x... (handy for demos)
  const [viewAs, setViewAs] = useState<string | null>(null);
  useEffect(() => setViewAs(new URLSearchParams(window.location.search).get("as")), []);
  const owner = (viewAs as `0x${string}` | null) ?? connected;
  const q = useMyPositions(owner);
  const tx = useTx();

  const withdrawHeld = (currency: `0x${string}`) =>
    tx.run(async () => {
      await tx.send("Withdraw held payout", { address: CORE.conditionalOrders, abi: conditionalOrdersAbi as Abi, functionName: "withdraw", args: [currency, connected] });
      q.refetch();
    });

  const all = [...(q.data?.rules ?? []), ...(q.data?.plain ?? [])];

  return (
    <div className="mx-auto flex max-w-[860px] flex-col gap-4 px-4 py-8">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">Positions</h1>
          {viewAs && <div className="text-[12px] text-[var(--muted)]">Viewing {viewAs.slice(0, 6)}…{viewAs.slice(-4)} (read-only)</div>}
        </div>
        <Link href="/pool/new" className="btn btn-dark !rounded-full">
          <Plus className="h-4 w-4" /> New position
        </Link>
      </div>
      <TxLine state={tx.state} />

      {q.data?.held.map((h) => (
        <div key={h.currency} className="card flex items-center gap-3 p-3 text-[13px]">
          <Wallet className="h-4 w-4 text-[var(--amber)]" />
          {fmt(h.amount)} {h.symbol} could not be sent to your wallet and is waiting for you.
          <button className="btn btn-dark ml-auto" onClick={() => withdrawHeld(h.currency)}>
            Withdraw
          </button>
        </div>
      ))}

      {!owner && <Empty text="Connect your wallet to see your positions." />}
      {owner && q.isLoading && <Empty text="Loading your positions…" />}
      {q.data && all.length === 0 && (
        <Empty text="You have no positions yet.">
          <Link href="/pool/new" className="btn btn-dark !rounded-full">
            <Plus className="h-4 w-4" /> New position
          </Link>
        </Empty>
      )}

      <div className="flex flex-col gap-2">
        {all.map((p) => (
          <PositionRow key={`${p.kind}-${p.id}`} p={p} />
        ))}
      </div>
    </div>
  );
}

function PositionRow({ p }: { p: RulePosition | PlainPosition }) {
  const full = p.tickLower === minUsable(p.pool.key.tickSpacing) && p.tickUpper === maxUsable(p.pool.key.tickSpacing);
  const [lo, hi] = priceRange(p.pool, p.tickLower, p.tickUpper);
  const inRange = p.tick >= p.tickLower && p.tick < p.tickUpper;
  const ruleCount = p.kind === "rules" ? (p.rules.down.trigger ? 1 : 0) + (p.rules.up.trigger ? 1 : 0) : 0;
  const ready = p.kind === "rules" && (p.ready.down || p.ready.up);
  const body = (
    <div className="card flex flex-wrap items-center gap-4 p-4 transition-colors hover:border-[var(--muted2)]">
      <PoolIcons pool={p.pool} />
      <div className="min-w-[200px] flex-1">
        <div className="flex items-center gap-2">
          <span className="font-semibold">
            {p.pool.base.symbol} / {p.pool.quote.symbol}
          </span>
          <span className="rounded bg-[var(--line2)] px-1.5 py-0.5 text-[11px] font-semibold">{p.pool.key.fee / 10_000}%</span>
          <span className={`flex items-center gap-1 text-[11px] font-semibold ${inRange ? "text-[var(--sage)]" : "text-[var(--amber)]"}`}>
            <span className={`h-1.5 w-1.5 rounded-full ${inRange ? "bg-[var(--sage)]" : "bg-[var(--amber)]"}`} />
            {inRange ? "In range" : "Out of range"}
          </span>
        </div>
        <div className="text-[13px] text-[var(--muted)]">
          {full ? "Full range" : `${fmt(lo)} – ${fmt(hi)} ${p.pool.quote.symbol}`} · now {fmt(priceAtTick(p.pool, p.tick))}
        </div>
      </div>
      <div className="text-right text-[13px]">
        <div>
          {fmt(p.amount0)} {p.pool.token0.symbol}
        </div>
        <div>
          {fmt(p.amount1)} {p.pool.token1.symbol}
        </div>
      </div>
      <div className="w-[120px] text-right">
        {p.kind === "rules" ? (
          <span className={`inline-flex items-center gap-1 rounded-full px-2 py-1 text-[11px] font-semibold ${ready ? "bg-[var(--ink)] text-white" : "bg-[var(--line2)]"}`}>
            <Sparkles className="h-3 w-3" />
            {ready ? "Rule ready" : `${ruleCount} rule${ruleCount === 1 ? "" : "s"}`}
          </span>
        ) : (
          <span className="text-[11px] text-[var(--muted)]">No rules</span>
        )}
      </div>
    </div>
  );
  return p.kind === "rules" ? <Link href={`/pool/${p.id}`}>{body}</Link> : body;
}
