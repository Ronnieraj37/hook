"use client";

import { AlertTriangle, Check, Code2, Copy, Info, Lightbulb, Link2 } from "lucide-react";
import { useState } from "react";

/** A top-level section with an anchor link. */
export function Section({ id, title, lead, children }: { id: string; title: string; lead?: string; children: React.ReactNode; dev?: boolean }) {
  const [copied, setCopied] = useState(false);
  return (
    <section id={id} data-section className="scroll-mt-24 border-b border-[var(--line)] py-12 first:pt-2 last:border-b-0">
      <h2 className="group relative mt-1">
        {title}
        <button
          aria-label="Copy link to this section"
          className="ml-2 inline-grid h-7 w-7 translate-y-[-2px] place-items-center rounded-md align-middle text-[var(--muted2)] opacity-0 transition-opacity hover:bg-[var(--line2)] hover:text-[var(--ink)] group-hover:opacity-100"
          onClick={() => {
            const url = `${window.location.origin}${window.location.pathname}${window.location.search}#${id}`;
            navigator.clipboard?.writeText(url);
            history.replaceState(null, "", `#${id}`);
            setCopied(true);
            setTimeout(() => setCopied(false), 1200);
          }}
        >
          {copied ? <Check className="h-4 w-4 text-[var(--sage)]" /> : <Link2 className="h-4 w-4" />}
        </button>
      </h2>
      {lead && <p className="lead">{lead}</p>}
      {children}
    </section>
  );
}

/** Technical notes inside a guide section, set apart so readers can skip them. */
export function Dev({ children, title = "Under the hood" }: { children: React.ReactNode; title?: string }) {
  return (
    <div className="my-5 rounded-[12px] border border-[var(--line)] bg-white">
      <div className="flex items-center gap-2 border-b border-[var(--line2)] px-4 py-2 text-[12px] font-semibold text-[var(--accent-ink)]">
        <Code2 className="h-3.5 w-3.5" />
        {title}
      </div>
      <div className="px-4 py-1 text-[14px] [&_p]:text-[14px]">{children}</div>
    </div>
  );
}

export function Callout({ kind = "note", title, children }: { kind?: "note" | "tip" | "warn"; title?: string; children: React.ReactNode }) {
  const map = {
    note: { Icon: Info, bg: "bg-[var(--blue-lt)]", fg: "text-[var(--blue)]" },
    tip: { Icon: Lightbulb, bg: "bg-[var(--accent-lt)]", fg: "text-[var(--accent-ink)]" },
    warn: { Icon: AlertTriangle, bg: "bg-[var(--amber-lt)]", fg: "text-[var(--amber)]" },
  }[kind];
  return (
    <div className={`my-5 flex gap-3 rounded-[12px] ${map.bg} px-4 py-3 text-[14px]`}>
      <map.Icon className={`mt-0.5 h-4 w-4 shrink-0 ${map.fg}`} />
      <div className="[&_p]:my-1 [&_p]:text-[14px]">
        {title && <div className={`font-semibold ${map.fg}`}>{title}</div>}
        {children}
      </div>
    </div>
  );
}

export function Code({ children, lang }: { children: string; lang?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="group relative my-4 overflow-hidden rounded-[12px] bg-[#0b1f2a]">
      {lang && <div className="border-b border-white/10 px-4 py-1.5 text-[11px] font-medium uppercase tracking-wider text-white/40">{lang}</div>}
      <button
        aria-label="Copy"
        onClick={() => {
          navigator.clipboard?.writeText(children);
          setCopied(true);
          setTimeout(() => setCopied(false), 1200);
        }}
        className="absolute right-2 top-1.5 grid h-7 w-7 place-items-center rounded-md text-white/50 opacity-0 transition-opacity hover:bg-white/10 hover:text-white group-hover:opacity-100"
      >
        {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
      </button>
      <pre className="overflow-x-auto px-4 py-3 text-[12.5px] leading-relaxed text-[#d7e7ec]">
        <code style={{ background: "none", border: 0, padding: 0, color: "inherit", fontSize: "inherit" }}>{children}</code>
      </pre>
    </div>
  );
}

/** A step list with numbered circles. */
export function Steps({ items }: { items: React.ReactNode[] }) {
  return (
    <ol className="!my-5 !list-none !pl-0">
      {items.map((it, i) => (
        <li key={i} className="relative !my-0 flex gap-3 pb-4 last:pb-0">
          {i < items.length - 1 && <span className="absolute left-[11px] top-7 h-[calc(100%-24px)] w-px bg-[var(--line)]" />}
          <span className="z-10 grid h-6 w-6 shrink-0 place-items-center rounded-full bg-[var(--accent)] text-[12px] font-semibold text-white">{i + 1}</span>
          <div className="pt-0.5">{it}</div>
        </li>
      ))}
    </ol>
  );
}

/** Small cards in a grid, for "what you can do" style overviews. */
export function Cards({ items }: { items: { icon: React.ElementType; title: string; text: string; href?: string }[] }) {
  return (
    <div className="my-6 grid gap-3 sm:grid-cols-2">
      {items.map((c) => {
        const body = (
          <div className="h-full rounded-[12px] border border-[var(--line)] bg-white p-4 transition-colors hover:border-[var(--accent)]">
            <div className="mb-2 grid h-8 w-8 place-items-center rounded-[9px] bg-[var(--accent-lt)] text-[var(--accent-ink)]">
              <c.icon className="h-4 w-4" />
            </div>
            <div className="text-[14px] font-semibold">{c.title}</div>
            <div className="mt-0.5 text-[13px] leading-relaxed text-[var(--muted)]">{c.text}</div>
          </div>
        );
        return c.href ? (
          <a key={c.title} href={c.href} className="!no-underline">
            {body}
          </a>
        ) : (
          <div key={c.title}>{body}</div>
        );
      })}
    </div>
  );
}

export function Kbd({ children }: { children: React.ReactNode }) {
  return <span className="rounded-md border border-[var(--line)] bg-white px-1.5 py-0.5 text-[12px] font-medium shadow-[0_1px_0_var(--line)]">{children}</span>;
}
