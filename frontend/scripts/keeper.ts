// Keeper bot: finds every rule whose condition is met and executes it, one transaction each.
// It is paid back its gas from the position it runs (see ConditionalOrders._payKeeper).
//
//   KEEPER_PRIVATE_KEY=0x... RPC_URL=https://... npx tsx scripts/keeper.ts
//   DRY_RUN=1 ...   lists what it would run, sends nothing
//
// Runs once and exits, so a scheduler (GitHub Actions cron) can call it every few minutes.
import { createPublicClient, createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { conditionalOrdersAbi } from "../lib/generated/abis";
import deployment from "../lib/generated/deployment.json";

const ORDERS = deployment.core.conditionalOrders as `0x${string}`;
const RPC = process.env.RPC_URL ?? process.env.SEPOLIA_RPC ?? "https://ethereum-sepolia-rpc.publicnode.com";
const KEY = process.env.KEEPER_PRIVATE_KEY ?? process.env.PRIVATE_KEY;
const DRY = !!process.env.DRY_RUN;

async function main() {
  const client = createPublicClient({ chain: sepolia, transport: http(RPC) });
  const c = { address: ORDERS, abi: conditionalOrdersAbi } as const;

  const next = await client.readContract({ ...c, functionName: "nextOrderId" });
  const now = BigInt(Math.floor(Date.now() / 1000));
  const ready: { id: bigint; upper: boolean }[] = [];
  for (let id = 1n; id < next; id++) {
    const [order] = await client.readContract({ ...c, functionName: "getOrder", args: [id] });
    if (order.owner === "0x0000000000000000000000000000000000000000" || BigInt(order.expiry) < now) continue;
    const [lower, upper] = await Promise.all([
      client.readContract({ ...c, functionName: "canExecute", args: [id, false] }),
      client.readContract({ ...c, functionName: "canExecute", args: [id, true] }),
    ]);
    if (lower) ready.push({ id, upper: false });
    if (upper) ready.push({ id, upper: true });
  }
  console.log(`${Number(next) - 1} orders checked, ${ready.length} ready`);
  if (!ready.length || DRY) return;
  if (!KEY) {
    console.log("No KEEPER_PRIVATE_KEY set: nothing sent.");
    return;
  }

  const account = privateKeyToAccount((KEY.startsWith("0x") ? KEY : `0x${KEY}`) as Hex);
  const wallet = createWalletClient({ account, chain: sepolia, transport: http(RPC) });
  for (const r of ready) {
    const label = `#${r.id} ${r.upper ? "upper" : "lower"}`;
    try {
      // Re-check on the latest block: another keeper may have run it, or the price moved back.
      const { request } = await client.simulateContract({ ...c, account, functionName: "execute", args: [r.id, r.upper] });
      const gas = await client.estimateContractGas({ ...c, account, functionName: "execute", args: [r.id, r.upper] });
      const hash = await wallet.writeContract({ ...request, gas: (gas * 12n) / 10n });
      const receipt = await client.waitForTransactionReceipt({ hash });
      console.log(`${label}: ${receipt.status} ${hash}`);
    } catch (e) {
      console.log(`${label}: skipped (${(e as Error).message.split("\n")[0]})`);
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
