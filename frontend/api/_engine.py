"""Alucard backtest engine: replays real Uniswap swaps against a position with rules.

Semantics follow src/ConditionalOrders.sol run by run:
  * a side fires when its condition holds after a swap (EDGE: tick past edge +- value, TICK: a tick level, possibly
    in another pool, TIME: lastRun + minutes)
  * a keeper executes it `delay` seconds later, at the price after the first swap at or past that time, and only if
    the condition still holds then (the contract re-checks)
  * remove (removeBps) -> keeper reserve (maxKeeperFeeBps of what came out) -> fees kept or paid out (bit 0)
    -> optional swap (stops at the slippage limit, skipped if already past it) -> optional add (same range, or
    one-sided next to the price) -> side updated (lastRun, TICK step, or cleared) -> keeper paid -> close if no
    liquidity is left or both sides are off -> refused if the same side would fire again at once (WouldRefire)

Fees use the validated swap replay of lp_study (lp_sim.swap_shares): each swap pays a unit of liquidity
overlap_fraction / pool_liquidity of its LP fee. Valid while the position is small next to the pool.

Not modelled, stated in the output: the position's own swaps do not move later prices; price manipulation; MEV.

Only numpy. Pure functions, so tests in lp_study can import this file directly.
"""
from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass, field, replace

import numpy as np

LN = math.log(1.0001)
MIN_TICK, MAX_TICK = -887272, 887272
BPS = 10_000
CHECK_OFF, CHECK_EDGE, CHECK_TICK, CHECK_TIME = 0, 1, 2, 3
ACT_KEEP_FEES, ACT_REMOVE, ACT_SWAP, ACT_ADD = 1, 2, 4, 8
ADD_SAME, ADD_ONE_SIDED = 0, 1
MAX_RUNS = 5000

QUOTE_RANK = ["USDC", "USDT", "DAI", "WETH", "ETH", "WBTC", "LINK"]
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_data")
_CACHE: dict[str, "Series"] = {}


# ---------------------------------------------------------------- data


@dataclass
class Series:
    key: str
    dec0: int
    dec1: int
    fee: float
    spacing: int
    token0: str
    token1: str
    ts: np.ndarray
    sp0: np.ndarray
    sp1: np.ndarray
    lpre: np.ndarray
    lpost: np.ndarray
    fee_raw: np.ndarray
    t0in: np.ndarray
    tick: np.ndarray  # tick after each swap

    @property
    def base_is0(self) -> bool:
        """The base is the token people price ("1 WETH = x USDC"); same ranking as the frontend's lib/pools.ts."""
        rank = lambda t: QUOTE_RANK.index(t) if t in QUOTE_RANK else len(QUOTE_RANK)  # noqa: E731
        return rank(self.token0) > rank(self.token1)

    def price(self, sp):
        """Base price in quote (USDC per WETH for the recorded pools) from a raw sqrt price."""
        t1per0 = np.square(sp) * 10.0 ** (self.dec0 - self.dec1)
        return t1per0 if self.base_is0 else 1.0 / t1per0

    def tick_at_price(self, price: float) -> float:
        t1per0 = price if self.base_is0 else 1.0 / price
        return math.log(t1per0 * 10.0 ** (self.dec1 - self.dec0)) / LN


def load(key: str) -> Series:
    if key in _CACHE:
        return _CACHE[key]
    z = np.load(os.path.join(DATA_DIR, f"{key}.npz"))
    m = json.loads(str(z["meta"]))
    sp1 = z["sp1"]
    s = Series(
        key=key, dec0=m["dec0"], dec1=m["dec1"], fee=m["fee"], spacing=m["spacing"], token0=m["token0"], token1=m["token1"],
        ts=z["ts"], sp0=z["sp0"], sp1=sp1, lpre=z["lpre"], lpost=z["lpost"], fee_raw=z["fee"], t0in=z["t0in"].astype(bool),
        tick=np.floor(2.0 * np.log(sp1) / LN).astype(np.int64),
    )
    _CACHE[key] = s
    return s


