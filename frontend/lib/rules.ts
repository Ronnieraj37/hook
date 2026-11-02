// The rule model the UI works with, and its translation to the contract's two sides.
//
// The UI talks about the BASE token's price ("if WETH falls"). The contract talks about ticks of token1 per token0
// ("lower side" fires when the tick falls). When the base token is token1 the two point opposite ways, so every
// mapping below goes through `contractSide`.

import { type Pool, pctForTicks, priceAtTick, poolByIndex, ticksForPct, tickAtPrice, fmt } from "./pools";

export type LaneId = "down" | "up"; // base price falls / rises

export type TriggerKind = "leave" | "price" | "otherPool" | "timer";
export type Trigger = {
  kind: TriggerKind;
  bufferPct?: number; // leave: how far past the range edge
  price?: number; // price, otherPool: base price in quote
  poolIndex?: number; // otherPool
  hours?: number; // timer
};

export type ActionKind = "collect" | "withdraw" | "convert" | "readd" | "follow";
export type Action = {
  kind: ActionKind;
  pct?: number; // withdraw: % of the liquidity
  to?: "base" | "quote"; // convert
  widthPct?: number; // follow: width of the new range
};

export type Lane = { trigger: Trigger | null; actions: Action[]; repeat: boolean; stepPct?: number };
export type Rules = { down: Lane; up: Lane };

export type Advanced = { keeperFeeBps: number; slippagePct: number; expiryDays: number };
export const DEFAULT_ADVANCED: Advanced = { keeperFeeBps: 10, slippagePct: 1, expiryDays: 30 };

export const ACTION_ORDER: ActionKind[] = ["collect", "withdraw", "convert", "readd", "follow"];
export const emptyLane = (): Lane => ({ trigger: null, actions: [], repeat: false });
export const emptyRules = (): Rules => ({ down: emptyLane(), up: emptyLane() });

// Contract constants (OrderState.sol)
const CHECK = { OFF: 0, EDGE: 1, TICK: 2, TIME: 3 } as const;
const ACT = { KEEP_FEES: 1, REMOVE: 2, SWAP: 4, ADD: 8 } as const;
const ADD_SAME = 0;
const ADD_ONE_SIDED = 1;

export type Side = {
  edge: number;
  checker: number;
  value: number;
  checkPool: number;
  actions: number;
  removeBps: number;
  swapToToken1: boolean;
  addMode: number;
  repeat: boolean;
  shape: number;
  lastRun: number;
};

const offSide = (): Side => ({
  edge: 0,
  checker: 0,
  value: 0,
  checkPool: 0,
  actions: 0,
  removeBps: 0,
  swapToToken1: false,
  addMode: 0,
  repeat: false,
  shape: 0,
  lastRun: 0,
});

/** Which contract side a lane uses: "up" (base rises) is the upper side when base is token0. */
export const contractSide = (p: Pool, lane: LaneId): "lower" | "upper" =>
  (lane === "up") === p.baseIs0 ? "upper" : "lower";

/** The pool whose price a lane's trigger reads: another pool for "price in another pool", else this one. */
export const watched = (p: Pool, lane: Lane): Pool =>
  lane.trigger?.kind === "otherPool" && lane.trigger.poolIndex ? poolByIndex(lane.trigger.poolIndex) ?? p : p;

/** Contract side a lane uses. A price check runs on the watched pool's ticks, so that pool's orientation decides. */
export const sideFor = (p: Pool, id: LaneId, lane: Lane) => contractSide(watched(p, lane), id);

export const has = (lane: Lane, k: ActionKind) => lane.actions.some((a) => a.kind === k);
export const get = (lane: Lane, k: ActionKind) => lane.actions.find((a) => a.kind === k);

/** Insert or replace an action, keeping the order the contract runs them in. Adds what an action needs. */
export function withAction(lane: Lane, a: Action): Lane {
  let actions = [...lane.actions.filter((x) => x.kind !== a.kind), a];
  if (a.kind === "convert" && !actions.some((x) => x.kind === "withdraw")) actions.push({ kind: "withdraw", pct: 100 });
  if (a.kind === "convert") actions = actions.filter((x) => x.kind !== "readd" && x.kind !== "follow");
  if (a.kind === "readd" || a.kind === "follow") {
    actions = actions.filter((x) => x.kind !== "convert" && (a.kind === "readd" ? x.kind !== "follow" : x.kind !== "readd"));
  }
  if (a.kind === "follow") actions = actions.filter((x) => x.kind !== "withdraw"); // follow moves everything
  actions.sort((x, y) => ACTION_ORDER.indexOf(x.kind) - ACTION_ORDER.indexOf(y.kind));
  return { ...lane, actions };
}

