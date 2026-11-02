"use client";

import { useCallback, useState } from "react";
import { type Abi, BaseError, ContractFunctionRevertedError, maxUint256 } from "viem";
import { useAccount, useBalance, usePublicClient, useReadContract, useWriteContract } from "wagmi";
import { testTokenAbi } from "./generated/abis";
import { type Token } from "./pools";

export type TxState = { busy: boolean; message: string | null; error: string | null; hash: string | null };

/** Run one or more writes in order, waiting for each to be mined, with a plain status line for the user. */
export function useTx() {
  const client = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const { address } = useAccount();
  const [state, setState] = useState<TxState>({ busy: false, message: null, error: null, hash: null });

  const send = useCallback(
    async (label: string, req: { address: `0x${string}`; abi: Abi; functionName: string; args?: readonly unknown[]; value?: bigint }) => {
      setState((s) => ({ ...s, busy: true, message: `${label}: confirm in your wallet…`, error: null }));
      const hash = await writeContractAsync(req as never);
      setState((s) => ({ ...s, message: `${label}: waiting for the block…`, hash }));
      const receipt = await client!.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error(`${label} failed on-chain`);
      return receipt;
    },
    [client, writeContractAsync],
  );

  /** Approve `spender` for `amount` of `token` if the allowance is not enough already. */
  const ensureAllowance = useCallback(
    async (token: Token, spender: `0x${string}`, amount: bigint) => {
      if (token.native || amount === 0n || !address) return;
      const allowance = await client!.readContract({
        address: token.address,
        abi: testTokenAbi,
        functionName: "allowance",
        args: [address, spender],
      });
      if (allowance >= amount) return;
      await send(`Approve t${token.symbol}`, {
        address: token.address,
        abi: testTokenAbi as Abi,
        functionName: "approve",
        args: [spender, maxUint256],
      });
    },
    [address, client, send],
  );

  const run = useCallback(async (fn: () => Promise<unknown>, done = "Done") => {
    try {
      await fn();
      setState({ busy: false, message: done, error: null, hash: null });
      return true;
    } catch (e) {
      setState({ busy: false, message: null, error: explain(e), hash: null });
      return false;
    }
  }, []);

  return { state, send, ensureAllowance, run };
}

/** Turn wallet and revert errors into one short sentence. */
export function explain(e: unknown): string {
  if (e instanceof BaseError) {
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName;
      if (name) return HUMAN_ERRORS[name] ?? `The contract refused: ${name}`;
    }
    if (e.shortMessage?.includes("User rejected")) return "You cancelled the transaction in your wallet.";
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}

const HUMAN_ERRORS: Record<string, string> = {
  ConditionNotMet: "Its condition is not met right now.",
  SwappedThisTx: "The pool was swapped in this same transaction. Try again in a new transaction.",
  WouldRefire: "This run would leave the order ready to fire again at once, so it was refused.",
  InvalidSide: "One of the rules is not allowed. Check the warnings on the canvas.",
  InvalidOrder: "The order settings are not valid (expiry, fee or both sides empty).",
  TooMuchIn: "The price moved while you were confirming. Refresh and try again.",
  NotOwner: "Only the owner can do this.",
  Expired: "This order has expired. Anyone can now cancel it, which returns the tokens to the owner.",
  UnknownOrder: "This order no longer exists.",
};

/** Balance of a token (native ETH or ERC20) for the connected wallet. */
export function useTokenBalance(token: Token): bigint | undefined {
  const { address } = useAccount();
  const native = useBalance({ address, query: { enabled: !!address && !!token.native } });
  const erc20 = useReadContract({
    address: token.address,
    abi: testTokenAbi,
    functionName: "balanceOf",
    args: [address ?? "0x0000000000000000000000000000000000000000"],
    query: { enabled: !!address && !token.native },
  });
  return token.native ? native.data?.value : (erc20.data as bigint | undefined);
}
