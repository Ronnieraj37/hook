"use client";

import { ChevronDown } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { type Pool, type Token, fmt } from "@/lib/pools";
import { type TxState } from "@/lib/tx";

export function TxLine({ state }: { state: TxState }) {
  if (state.error) return <div className="text-[12px] text-[var(--rose)]">{state.error}</div>;
  if (state.message) return <div className={`text-[12px] ${state.busy ? "text-[var(--muted)]" : "text-[var(--sage)]"}`}>{state.message}</div>;
  return null;
}

export function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="label mb-1">{label}</div>
      {children}
      {hint && <div className="mt-1 text-[11px] text-[var(--muted)]">{hint}</div>}
    </div>
  );
}

/** Number input with a unit on the right. Keeps what the user typed while it is not a valid number yet. */
export function Suffix({ value, suffix, onChange }: { value: number | undefined; suffix: string; onChange: (v: string) => void }) {
  const [text, setText] = useState(value === undefined || isNaN(value) ? "" : String(value));
  const typing = useRef(false);
  useEffect(() => {
    if (!typing.current) setText(value === undefined || isNaN(value) ? "" : String(value));
    typing.current = false;
  }, [value]);
  return (
    <div className="relative">
      <input
        className="input pr-16"
        inputMode="decimal"
        value={text}
        onChange={(e) => {
          typing.current = true;
          setText(e.target.value);
          onChange(e.target.value);
        }}
      />
      <span className="pointer-events-none absolute right-3 top-2 text-[13px] text-[var(--muted)]">{suffix}</span>
    </div>
  );
}

export function Toggle({ value, onChange }: { value: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      type="button"
      onClick={() => onChange(!value)}
      className={`relative h-6 w-11 shrink-0 rounded-full transition-colors ${value ? "bg-[var(--ink)]" : "bg-[var(--line)]"}`}
      aria-pressed={value}
    >
      <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow transition-all ${value ? "left-[22px]" : "left-0.5"}`} />
    </button>
  );
}

/** Uniswap-style token amount box. */
export function TokenBox({
  label,
  token,
  value,
  onChange,
  balance,
  readOnly,
  right,
  dim,
}: {
  label: string;
  token: Token;
  value: string;
  onChange?: (v: string) => void;
  balance?: number;
  readOnly?: boolean;
  right?: React.ReactNode;
  dim?: string;
}) {
  return (
    <div className="rounded-[16px] bg-[var(--line2)] p-4">
      <div className="text-[13px] text-[var(--muted)]">{label}</div>
      <div className="mt-1 flex items-center gap-3">
        <input
          className="min-w-0 flex-1 bg-transparent text-[30px] font-medium outline-none placeholder:text-[var(--muted2)]"
          placeholder="0"
          inputMode="decimal"
          value={value}
          readOnly={readOnly}
          onChange={(e) => onChange?.(e.target.value.replace(",", "."))}
        />
        {right ?? <TokenPill token={token} />}
      </div>
      <div className="mt-1 flex justify-between text-[12px] text-[var(--muted)]">
        <span>{dim ?? ""}</span>
        {balance !== undefined && (
          <button className="hover:text-[var(--ink)]" onClick={() => onChange?.(String(balance))} disabled={readOnly}>
            Balance {fmt(balance)}
          </button>
        )}
      </div>
    </div>
  );
}

const TOKEN_COLORS: Record<string, string> = {
  WETH: "#627eea",
  ETH: "#627eea",
  WBTC: "#f7931a",
  USDC: "#2775ca",
  USDT: "#26a17b",
  DAI: "#f5ac37",
  LINK: "#2a5ada",
};

export function TokenIcon({ symbol, size = 20 }: { symbol: string; size?: number }) {
  return (
    <span
      className="grid shrink-0 place-items-center rounded-full font-bold text-white"
      style={{ width: size, height: size, background: TOKEN_COLORS[symbol] ?? "#888", fontSize: size * 0.42 }}
    >
      {symbol.slice(0, 1)}
    </span>
  );
}

export function TokenPill({ token, onClick }: { token: Token; onClick?: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`flex shrink-0 items-center gap-1.5 rounded-full border border-[var(--line)] bg-white py-1 pl-1 pr-3 text-[15px] font-semibold ${onClick ? "hover:border-[var(--ink)]" : "cursor-default"}`}
    >
      <TokenIcon symbol={token.symbol} size={24} />
      {token.symbol}
      {onClick && <ChevronDown className="h-4 w-4 text-[var(--muted)]" />}
    </button>
  );
}

export function PoolIcons({ pool }: { pool: Pool }) {
  return (
    <span className="flex">
      <TokenIcon symbol={pool.base.symbol} size={22} />
      <span className="-ml-1.5">
        <TokenIcon symbol={pool.quote.symbol} size={22} />
      </span>
    </span>
  );
}

/** Simple popover list. */
export function Menu<T>({
  items,
  render,
  onPick,
  onClose,
}: {
  items: T[];
  render: (t: T) => React.ReactNode;
  onPick: (t: T) => void;
  onClose: () => void;
}) {
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/25 p-4" onClick={onClose}>
      <div className="card max-h-[70vh] w-full max-w-sm overflow-y-auto p-2 shadow-xl" onClick={(e) => e.stopPropagation()}>
        {items.map((t, i) => (
          <button key={i} className="flex w-full items-center gap-3 rounded-md px-3 py-2.5 text-left hover:bg-[var(--line2)]" onClick={() => onPick(t)}>
            {render(t)}
          </button>
        ))}
      </div>
    </div>
  );
}

export function Empty({ text, children }: { text: string; children?: React.ReactNode }) {
  return (
    <div className="card flex flex-col items-center gap-3 p-10 text-center text-[13px] text-[var(--muted)]">
      {text}
      {children}
    </div>
  );
}
