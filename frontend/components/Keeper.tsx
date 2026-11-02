"use client";

import { useQuery } from "@tanstack/react-query";
import { Bot, Play, RefreshCw } from "lucide-react";
import { type Abi } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { Empty, TxLine } from "@/components/ui";
import { conditionalOrdersAbi } from "@/lib/generated/abis";
import { CORE } from "@/lib/pools";
import { loadRulePosition } from "@/lib/positions";
import { type LaneId, describeLane, sideFor } from "@/lib/rules";
import { useTx } from "@/lib/tx";

/** Anyone can run a rule once its condition is met, and is paid a gas refund from that position. */
export default function Keeper() {
  const client = usePublicClient();
  const { address } = useAccount();
  const tx = useTx();
  const q = useQuery({
    queryKey: ["keeper"],
    enabled: !!client,
    refetchInterval: 15_000,
    queryFn: async () => {
      const next = await client!.readContract({ address: CORE.conditionalOrders, abi: conditionalOrdersAbi, functionName: "nextOrderId" });
      const ready: { id: bigint; upper: boolean; text: string; label: string }[] = [];
      let open = 0;
      for (let id = 1n; id < next; id++) {
        const p = await loadRulePosition(client!, id);
        if (!p) continue;
        open++;
        for (const lane of ["down", "up"] as LaneId[]) {
          if (!p.ready[lane]) continue;
          ready.push({ id, upper: sideFor(p.pool, lane, p.rules[lane]) === "upper", text: describeLane(p.pool, lane, p.rules[lane]) ?? "", label: p.pool.label });
        }
      }
      return { open, ready };
    },
  });

  // One transaction per rule: running right after a swap in the same transaction is refused on purpose.
  const runAll = () =>
    tx.run(async () => {
      for (const r of q.data?.ready ?? []) {
        await tx.send(`Run #${r.id}`, { address: CORE.conditionalOrders, abi: conditionalOrdersAbi as Abi, functionName: "execute", args: [r.id, r.upper] });
      }
      q.refetch();
    }, "All ready rules ran. Your gas refund arrived in your wallet.");

  return (
    <div className="mx-auto flex max-w-[680px] flex-col gap-4 px-4 py-8">
      <div className="flex items-start gap-3">
        <div>
          <h1 className="text-xl font-semibold">Keeper</h1>
          <div className="text-[13px] text-[var(--muted)]">
            Rules run when someone sends the transaction. Anyone can, and is paid back the gas from that position.
          </div>
        </div>
        <button className="btn btn-light ml-auto !p-2" onClick={() => q.refetch()} title="Refresh">
          <RefreshCw className={`h-4 w-4 ${q.isFetching ? "animate-spin" : ""}`} />
        </button>
      </div>
      <div className="text-[13px] text-[var(--muted)]">{q.data ? `${q.data.open} open positions with rules, ${q.data.ready.length} ready to run.` : "Checking…"}</div>
      {q.data && q.data.ready.length === 0 && <Empty text="Nothing to run right now. Move a price on the Swap page to trigger rules." />}
      <div className="flex flex-col gap-2">
        {q.data?.ready.map((r) => (
          <div key={`${r.id}-${r.upper}`} className="card flex items-start gap-3 p-3 text-[13px]">
            <Bot className="mt-0.5 h-4 w-4 text-[var(--muted)]" />
            <div>
              <div className="font-semibold">
                #{String(r.id)} · {r.label}
              </div>
              <div className="text-[var(--muted)]">{r.text}</div>
            </div>
          </div>
        ))}
      </div>
      {!!q.data?.ready.length && (
        <button className="btn btn-dark !rounded-[14px] !py-3" disabled={!address || tx.state.busy} onClick={runAll}>
          <Play className="h-4 w-4" /> {address ? "Run all ready rules" : "Connect a wallet to run them"}
        </button>
      )}
      <TxLine state={tx.state} />
    </div>
  );
}
