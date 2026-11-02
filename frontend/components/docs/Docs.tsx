"use client";

import { BookOpen, Code2, Search, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { APP_NAME } from "@/lib/brand";
import { SECTIONS } from "./content";

export default function Docs() {
  const [query, setQuery] = useState("");
  const [active, setActive] = useState("overview");

  const q = query.trim().toLowerCase();
  const matches = useMemo(() => (q ? SECTIONS.filter((s) => (s.title + " " + s.keywords).toLowerCase().includes(q)) : SECTIONS), [q]);

  // Highlight the section being read: the last one whose heading has passed the reading line.
  useEffect(() => {
    let raf = 0;
    const update = () => {
      raf = 0;
      const els = Array.from(document.querySelectorAll<HTMLElement>("[data-section]"));
      let current = els[0]?.id ?? "overview";
      for (const el of els) if (el.getBoundingClientRect().top <= 140) current = el.id;
      // at the very bottom, the last section is the one being read
      if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4 && els.length) current = els[els.length - 1].id;
      setActive(current);
    };
    const onScroll = () => {
      if (!raf) raf = requestAnimationFrame(update);
    };
    update();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      window.removeEventListener("scroll", onScroll);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [matches]);

  // Opening a link to a section scrolls to it once the page has rendered.
  useEffect(() => {
    const id = window.location.hash.slice(1);
    if (id) setTimeout(() => document.getElementById(id)?.scrollIntoView(), 50);
  }, []);

  const go = (id: string) => {
    document.getElementById(id)?.scrollIntoView({ behavior: "smooth" });
    history.replaceState(null, "", `${window.location.pathname}#${id}`);
  };

  const guide = matches.filter((s) => s.group === "guide");
  const internals = matches.filter((s) => s.group === "dev");

  return (
    <div className="mx-auto max-w-[1200px] px-4">
      {/* hero */}
      <div className="border-b border-[var(--line)] pb-6 pt-8">
        <div className="flex items-center gap-2 text-[13px] font-medium text-[var(--accent-ink)]">
          <BookOpen className="h-4 w-4" /> Documentation
        </div>
        <h1 className="mt-1 text-[34px] font-semibold tracking-tight">How {APP_NAME} works</h1>
        <p className="mt-1 max-w-[620px] text-[15px] text-[var(--muted)]">
          How to swap, place limit orders and put rules on your liquidity, and how it all works inside: contracts, storage, encodings, formulas and APIs.
        </p>
      </div>

      <div className="grid gap-10 lg:grid-cols-[230px_1fr]">
        {/* sidebar */}
        <aside className="lg:sticky lg:top-16 lg:h-[calc(100vh-64px)] lg:overflow-y-auto lg:py-6">
          <div className="relative mt-4 lg:mt-0">
            <Search className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-[var(--muted2)]" />
            <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search the docs" className="input !py-1.5 !pl-8 !pr-8 text-[13px]" aria-label="Search the docs" />
            {query && (
              <button className="absolute right-2 top-1/2 -translate-y-1/2 text-[var(--muted)]" onClick={() => setQuery("")} aria-label="Clear search">
                <X className="h-3.5 w-3.5" />
              </button>
            )}
          </div>
          <nav className="mt-4 flex flex-col gap-5 text-[13.5px]">
            {guide.length > 0 && <TocGroup title="Using Alucard" items={guide} active={active} onGo={go} />}
            {internals.length > 0 && <TocGroup title="Under the hood" items={internals} active={active} onGo={go} code />}
            {!matches.length && <div className="text-[13px] text-[var(--muted)]">Nothing matches “{query}”.</div>}
          </nav>
        </aside>

        {/* content */}
        <main className="doc min-w-0 max-w-[760px] pb-24">
          {matches.map((s, i) => (
            <div key={s.id}>
              {s.group === "dev" && (i === 0 || matches[i - 1].group !== "dev") && (
                <div className="mt-10 flex items-center gap-3 text-[12px] font-semibold uppercase tracking-wider text-[var(--muted)]">
                  <Code2 className="h-4 w-4 text-[var(--accent-ink)]" />
                  Under the hood
                  <span className="h-px flex-1 bg-[var(--line)]" />
                </div>
              )}
              {s.render()}
            </div>
          ))}
        </main>
      </div>
    </div>
  );
}

function TocGroup({ title, items, active, onGo, code }: { title: string; items: { id: string; title: string }[]; active: string; onGo: (id: string) => void; code?: boolean }) {
  return (
    <div>
      <div className="mb-1.5 flex items-center gap-1.5 px-2 text-[11px] font-semibold uppercase tracking-wider text-[var(--muted)]">
        {code && <Code2 className="h-3 w-3" />}
        {title}
      </div>
      <ul className="flex flex-col">
        {items.map((s) => (
          <li key={s.id}>
            <button
              onClick={() => onGo(s.id)}
              className={`relative w-full rounded-[8px] px-2 py-1.5 text-left transition-colors ${
                active === s.id ? "bg-[var(--accent-lt)] font-medium text-[var(--accent-ink)]" : "text-[var(--muted)] hover:bg-[var(--line2)] hover:text-[var(--ink)]"
              }`}
            >
              {s.title}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