POOL_LABELS = {"eth_usdc_030": "ETH/USDC 0.30% (Ethereum mainnet)", "eth_usdc_005": "ETH/USDC 0.05% (Ethereum mainnet)"}
OTHER_POOL = {"eth_usdc_030": "eth_usdc_005", "eth_usdc_005": "eth_usdc_030"}


# ---------------------------------------------------------------- Uniswap math (raw units, as in lp_study/univ3.py)


def sqrt_at(tick) -> float:
    return 1.0001 ** (tick / 2.0)


def amounts(L: float, sp: float, sa: float, sb: float) -> tuple[float, float]:
    spc = min(max(sp, sa), sb)
    return L * (1.0 / spc - 1.0 / sb), L * (spc - sa)


def liquidity_for(sp: float, sa: float, sb: float, a0: float, a1: float) -> float:
    if sp <= sa:
        return a0 / (1 / sa - 1 / sb)
    if sp >= sb:
        return a1 / (sb - sa)
    return min(a0 / (1 / sp - 1 / sb), a1 / (sp - sa))


def overlap_frac(sp0, sp1, sa, sb):
    lo_p, hi_p = np.minimum(sp0, sp1), np.maximum(sp0, sp1)
    lo, hi = np.maximum(lo_p, sa), np.minimum(hi_p, sb)
    up = sp1 > sp0
    ok = (hi > lo) & (hi_p > lo_p)
    with np.errstate(divide="ignore", invalid="ignore"):
        num = np.where(up, hi - lo, 1.0 / lo - 1.0 / hi)
        den = np.where(up, hi_p - lo_p, 1.0 / lo_p - 1.0 / hi_p)
        return np.clip(np.where(ok, num / den, 0.0), 0.0, 1.0)


def floor_to(t: float, s: int) -> int:
    return int(math.floor(t / s) * s)


def min_usable(s: int) -> int:
    return math.ceil(MIN_TICK / s) * s


def max_usable(s: int) -> int:
    return math.floor(MAX_TICK / s) * s


def ticks_for_pct(pct: float) -> int:
    return max(0, round(math.log(1 + pct / 100) / LN))


# ---------------------------------------------------------------- rules: UI model -> contract sides (port of frontend lib/rules.ts)


@dataclass
class Side:
    edge: int = 0
    checker: int = 0
    value: int = 0
    check_pool: str | None = None  # TICK: key of the pool whose tick is read (None = own pool)
    actions: int = 0
    remove_bps: int = 0
    swap_to_token1: bool = False
    add_mode: int = 0
    repeat: bool = False
    shape: int = 0
    last_run: float = 0.0
    blocked: bool = False  # a run was refused (WouldRefire): wait until the condition is false again


def contract_side(base_is0: bool, lane: str) -> str:
    return "upper" if (lane == "up") == base_is0 else "lower"


