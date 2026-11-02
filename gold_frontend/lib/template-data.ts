import type { Article, SignalHistoryData } from "./types";
export type Candle = { t: number; o: number; h: number; l: number; c: number };
export const finite = (v: unknown): v is number =>
  typeof v === "number" && Number.isFinite(v);
export const number = (v: unknown): number | null =>
  v !== null && v !== undefined && v !== "" && Number.isFinite(Number(v))
    ? Number(v)
    : null;
export const fmt = (v: unknown, digits = 2) =>
  finite(v)
    ? v.toLocaleString("en-US", {
        minimumFractionDigits: digits,
        maximumFractionDigits: digits,
      })
    : "—";
export const utc = (v: string | number | null | undefined) => {
  const t = typeof v === "number" ? v : Date.parse(v ?? "");
  return Number.isFinite(t)
    ? new Date(t).toISOString().replace("T", " ").slice(0, 16) + " UTC"
    : "—";
};
export const clamp = (v: number, lo = -1, hi = 1) =>
  Math.max(lo, Math.min(hi, v));
export function normalizeCandles(rows: Candle[]) {
  return [
    ...new Map(
      rows
        .filter(
          (c) =>
            [c.t, c.o, c.h, c.l, c.c].every(finite) &&
            c.t % 900000 === 0 &&
            c.l > 0 &&
            c.h >= Math.max(c.o, c.c) &&
            c.l <= Math.min(c.o, c.c),
        )
        .map((c) => [c.t, c]),
    ).values(),
  ].sort((a, b) => a.t - b.t);
}
export function ema(a: number[], n: number) {
  let e = a[0];
  return a.map(
    (v, i) => (e = i ? (v * 2) / (n + 1) + e * (1 - 2 / (n + 1)) : v),
  );
}
export function indicators(candles: Candle[]) {
  // Never bridge missing M15 bars with an invented candle or indicator path.
  let start = 0;
  candles.forEach((c, i) => {
    if (i && c.t - candles[i - 1].t !== 900000) start = i;
  });
  const cs = candles.slice(start),
    close = cs.map((c) => c.c),
    e20 = ema(close, 20),
    e50 = ema(close, 50);
  const fast = ema(close, 12),
    slow = ema(close, 26),
    macd = fast.map((v, i) => v - slow[i]),
    signal = ema(macd, 9),
    hist = macd.map((v, i) => v - signal[i]);
  const rsi: (number | null)[] = close.map(() => null);
  let gain = 0,
    loss = 0;
  for (let i = 1; i < close.length; i++) {
    const d = close[i] - close[i - 1];
    if (i <= 14) {
      gain += Math.max(d, 0);
      loss += Math.max(-d, 0);
    } else {
      gain = (gain * 13 + Math.max(d, 0)) / 14;
      loss = (loss * 13 + Math.max(-d, 0)) / 14;
    }
    if (i === 14) {
      gain /= 14;
      loss /= 14;
    }
    if (i >= 14)
      rsi[i] =
        gain + loss === 0
          ? 50
          : loss === 0
            ? 100
            : 100 - 100 / (1 + gain / loss);
  }
  const atr =
    cs.length < 15
      ? null
      : cs.slice(-14).reduce((sum, c, i) => {
          const prev = cs[cs.length - 15 + i].c;
          return (
            sum +
            Math.max(c.h - c.l, Math.abs(c.h - prev), Math.abs(c.l - prev))
          );
        }, 0) / 14;
  const pad = (a: (number | null)[]) => [
    ...Array<null>(start).fill(null),
    ...a,
  ];
  return {
    e20: pad(e20),
    e50: pad(e50),
    rsi: pad(rsi),
    macd: pad(macd),
    signal: pad(signal),
    hist: pad(hist),
    atr,
    continuous: cs.length,
  };
}
export type Signal = SignalHistoryData["items"][number];
export const results: Record<string, { label: string; color: string }> = {
  tp_first: { label: "Chạm TP", color: "var(--up)" },
  sl_first: { label: "Chạm SL", color: "var(--down)" },
  ambiguous: { label: "Không xác định", color: "var(--warn)" },
  data_gap: { label: "Chưa kết luận · thiếu nến", color: "var(--neutral)" },
  pending_entry: { label: "Chưa chạm entry", color: "var(--axis)" },
  entry_touched: {
    label: "Đã chạm entry · đang theo dõi",
    color: "var(--neutral)",
  },
  expired_without_entry: {
    label: "Hết hạn · chưa chạm entry",
    color: "var(--axis)",
  },
  cancelled_without_entry: {
    label: "Đã hủy · chưa chạm entry",
    color: "var(--axis)",
  },
  invalidated_before_entry: {
    label: "Vô hiệu trước entry",
    color: "var(--axis)",
  },
  expired_after_entry: {
    label: "Hết cửa sổ · chưa chạm TP/SL",
    color: "var(--neutral)",
  },
  legacy: { label: "Chưa có kết quả mô phỏng", color: "var(--neutral)" },
};
export const resultOf = (s: Signal) =>
  results[s.result.status] ?? {
    label: "Chưa kết luận",
    color: "var(--neutral)",
  };
export function levels(s: Signal) {
  return {
    entry:
      number(s.result.entry_price) ??
      number(s.plan?.current_entry) ??
      number(s.plan?.reference_entry),
    tp: number(s.plan?.take_profit),
    sl: number(s.plan?.stop_loss),
  };
}
export function riskReward(s: Signal) {
  const { entry, tp, sl } = levels(s);
  return entry !== null &&
    tp !== null &&
    sl !== null &&
    Math.abs(entry - sl) > 0
    ? Math.abs(tp - entry) / Math.abs(entry - sl)
    : null;
}
export function simulatedR(s: Signal) {
  return s.result.status === "sl_first"
    ? -1
    : s.result.status === "tp_first"
      ? riskReward(s)
      : 0;
}
export function observed(s: Signal, candles: Candle[]) {
  if (finite(s.result.observed_count))
    return {
      count: clamp(s.result.observed_count, 0, 8),
      hi: number(s.result.observed_high),
      lo: number(s.result.observed_low),
    };
  const from = Date.parse(s.result.observed_from ?? ""),
    through = Date.parse(s.result.observed_through ?? "");
  const count =
    Number.isFinite(from) && Number.isFinite(through)
      ? Math.max(0, Math.min(8, (through - from) / 900000))
      : 0;
  const bars = candles.filter((c) => c.t >= from && c.t + 900000 <= through);
  const complete =
    count > 0 &&
    bars.length === count &&
    bars.every((c, i) => c.t === from + i * 900000);
  return {
    count,
    hi: complete ? Math.max(...bars.map((c) => c.h)) : null,
    lo: complete ? Math.min(...bars.map((c) => c.l)) : null,
  };
}
export function recentNews(articles: Article[], now: number) {
  const d = new Date(now),
    start =
      Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) - 86400000;
  return articles
    .filter((a) => {
      const t = Date.parse(a.published_at ?? "");
      return t >= start && t <= now;
    })
    .sort((a, b) => Date.parse(b.published_at!) - Date.parse(a.published_at!));
}