// ---------------------------------------------------------------- encode / decode

function encodeLane(p: Pool, lane: Lane, laneId: LaneId): Side {
  const s = offSide();
  if (!lane.trigger || lane.actions.length === 0) return s;
  const upper = sideFor(p, laneId, lane) === "upper";
  const t = lane.trigger;
  const follow = get(lane, "follow");
  const spacing = p.key.tickSpacing;

  if (t.kind === "leave") {
    s.checker = CHECK.EDGE;
    s.value = ticksForPct(t.bufferPct ?? 0);
    if (follow && lane.repeat) s.value = Math.max(s.value, spacing); // the new range sits next to the price
  } else if (t.kind === "price" || t.kind === "otherPool") {
    s.checker = CHECK.TICK;
    s.value = Math.round(tickAtPrice(watched(p, lane), t.price ?? 0));
    s.checkPool = t.kind === "otherPool" ? t.poolIndex ?? 0 : 0;
  } else {
    s.checker = CHECK.TIME;
    s.value = Math.max(1, Math.round((t.hours ?? 24) * 60));
  }

  const withdraw = get(lane, "withdraw");
  const collect = has(lane, "collect");
  let bits = collect ? 0 : ACT.KEEP_FEES;
  if (withdraw) {
    bits |= ACT.REMOVE;
    s.removeBps = Math.round((withdraw.pct ?? 100) * 100);
  } else if (collect) {
    bits |= ACT.REMOVE; // remove nothing: just collect the fees and send them out
    s.removeBps = 0;
  }
  const convert = get(lane, "convert");
  if (convert) {
    bits |= ACT.SWAP;
    const target = convert.to === "base" ? p.base : p.quote;
    s.swapToToken1 = target.address === p.token1.address;
  }
  if (has(lane, "readd")) {
    bits |= ACT.ADD;
    s.addMode = ADD_SAME;
  }
  if (follow) {
    bits |= ACT.ADD | ACT.REMOVE;
    s.removeBps = 10_000;
    s.addMode = ADD_ONE_SIDED;
    const w = Math.max(1, Math.min(2047, Math.ceil(ticksForPct(follow.widthPct ?? 5) / spacing)));
    s.shape = upper ? w : w << 11; // upper side builds below the price, lower side above it
  }
  s.actions = bits;
  s.repeat = lane.repeat;
  if (lane.repeat && s.checker === CHECK.TICK && !(bits & ACT.ADD)) s.shape = ticksForPct(lane.stepPct ?? 5);
  return s;
}

export function encodeRules(p: Pool, r: Rules): { lower: Side; upper: Side } {
  const out = { lower: offSide(), upper: offSide() };
  const live = (l: Lane) => !!l.trigger && l.actions.length > 0;
  if (live(r.down)) out[sideFor(p, "down", r.down)] = encodeLane(p, r.down, "down");
  if (live(r.up)) out[sideFor(p, "up", r.up)] = encodeLane(p, r.up, "up");
  return out;
}

function decodeSide(p: Pool, s: Side, upper: boolean): Lane {
  const lane = emptyLane();
  if (s.checker === CHECK.OFF) return lane;
  if (s.checker === CHECK.EDGE) lane.trigger = { kind: "leave", bufferPct: round2(pctForTicks(s.value)) };
  else if (s.checker === CHECK.TICK) {
    const other = s.checkPool ? poolByIndex(s.checkPool) : undefined;
    lane.trigger = {
      kind: s.checkPool ? "otherPool" : "price",
      price: priceAtTick(other ?? p, s.value),
      poolIndex: s.checkPool || undefined,
    };
  } else lane.trigger = { kind: "timer", hours: round2(s.value / 60) };

  const keep = (s.actions & ACT.KEEP_FEES) !== 0;
  const remove = (s.actions & ACT.REMOVE) !== 0;
  const add = (s.actions & ACT.ADD) !== 0;
  if (add && s.addMode === ADD_ONE_SIDED) {
    const w = upper ? s.shape & 2047 : (s.shape >> 11) & 2047;
    lane.actions.push({ kind: "follow", widthPct: round2(pctForTicks(w * p.key.tickSpacing)) });
  } else {
    if (!keep) lane.actions.push({ kind: "collect" });
    if (remove && s.removeBps > 0) lane.actions.push({ kind: "withdraw", pct: s.removeBps / 100 });
    if (s.actions & ACT.SWAP) {
      const toToken1 = s.swapToToken1;
      const target = toToken1 ? p.token1 : p.token0;
      lane.actions.push({ kind: "convert", to: target.address === p.base.address ? "base" : "quote" });
    }
    if (add) lane.actions.push({ kind: "readd" });
  }
  lane.actions.sort((x, y) => ACTION_ORDER.indexOf(x.kind) - ACTION_ORDER.indexOf(y.kind));
  lane.repeat = s.repeat;
  if (s.repeat && s.checker === CHECK.TICK && !add) lane.stepPct = round2(pctForTicks(s.shape));
  return lane;
}

