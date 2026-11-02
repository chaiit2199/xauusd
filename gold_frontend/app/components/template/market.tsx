"use client";
import type { MarketBoard } from "../../../lib/types";
import {
  Candle,
  Signal,
  fmt,
  utc,
  number,
  indicators,
  clamp,
  levels,
  riskReward,
  observed,
  resultOf,
} from "../../../lib/template-data";
import { CandleChart } from "./candle-chart";
export type LoadState = { loading: boolean; error: string | null };
export function BlockState({
  loading,
  error,
}: {
  loading: boolean;
  error: string | null;
}) {
  return (
    <>
      {loading && (
        <p className="caption" role="status">
          Đang cập nhật…
        </p>
      )}
      {error && (
        <p className="error" role="alert">
          {error} Dữ liệu cũ (nếu có) chưa được cập nhật.
        </p>
      )}
    </>
  );
}
export function Header({
  newsBusy,
  marketBusy,
  onNews,
  onMarket,
}: {
  newsBusy: boolean;
  marketBusy: boolean;
  onNews: () => void;
  onMarket: () => void;
}) {
  return (
    <header className="top">
      <div className="brand">
        <div className="mark" aria-hidden="true">
          Au
        </div>
        <div>
          <b>Vàng · XAUUSD</b>
          <span>Gold trading · CFD</span>
        </div>
      </div>
      <div className="actions">
        <button className="btn" disabled={newsBusy} onClick={onNews}>
          {newsBusy ? "Đang cập nhật tin…" : "Cập nhật tin"}
        </button>
        <button
          className="btn primary"
          disabled={marketBusy}
          onClick={onMarket}
        >
          {marketBusy ? "Đang cập nhật nhận định…" : "Cập nhật nhận định"}
        </button>
      </div>
    </header>
  );
}
export function PriceHero({
  board,
  candles,
  active,
  state,
  candleState,
  now,
}: {
  board: MarketBoard | null;
  candles: Candle[];
  active?: Signal;
  state: LoadState;
  candleState: LoadState;
  now: number;
}) {
  const price = number(board?.current_price),
    bars = candles.filter(
      (c) =>
        c.t >= Math.floor(now / 900000) * 900000 - 86400000 &&
        c.t < Math.floor(now / 900000) * 900000,
    ),
    full =
      bars.length === 96 &&
      bars.every((c, i) => !i || c.t - bars[i - 1].t === 900000),
    hi = bars.length ? Math.max(...bars.map((c) => c.h)) : null,
    lo = bars.length ? Math.min(...bars.map((c) => c.l)) : null;
  const change = price !== null && full ? price - bars[0].o : null,
    pos =
      price !== null && hi !== null && lo !== null && hi > lo
        ? clamp((price - lo) / (hi - lo), 0, 1) * 100
        : 50;
  return (
    <section className="card">
      <h3>Thị trường vàng · XAUUSD · USD / oz</h3>
      <BlockState {...state} />
      <div className="quote quote-spacing">
        <div>
          <div className="price mono">{fmt(price)}</div>
          <div
            className={`chg ${change === null ? "" : change >= 0 ? "up" : "down"}`}
          >
            {change !== null
              ? `${change >= 0 ? "▲ +" : "▼ "}${fmt(change)} · ${fmt((change / bars[0].o) * 100)}% / 24h`
              : "Chưa đủ dữ liệu biến động 24h"}
          </div>
          <p className="caption">Báo giá: {utc(board?.as_of)}</p>
        </div>
        <div className="range">
          <div className="lbl">
            <span>
              Thấp {full ? "24h" : "đã có"} <b className="mono">{fmt(lo)}</b>
            </span>
            <span>
              Cao {full ? "24h" : "đã có"} <b className="mono">{fmt(hi)}</b>
            </span>
          </div>
          <div className="track">
            <i style={{ left: `${pos}%` }} />
          </div>
          <div className="lbl">
            <span>
              Biên độ{" "}
              <b className="mono">
                {fmt(hi !== null && lo !== null ? hi - lo : null)}
              </b>
            </span>
            <span>
              ATR 14 · M15{" "}
              <b className="mono">{fmt(indicators(candles).atr)}</b>
            </span>
          </div>
        </div>
      </div>
      <BlockState {...candleState} />
      <CandleChart candles={candles} active={active} price={price} />
    </section>
  );
}
export function BiasGauge({
  candles,
  board,
  state,
}: {
  candles: Candle[];
  board: MarketBoard | null;
  state: LoadState;
}) {
  const v = indicators(candles),
    n = candles.length - 1,
    last = candles[n],
    atr = v.atr,
    window = candles.slice(-96),
    hi = Math.max(...window.map((c) => c.h)),
    lo = Math.min(...window.map((c) => c.l));
  const ready = v.continuous >= 60 && atr !== null && atr > 0;
  const factors = [
    {
      name: "Xu hướng EMA 20/50",
      value: ready ? clamp((v.e20[n]! - v.e50[n]!) / (atr! * 1.5)) : null,
      note: `EMA20 ${fmt(v.e20[n])} so với EMA50 ${fmt(v.e50[n])}`,
    },
    {
      name: "Động lượng MACD",
      value: ready ? clamp(v.hist[n]! / (atr! * 0.35)) : null,
      note: `Histogram ${fmt(v.hist[n])}`,
    },
    {
      name: "RSI 14",
      value: ready && v.rsi[n] !== null ? clamp((v.rsi[n]! - 50) / 25) : null,
      note: `RSI ${fmt(v.rsi[n], 1)} (50 là trung tính)`,
    },
    {
      name: "Vị trí trong biên 24h",
      value:
        v.continuous >= 96 && last && hi > lo
          ? clamp((last.c - (hi + lo) / 2) / ((hi - lo) / 2))
          : null,
      note: "Theo 96 nến M15 liên tục gần nhất",
    },
    {
      name: "Tâm lý tin tức",
      value: null,
      note: "Chưa có dữ liệu sentiment từ API",
    },
  ];
  const available = factors.filter((f) => f.value !== null),
    score =
      available.length === 4
        ? Math.round(
            (available.reduce((sum, f) => sum + f.value!, 0) / 4) * 100,
          )
        : null;
  const point = (angle: number, r: number) => [
    130 + r * Math.cos((angle * Math.PI) / 180),
    124 - r * Math.sin((angle * Math.PI) / 180),
  ];
  const needle = point(90 - (score ?? 0) * 0.9, 75);
  return (
    <section className="card">
      <h3>Nhận định tổng hợp</h3>
      <BlockState {...state} />
      <div className="gwrap">
        <svg
          viewBox="0 0 260 146"
          role="img"
          aria-label={
            score === null
              ? "Chưa đủ dữ liệu nhận định"
              : `Điểm kỹ thuật ${score}`
          }
        >
          <title>Điểm kỹ thuật · không thay đổi rule vào lệnh</title>
          {["down", "s2", "neutral", "s3", "up"].map((color, i) => {
            const a = point(180 - i * 36 - 1.5, 96),
              b = point(180 - (i + 1) * 36 + 1.5, 96);
            return (
              <path
                key={color}
                d={`M${a} A96 96 0 0 1 ${b}`}
                fill="none"
                stroke={`var(--${color})`}
                strokeWidth={16}
              />
            );
          })}
          {score !== null && (
            <>
              <line
                x1={130}
                y1={124}
                x2={needle[0]}
                y2={needle[1]}
                stroke="var(--ink)"
                strokeWidth={3}
              />
              <circle cx={130} cy={124} r={5} fill="var(--ink)" />
            </>
          )}
          <text className="tx" x={130} y={18} textAnchor="middle">
            0
          </text>
          <text className="tx" x={22} y={140}>
            −100
          </text>
          <text className="tx" x={206} y={140}>
            +100
          </text>
        </svg>
        <div className="gval">
          <b className="mono">
            {score === null ? "—" : `${score > 0 ? "+" : ""}${score}`}
          </b>
          <span>
            {score === null
              ? "Chưa đủ dữ liệu"
              : score >= 60
                ? "Tăng mạnh"
                : score >= 20
                  ? "Nghiêng tăng"
                  : score > -20
                    ? "Trung lập"
                    : score > -60
                      ? "Nghiêng giảm"
                      : "Giảm mạnh"}
          </span>
        </div>
      </div>
      <div className="factors">
        {factors.map((f) => (
          <div className="f" key={f.name} title={f.note} tabIndex={0}>
            <span className="nm">{f.name}</span>
            <div className="bar">
              {f.value !== null && (
                <i
                  style={{
                    background: `var(--${f.value > 0.15 ? "up" : f.value < -0.15 ? "down" : "neutral"})`,
                    left: `${f.value >= 0 ? 50 : 50 + f.value * 50}%`,
                    width: `${Math.abs(f.value) * 50}%`,
                  }}
                />
              )}
            </div>
            <span className="w">
              {f.value === null
                ? "Chưa có dữ liệu"
                : f.value > 0.15
                  ? "▲ Tăng"
                  : f.value < -0.15
                    ? "▼ Giảm"
                    : "● Trung lập"}
            </span>
          </div>
        ))}
      </div>
      <p className="caption">
        Điểm hiển thị là trung bình 4 yếu tố kỹ thuật có đủ dữ liệu; chưa bao
        gồm tin tức. Không phải điểm AI hoặc điều kiện vào lệnh.
      </p>
      {board?.ai_insight && (
        <details>
          <summary>Nhận định AI · {utc(board.ai_cached_at)}</summary>
          <p className="ai-copy">{board.ai_insight}</p>
        </details>
      )}
      {board?.ai_error && <p className="caption">AI: {board.ai_error}</p>}
    </section>
  );
}
export function SignalActive({
  signal,
  candles,
  state,
}: {
  signal?: Signal;
  candles: Candle[];
  state: LoadState;
}) {
  const lv = signal ? levels(signal) : null,
    rr = signal ? riskReward(signal) : null,
    ob = signal ? observed(signal, candles) : null;
  return (
    <section className="card">
      <h3>Tín hiệu đang theo dõi</h3>
      <BlockState {...state} />
      {signal && lv ? (
        <>
          <div className="signal-heading">
            <span className={`side ${signal.side}`}>
              {signal.side === "buy" ? "▲ BUY" : "▼ SELL"}
            </span>
            <span className="mono caption">{utc(signal.published_at)}</span>
          </div>
          <div className="sigbox">
            {[
              ["Entry", lv.entry],
              ["TP", lv.tp],
              ["SL", lv.sl],
            ].map(([label, value]) => (
              <div key={String(label)}>
                <small>{label}</small>
                <b className="mono">{fmt(value)}</b>
              </div>
            ))}
          </div>
          {signal.plan?.entry_zone && (
            <p className="caption">
              Vùng entry mô phỏng: {fmt(signal.plan.entry_zone.low)}–
              {fmt(signal.plan.entry_zone.high)}
            </p>
          )}
          <div className="rr">
            <i
              style={{
                background: "var(--down)",
                width: `${rr === null ? 50 : 100 / (1 + rr)}%`,
              }}
            />
            <i style={{ background: "var(--up)", flex: 1 }} />
          </div>
          <div className="rrl">
            <span>Rủi ro 1R</span>
            <span>Lợi nhuận mục tiêu {fmt(rr)}R</span>
          </div>
          <div
            className="prog"
            aria-label={`Đã theo dõi ${ob?.count ?? 0}/8 nến`}
          >
            {Array.from({ length: 8 }, (_, i) => (
              <i key={i} className={i < (ob?.count ?? 0) ? "on" : ""} />
            ))}
          </div>
          <p className="caption">
            {ob?.count ?? 0}/8 nến M15 đã theo dõi · {resultOf(signal).label}
          </p>
          <p className="caption">Hết cửa sổ: {utc(signal.horizon_at)}</p>
        </>
      ) : (
        !state.loading && (
          <p className="empty">Chưa có tín hiệu đang theo dõi.</p>
        )
      )}
    </section>
  );
}