def encode_lane(s: Series, lane_id: str, lane: dict, entry_price: float, watched: Series) -> tuple[str, Side]:
    """lane: {trigger: {kind, bufferPct?, pricePct?, price?, hours?}, actions: [{kind, pct?, to?, widthPct?}], repeat, stepPct?}
    Price triggers come as pricePct (relative to the entry price), because absolute prices of today do not apply to
    a past window; `price` (absolute) is accepted too, for tests."""
    side_name = contract_side(watched.base_is0, lane_id)
    d = Side()
    t = lane.get("trigger")
    acts = {a["kind"]: a for a in lane.get("actions", [])}
    if not t or not acts:
        return side_name, d
    upper = side_name == "upper"
    follow = acts.get("follow")
    if t["kind"] == "leave":
        d.checker = CHECK_EDGE
        d.value = ticks_for_pct(t.get("bufferPct") or 0)
        if follow and lane.get("repeat"):
            d.value = max(d.value, s.spacing)
    elif t["kind"] in ("price", "otherPool"):
        d.checker = CHECK_TICK
        price = t["price"] if "price" in t and t["price"] is not None else entry_price * (1 + (t.get("pricePct") or 0) / 100)
        d.value = round(watched.tick_at_price(price))
        d.check_pool = watched.key if watched.key != s.key else None
    else:
        d.checker = CHECK_TIME
        d.value = max(1, round((t.get("hours") or 24) * 60))

    collect = "collect" in acts
    bits = 0 if collect else ACT_KEEP_FEES
    if "withdraw" in acts:
        bits |= ACT_REMOVE
        d.remove_bps = round((acts["withdraw"].get("pct") or 100) * 100)
    elif collect:
        bits |= ACT_REMOVE
        d.remove_bps = 0
    if "convert" in acts:
        bits |= ACT_SWAP
        to_base = acts["convert"].get("to") == "base"
        target_is0 = s.base_is0 == to_base
        d.swap_to_token1 = not target_is0
    if "readd" in acts:
        bits |= ACT_ADD
        d.add_mode = ADD_SAME
    if follow:
        bits |= ACT_ADD | ACT_REMOVE
        d.remove_bps = BPS
        d.add_mode = ADD_ONE_SIDED
        w = max(1, min(2047, math.ceil(ticks_for_pct(follow.get("widthPct") or 5) / s.spacing)))
        d.shape = w if upper else (w << 11)
    d.actions = bits
    d.repeat = bool(lane.get("repeat"))
    if d.repeat and d.checker == CHECK_TICK and not (bits & ACT_ADD):
        d.shape = ticks_for_pct(lane.get("stepPct") or 5)
    return side_name, d


# ---------------------------------------------------------------- simulation


@dataclass
class Params:
    keeper_fee_bps: int = 10
    slippage_steps: int = 10  # x10 ticks, like Order.maxSlippage
    delay_s: float = 12.0
    keeper_cost_usd: float = 0.01  # gas cost of one run in USD
    keeper_mode: str = "gas"  # "gas": paid gas cost (native-ETH pools); "ceiling": takes the whole reserve (ERC20 pools)


@dataclass
class State:
    L: float = 0.0
    tl: int = 0
    tu: int = 0
    f0: float = 0.0  # uncollected fees of the position, raw
    f1: float = 0.0
    w0: float = 0.0  # owner's wallet (everything paid out), raw
    w1: float = 0.0
    sides: dict = field(default_factory=dict)
    open: bool = True
    keeper_usd: float = 0.0
    fees_usd: float = 0.0  # fees earned, valued when collected
    runs: int = 0
    in_range_s: float = 0.0
    live_s: float = 0.0