export function decodeRules(p: Pool, lower: Side, upper: Side): Rules {
  const r = emptyRules();
  const laneOf = (s: Side, isUpper: boolean): LaneId => {
    const w = s.checker === CHECK.TICK && s.checkPool ? poolByIndex(s.checkPool) ?? p : p;
    return isUpper === w.baseIs0 ? "up" : "down";
  };
  const lo = decodeSide(p, lower, false);
  const up = decodeSide(p, upper, true);
  let loLane = laneOf(lower, false);
  let upLane = laneOf(upper, true);
  if (lower.checker === CHECK.OFF) loLane = upLane === "up" ? "down" : "up";
  if (upper.checker === CHECK.OFF) upLane = loLane === "up" ? "down" : "up";
  if (loLane === upLane) {
    loLane = contractSide(p, "down") === "lower" ? "down" : "up";
    upLane = loLane === "down" ? "up" : "down";
  }
  r[loLane] = lo;
  r[upLane] = up;
  return r;
}

const round2 = (n: number) => Math.round(n * 100) / 100;

// ---------------------------------------------------------------- validation (mirrors ConditionalOrders._validateSide)

export function validate(p: Pool, r: Rules): { down: string[]; up: string[]; general: string[] } {
  const out = { down: [] as string[], up: [] as string[], general: [] as string[] };
  (["down", "up"] as LaneId[]).forEach((id) => {
    const lane = r[id];
    const e = out[id];
    if (!lane.trigger) {
      if (lane.actions.length) e.push("Add a trigger, or these steps never run.");
      return;
    }
    if (lane.actions.length === 0) e.push("Add at least one step after the trigger.");
    const t = lane.trigger;
    const moves = has(lane, "follow");
    if (t.kind === "timer" && !(t.hours! > 0)) e.push("The timer needs a number of hours.");
    if ((t.kind === "price" || t.kind === "otherPool") && !(t.price! > 0)) e.push("Set the trigger price.");
    if (t.kind === "otherPool" && !t.poolIndex) e.push("Choose the pool to watch.");
    if (moves && t.kind !== "leave") e.push("“Follow the price” only works with the “Leaves range” trigger.");
    if (lane.repeat && t.kind === "leave" && !moves)
      e.push("Repeating this would fire again straight away, because the range does not move. Turn repeat off or use “Follow the price”.");
    if (lane.repeat && (t.kind === "price" || t.kind === "otherPool") && !has(lane, "readd") && !(lane.stepPct! > 0))
      e.push("Set how far the trigger price moves after each run.");
    const w = get(lane, "withdraw");
    if (w && !(w.pct! > 0 && w.pct! <= 100)) e.push("Withdraw must be between 1% and 100%.");
  });
  if (!r.down.trigger && !r.up.trigger) out.general.push("Add at least one trigger.");
  if (r.down.trigger && r.up.trigger && sideFor(p, "down", r.down) === sideFor(p, "up", r.up))
    out.general.push("These two triggers watch prices that move the opposite way and would need the same slot. Move one of them to the other lane.");
  return out;
}

export const isValid = (v: ReturnType<typeof validate>) => !v.down.length && !v.up.length && !v.general.length;

// ---------------------------------------------------------------- plain English

export function laneTitle(p: Pool, id: LaneId, lane?: Lane) {
  if (lane?.trigger?.kind === "timer") return "On a timer";
  const w = lane ? watched(p, lane) : p;
  return id === "down" ? `If ${w.base.symbol} falls` : `If ${w.base.symbol} rises`;
}

const every = (hours: number) =>
  hours < 1 ? `${Math.round(hours * 60)} min` : hours % 24 === 0 && hours >= 24 ? `${hours / 24} day${hours === 24 ? "" : "s"}` : `${hours} h`;

export function describeTrigger(p: Pool, id: LaneId, t: Trigger): string {
  const dir = id === "down" ? "below" : "above";
  switch (t.kind) {
    case "leave":
      return t.bufferPct ? `${p.base.symbol} moves ${t.bufferPct}% ${dir} my range` : `${p.base.symbol} leaves my range (${dir})`;
    case "price":
      return `${p.base.symbol} ${id === "down" ? "drops below" : "rises above"} ${fmt(t.price ?? 0)} ${p.quote.symbol}`;
    case "otherPool": {
      const other = t.poolIndex ? poolByIndex(t.poolIndex) : undefined;
      const w = other ?? p;
      return `${w.base.symbol} ${id === "down" ? "drops below" : "rises above"} ${fmt(t.price ?? 0)} ${w.quote.symbol} in ${other?.label ?? "another pool"}`;
    }
    case "timer":
      return `every ${every(t.hours ?? 24)}`;
  }
}

