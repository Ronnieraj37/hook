import type { Metadata } from "next";
import Docs from "@/components/docs/Docs";

export const metadata: Metadata = { title: "Docs · Alucard", description: "How Alucard works: swaps, limit orders, rules on Uniswap liquidity, keepers, backtests, and the internals." };

export default function Page() {
  return <Docs />;
}