class Sim:
    def __init__(self, s: Series, i0: int, i1: int, p: Params, other: Series | None):
        self.s, self.i0, self.i1, self.p, self.other = s, i0, i1, p, other
        self.events: list[dict] = []
        self.samples: dict[int, float] = {}
        self.ranges: dict[int, tuple[float, float]] = {}
        # other pool's tick at each of our swaps (for TICK checks on another pool)
        if other is not None:
            idx = np.clip(np.searchsorted(other.ts, s.ts[i0:i1], side="right") - 1, 0, len(other.ts) - 1)
            self.other_tick = np.full(len(s.ts), 0, dtype=np.int64)
            self.other_tick[i0:i1] = other.tick[idx]
        else:
            self.other_tick = None

    def usd(self, a0: float, a1: float, sp: float) -> float:
        s = self.s
        price = float(s.price(sp))
        h0, h1 = a0 / 10**s.dec0, a1 / 10**s.dec1
        # value in quote units: the quote token is worth 1, the base token `price`
        return h0 + h1 * price if not s.base_is0 else h0 * price + h1

    # ---- conditions
    def _tick_series(self, d: Side) -> np.ndarray:
        if d.checker == CHECK_TICK and d.check_pool and self.other_tick is not None:
            return self.other_tick
        return self.s.tick

    def cond_at(self, st: State, name: str, d: Side, k: int) -> bool:
        if d.checker == CHECK_TIME:
            return self.s.ts[k] >= d.last_run + d.value * 60
        t = int(self._tick_series(d)[k])
        if d.checker == CHECK_EDGE:
            return t >= st.tu + d.value if name == "upper" else t < st.tl - d.value
        if d.checker == CHECK_TICK:
            return t >= d.value if name == "upper" else t < d.value
        return False

    def first_true(self, st: State, name: str, d: Side, i: int) -> int | None:
        """First index >= i where the side's condition holds (searches in growing chunks)."""
        end = self.i1
        step = 4096
        while i < end:
            j = min(end, i + step)
            if d.checker == CHECK_TIME:
                m = self.s.ts[i:j] >= d.last_run + d.value * 60
            else:
                t = self._tick_series(d)[i:j]
                if d.checker == CHECK_EDGE:
                    m = t >= st.tu + d.value if name == "upper" else t < st.tl - d.value
                else:
                    m = t >= d.value if name == "upper" else t < d.value
            if d.blocked:  # wait for the condition to turn false first
                false_at = np.flatnonzero(~m)
                if len(false_at) == 0:
                    i = j
                    step *= 4
                    continue
                d.blocked = False
                i = i + int(false_at[0])
                continue
            hit = np.flatnonzero(m)
            if len(hit):
                return i + int(hit[0])
            i = j
            step *= 4
        return None

    # ---- fees and time in range for swaps (i, k]
    def accrue(self, st: State, i: int, k: int) -> None:
        if k <= i:
            return
        s = self.s
        sl = slice(i + 1, k + 1)
        if st.L > 0:
            sa, sb = sqrt_at(st.tl), sqrt_at(st.tu)
            sp0, sp1 = s.sp0[sl], s.sp1[sl]
            frac = overlap_frac(sp0, sp1, sa, sb)
            start_in = (sp0 >= sa) & (sp0 <= sb)
            # The position's own liquidity is part of the pool, so it can never earn more than the whole fee. This also
            # bounds swaps that sweep through near-empty ticks, where the pool's liquidity reads close to zero.
            share = st.L * frac / (np.where(start_in, s.lpre[sl], s.lpost[sl]) + st.L)
            fee = s.fee_raw[sl]
            t0 = s.t0in[sl]
            c0 = np.cumsum(np.where(t0, share * fee, 0.0))
            c1 = np.cumsum(np.where(t0, 0.0, share * fee))
            # samples inside this stretch
            for idx in [x for x in self.samples_wanted if i < x <= k]:
                r = idx - (i + 1)
                a0, a1 = amounts(st.L, s.sp1[idx], sa, sb)
                self.samples[idx] = self.usd(st.w0 + a0 + st.f0 + c0[r], st.w1 + a1 + st.f1 + c1[r], s.sp1[idx])
                self.ranges[idx] = (st.tl, st.tu)
            st.f0 += float(c0[-1])
            st.f1 += float(c1[-1])
            dur = np.diff(s.ts[i : k + 1])
            inr = (sp1 >= sa) & (sp1 <= sb)
            st.in_range_s += float(np.sum(dur * inr))
            st.live_s += float(np.sum(dur))
        else:
            for idx in [x for x in self.samples_wanted if i < x <= k]:
                self.samples[idx] = self.usd(st.w0, st.w1, s.sp1[idx])

    # ---- one run of one side at swap k
    def execute(self, st: State, name: str, k: int) -> State | None:
        s, p = self.s, self.p
        d = st.sides[name]
        sp = float(s.sp1[k])
        tick = int(s.tick[k])
        sa, sb = sqrt_at(st.tl), sqrt_at(st.tu)
        new = replace(st, sides={n: replace(x) for n, x in st.sides.items()})
        nd = new.sides[name]

        ref_tick = tick
        if d.checker == CHECK_EDGE:
            ref_tick = st.tu + d.value if name == "upper" else st.tl - d.value
        elif d.checker == CHECK_TICK:
            ref_tick = d.value

        remove_l = new.L * d.remove_bps / BPS if d.actions & ACT_REMOVE else 0.0
        a0, a1 = amounts(remove_l, sp, sa, sb)
        f0, f1 = new.f0, new.f1  # every modifyLiquidity collects all fees
        new.fees_usd += self.usd(f0, f1, sp)
        out0, out1 = a0 + f0, a1 + f1
        new.L -= remove_l
        new.f0 = new.f1 = 0.0
        res0, res1 = out0 * p.keeper_fee_bps / BPS, out1 * p.keeper_fee_bps / BPS
        w0, w1 = out0 - res0, out1 - res1
        if not d.actions & ACT_KEEP_FEES:
            w0 -= min(f0, w0)
            w1 -= min(f1, w1)
        pay0, pay1 = out0 - res0 - w0, out1 - res1 - w1  # fees sent to the owner

        note = []
        if d.actions & ACT_SWAP:
            w0, w1, swapped = self.swap(w0, w1, d.swap_to_token1, sp, ref_tick, k)
            note.append(swapped)
        if d.actions & ACT_ADD:
            s_ = s.spacing
            if d.add_mode == ADD_ONE_SIDED:
                fl = floor_to(tick, s_)
                if name == "upper":
                    ntu, ntl = fl, fl - (d.shape & 2047) * s_
                    use0, use1 = 0.0, w1
                else:
                    ntl = fl + s_
                    ntu, use0, use1 = ntl + ((d.shape >> 11) & 2047) * s_, w0, 0.0
                if ntl >= min_usable(s_) and ntu <= max_usable(s_) and ntu > ntl:
                    nsa, nsb = sqrt_at(ntl), sqrt_at(ntu)
                    la = liquidity_for(sp, nsa, nsb, use0, use1) * 0.9999
                    if la > 0:
                        c0, c1 = amounts(la, sp, nsa, nsb)
                        w0, w1 = w0 - c0, w1 - c1
                        new.L, new.tl, new.tu = new.L + la, ntl, ntu
                        nd_lo, nd_hi = sorted((float(s.price(nsa)), float(s.price(nsb))))
                        note.append(f"new range {fmt(nd_lo)}-{fmt(nd_hi)}")
            else:
                la = liquidity_for(sp, sa, sb, w0, w1) * 0.9999 if (w0 > 0 or w1 > 0) else 0.0
                if la > 0:
                    c0, c1 = amounts(la, sp, sa, sb)
                    w0, w1 = w0 - c0, w1 - c1
                    new.L += la
                    note.append(f"re-added {fmt(self.usd(c0, c1, sp))} USD")

        nd.last_run = float(s.ts[k])
        if d.repeat:
            if d.checker == CHECK_TICK and not d.actions & ACT_ADD:
                nd.value = d.value + (d.shape if name == "upper" else -d.shape)
        else:
            new.sides[name] = Side(edge=d.edge)

        # keeper pay out of the reserve
        res_usd = self.usd(res0, res1, sp)
        if p.keeper_mode == "ceiling" or res_usd <= 0:
            frac = 1.0
        else:
            frac = min(1.0, p.keeper_cost_usd / res_usd)
        new.keeper_usd += res_usd * frac
        back0, back1 = res0 * (1 - frac), res1 * (1 - frac)

        # what was not re-added goes to the owner
        new.w0 += w0 + pay0 + back0
        new.w1 += w1 + pay1 + back1
        new.runs += 1

        both_off = all(x.checker == CHECK_OFF for x in new.sides.values())
        if new.L <= 0 or both_off:
            nsa, nsb = sqrt_at(new.tl), sqrt_at(new.tu)
            r0, r1 = amounts(new.L, sp, nsa, nsb)
            new.w0 += r0
            new.w1 += r1
            new.L = 0.0
            new.open = False
            note.append("position closed")
        else:
            again = new.sides[name]
            if again.checker != CHECK_OFF and self.cond_at(new, name, again, k):
                return None  # WouldRefire: the contract refuses the run
        self.events.append({"t": float(s.ts[k]), "price": float(s.price(sp)), "side": name, "note": note})
        return new

    def swap(self, w0: float, w1: float, zero_for_one: bool, sp: float, ref_tick: int, k: int):
        """Swap all of one token at the pool's liquidity at that moment, stopping at the slippage limit."""
        s, p = self.s, self.p
        amount_in = w0 if zero_for_one else w1
        if amount_in <= 0:
            return w0, w1, "nothing to convert"
        slip = p.slippage_steps * 10
        limit_tick = max(MIN_TICK + 1, min(MAX_TICK - 1, ref_tick - slip if zero_for_one else ref_tick + slip))
        sl = sqrt_at(limit_tick)
        if (zero_for_one and sl >= sp) or (not zero_for_one and sl <= sp):
            return w0, w1, "convert skipped: price already past the limit"
        L = float(s.lpost[k])
        net = amount_in * (1 - s.fee)
        if zero_for_one:  # token0 in, price falls
            cap = L * (1 / sl - 1 / sp)
            used = min(net, cap)
            sp_new = L * sp / (L + used * sp)
            out = L * (sp - sp_new)
            gross = used / (1 - s.fee)
            return w0 - gross, w1 + out, ("converted" if used == net else "partly converted (limit)")
        cap = L * (sl - sp)
        used = min(net, cap)
        sp_new = sp + used / L
        out = L * (1 / sp - 1 / sp_new)
        gross = used / (1 - s.fee)
        return w0 + out, w1 - gross, ("converted" if used == net else "partly converted (limit)")

    # ---- whole run
    def run(self, st: State, sample_idx: list[int]) -> State:
        self.samples_wanted = sample_idx
        i = self.i0
        while st.open and st.runs < MAX_RUNS:
            best = None
            for name, d in st.sides.items():
                if d.checker == CHECK_OFF:
                    continue
                j = self.first_true(st, name, d, i + 1)
                if j is not None and (best is None or j < best[0]):
                    best = (j, name)
            if best is None:
                break
            j, name = best
            k = int(np.searchsorted(self.s.ts, self.s.ts[j] + self.p.delay_s, side="left"))
            k = max(k, j)
            if k >= self.i1:
                break
            self.accrue(st, i, k)
            i = k
            d = st.sides[name]
            if not self.cond_at(st, name, d, k):
                continue  # the price moved back before a keeper ran it
            nxt = self.execute(st, name, k)
            if nxt is None:
                st.sides[name].blocked = True
                continue
            st = nxt
        self.accrue(st, i, self.i1 - 1)
        return st