export function describeAction(p: Pool, a: Action): string {
  switch (a.kind) {
    case "collect":
      return "send earned fees to my wallet";
    case "withdraw":
      return a.pct === 100 ? "withdraw everything" : `withdraw ${a.pct}%`;
    case "convert":
      return `convert it all to ${a.to === "base" ? p.base.symbol : p.quote.symbol}`;
    case "readd":
      return "put it back into the same range (compound)";
    case "follow":
      return `move the range next to the new price (${a.widthPct}% wide)`;
  }
}

export function describeLane(p: Pool, id: LaneId, lane: Lane): string | null {
  if (!lane.trigger || !lane.actions.length) return null;
  const steps = lane.actions.map((a) => describeAction(p, a)).join(", then ");
  const when = lane.trigger.kind === "timer" ? `Every ${every(lane.trigger.hours ?? 24)}` : `When ${describeTrigger(p, id, lane.trigger)}`;
  const tail = lane.repeat
    ? lane.trigger.kind === "price" || lane.trigger.kind === "otherPool"
      ? has(lane, "readd")
        ? ". Repeats."
        : `. Repeats, moving the trigger ${lane.stepPct}% further each time.`
      : ". Repeats."
    : ". Runs once.";
  return `${when}: ${steps}${tail}`;
}

// ---------------------------------------------------------------- templates

export type Template = { id: string; name: string; hint: string; build: (p: Pool, price: number) => Rules };

export const TEMPLATES: Template[] = [
  {
    id: "takeProfit",
    name: "Take profit",
    hint: "Withdraw when the price rises out of range",
    build: () => ({ down: emptyLane(), up: { trigger: { kind: "leave", bufferPct: 0 }, actions: [{ kind: "withdraw", pct: 100 }], repeat: false } }),
  },
  {
    id: "stopLoss",
    name: "Stop loss",
    hint: "Exit to the stable token if the price falls",
    build: () => ({
      down: {
        trigger: { kind: "leave", bufferPct: 0 },
        actions: [
          { kind: "withdraw", pct: 100 },
          { kind: "convert", to: "quote" },
        ],
        repeat: false,
      },
      up: emptyLane(),
    }),
  },
  {
    id: "follow",
    name: "Auto re-range",
    hint: "Keep moving the range next to the price",
    build: () => ({
      down: { trigger: { kind: "leave", bufferPct: 1 }, actions: [{ kind: "follow", widthPct: 5 }], repeat: true },
      up: { trigger: { kind: "leave", bufferPct: 1 }, actions: [{ kind: "follow", widthPct: 5 }], repeat: true },
    }),
  },
  {
    id: "compound",
    name: "Auto-compound",
    hint: "Reinvest fees every day",
    build: () => ({ down: emptyLane(), up: { trigger: { kind: "timer", hours: 24 }, actions: [{ kind: "readd" }], repeat: true } }),
  },
  {
    id: "bracket",
    name: "Exit both ways",
    hint: "Take profit above, stop loss below",
    build: (p, price) => ({
      down: {
        trigger: { kind: "price", price: price * 0.9 },
        actions: [
          { kind: "withdraw", pct: 100 },
          { kind: "convert", to: "quote" },
        ],
        repeat: false,
      },
      up: { trigger: { kind: "price", price: price * 1.1 }, actions: [{ kind: "withdraw", pct: 100 }], repeat: false },
    }),
  },
];

/** Sensible defaults when a block is dropped, so nobody has to type every value. */
export function defaultTrigger(kind: TriggerKind, p: Pool, lane: LaneId, price: number, otherPools: Pool[]): Trigger {
  switch (kind) {
    case "leave":
      return { kind, bufferPct: 0 };
    case "price":
      return { kind, price: lane === "down" ? price * 0.95 : price * 1.05 };
    case "otherPool":
      return { kind, price: lane === "down" ? price * 0.95 : price * 1.05, poolIndex: otherPools[0]?.index ?? p.index };
    case "timer":
      return { kind, hours: 24 };
  }
}

export function defaultAction(kind: ActionKind): Action {
  switch (kind) {
    case "withdraw":
      return { kind, pct: 100 };
    case "convert":
      return { kind, to: "quote" };
    case "follow":
      return { kind, widthPct: 5 };
    default:
      return { kind };
  }
}