def fmt(x: float) -> str:
    return f"{x:,.0f}" if abs(x) >= 100 else f"{x:,.4g}"


# ---------------------------------------------------------------- entry point


def run(req: dict) -> dict:
    key = req.get("pool", "eth_usdc_030")
    if key not in POOL_LABELS:
        raise ValueError(f"unknown pool {key}")
    s = load(key)
    other = None
    lanes = req.get("rules") or {}
    if any((lanes.get(l) or {}).get("trigger", {}) and (lanes.get(l) or {}).get("trigger", {}).get("kind") == "otherPool" for l in ("down", "up")):
        other = load(OTHER_POOL[key])

    t_first, t_last = float(s.ts[0]), float(s.ts[-1])
    days = float(req.get("days", 30))
    start = float(req.get("start", t_first))
    start = min(max(start, t_first), t_last - 86400)
    end = min(start + days * 86400, t_last)
    i0 = int(np.searchsorted(s.ts, start))
    i1 = int(np.searchsorted(s.ts, end))
    if i1 - i0 < 10:
        raise ValueError("window too short")

    p = Params(
        keeper_fee_bps=int(req.get("keeperFeeBps", 10)),
        slippage_steps=max(1, round(float(req.get("slippagePct", 1)) * 10)),
        delay_s=float(req.get("delaySec", 12)),
        keeper_cost_usd=float(req.get("keeperCostUsd", 0.01)),
        keeper_mode=req.get("keeperMode", "gas"),
    )
    deposit = float(req.get("depositUsd", 10_000))

    # entry: range around the price before the first swap of the window
    sp_in = float(s.sp0[i0])
    entry = float(s.price(sp_in))
    rng = req.get("range") or {"loPct": -5, "hiPct": 5}
    spc = s.spacing
    if rng.get("full"):
        tl, tu = min_usable(spc), max_usable(spc)
    else:
        a = s.tick_at_price(entry * (1 + rng["loPct"] / 100))
        b = s.tick_at_price(entry * (1 + rng["hiPct"] / 100))
        tl, tu = max(min_usable(spc), floor_to(min(a, b), spc)), min(max_usable(spc), floor_to(max(a, b), spc) + spc)
    sa, sb = sqrt_at(tl), sqrt_at(tu)

    def start_state() -> State:
        st = State(tl=tl, tu=tu)
        unit0, unit1 = amounts(1.0, sp_in, sa, sb)
        unit_usd = Sim(s, i0, i1, p, None).usd(unit0, unit1, sp_in)
        st.L = deposit / unit_usd
        return st

    # samples for the chart
    n_samples = 240
    sample_idx = sorted(set(np.linspace(i0 + 1, i1 - 1, n_samples).astype(int).tolist()))

    # strategy with rules
    st = start_state()
    a0_in, a1_in = amounts(st.L, sp_in, sa, sb)
    sides = {"lower": Side(edge=tl), "upper": Side(edge=tu)}
    for lane_id in ("down", "up"):
        lane = lanes.get(lane_id) or {}
        watched = other if (lane.get("trigger") or {}).get("kind") == "otherPool" and other is not None else s
        name, d = encode_lane(s, lane_id, lane, entry if watched is s else float(watched.price(watched.sp1[max(0, int(np.searchsorted(watched.ts, start)) - 1)])), watched)
        if d.checker != CHECK_OFF:
            d.last_run = start
            sides[name] = d
    st.sides = sides
    sim = Sim(s, i0, i1, p, other)
    final = sim.run(st, sample_idx)

    # the same position without rules
    base = start_state()
    base.sides = {"lower": Side(edge=tl), "upper": Side(edge=tu)}
    plain = Sim(s, i0, i1, p, None)
    plain_final = plain.run(base, sample_idx)

    sp_end = float(s.sp1[i1 - 1])
    end_price = float(s.price(sp_end))

    def value(st_: State, sim_: Sim) -> float:
        a0, a1 = amounts(st_.L, sp_end, sqrt_at(st_.tl), sqrt_at(st_.tu)) if st_.L > 0 else (0.0, 0.0)
        return sim_.usd(st_.w0 + a0 + st_.f0, st_.w1 + a1 + st_.f1, sp_end)

    v_rules, v_plain = value(final, sim), value(plain_final, plain)
    v_hold = sim.usd(a0_in, a1_in, sp_end)
    fees_rules = final.fees_usd + sim.usd(final.f0, final.f1, sp_end)
    fees_plain = plain_final.fees_usd + plain.usd(plain_final.f0, plain_final.f1, sp_end)

    # chart series
    t, price, strat, pl, hold, lo, hi = [], [], [], [], [], [], []
    for idx in sample_idx:
        spx = float(s.sp1[idx])
        t.append(float(s.ts[idx]))
        price.append(float(s.price(spx)))
        strat.append(sim.samples.get(idx, None))
        pl.append(plain.samples.get(idx, None))
        hold.append(sim.usd(a0_in, a1_in, spx))
        r = sim.ranges.get(idx)
        if r:
            x, y = sorted((float(s.price(sqrt_at(r[0]))), float(s.price(sqrt_at(r[1])))))
            lo.append(x)
            hi.append(y)
        else:
            lo.append(None)
            hi.append(None)
    # carry the last known value forward where a sample fell after the position closed
    for arr in (strat, pl):
        last = deposit
        for n, v in enumerate(arr):
            if v is None:
                arr[n] = last
            else:
                last = v

    lo_p, hi_p = sorted((float(s.price(sa)), float(s.price(sb))))
    return {
        "pool": key,
        "poolLabel": POOL_LABELS[key],
        "start": float(s.ts[i0]),
        "end": float(s.ts[i1 - 1]),
        "dataFrom": t_first,
        "dataTo": t_last,
        "swaps": i1 - i0,
        "entryPrice": entry,
        "endPrice": end_price,
        "deposit": deposit,
        "range": {"lo": lo_p, "hi": hi_p, "full": bool(rng.get("full"))},
        "rules": {
            "final": v_rules,
            "fees": fees_rules,
            "keeperPaid": final.keeper_usd,
            "runs": final.runs,
            "timeInRange": final.in_range_s / max(final.live_s, 1.0) if final.live_s else 0.0,
            "closed": not final.open,
        },
        "noRules": {"final": v_plain, "fees": fees_plain, "timeInRange": plain_final.in_range_s / max(plain_final.live_s, 1.0)},
        "hold": {"final": v_hold},
        "usdc": {"final": deposit},
        "series": {"t": t, "price": price, "rules": strat, "noRules": pl, "hold": hold, "lo": lo, "hi": hi},
        "events": sim.events[:500],
        "assumptions": {
            "keeperDelaySec": p.delay_s,
            "keeperCostUsd": p.keeper_cost_usd,
            "keeperMode": p.keeper_mode,
            "keeperFeeBps": p.keeper_fee_bps,
            "slippagePct": p.slippage_steps / 10,
        },
        "caveats": [
            "Real swaps from the recorded window; past results do not predict future ones.",
            "Your own swaps (Convert) do not move later prices in the replay, and they use the pool's liquidity at that moment.",
            "Fees assume your position is small next to the pool.",
            "A keeper runs each rule a fixed delay after its condition is met; price manipulation and MEV are not modelled.",
        ],
    }


def run_windows(req: dict, window_days: int = 30, every_days: int = 7) -> dict:
    """The same rules over every window_days-long window starting every every_days."""
    s = load(req.get("pool", "eth_usdc_030"))
    t0, t1 = float(s.ts[0]), float(s.ts[-1])
    out = []
    start = t0
    while start + window_days * 86400 <= t1:
        r = run({**req, "start": start, "days": window_days})
        out.append({"start": r["start"], "rules": r["rules"]["final"], "noRules": r["noRules"]["final"], "hold": r["hold"]["final"], "runs": r["rules"]["runs"]})
        start += every_days * 86400
    beat_plain = sum(1 for x in out if x["rules"] > x["noRules"])
    beat_hold = sum(1 for x in out if x["rules"] > x["hold"])
    diffs = sorted(x["rules"] - x["noRules"] for x in out)
    return {
        "windows": out,
        "count": len(out),
        "beatNoRules": beat_plain,
        "beatHold": beat_hold,
        "medianVsNoRules": diffs[len(diffs) // 2] if diffs else 0.0,
        "worstVsNoRules": diffs[0] if diffs else 0.0,
        "bestVsNoRules": diffs[-1] if diffs else 0.0,
        "windowDays": window_days,
        "everyDays": every_days,
    }
