"use client";
import { useEffect, useRef, useState } from "react";
import {
  Candle,
  Signal,
  indicators,
  levels,
  fmt,
  utc,
  clamp,
  finite,
} from "../../../lib/template-data";
export function useWidth(initial = 700) {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(initial);
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const measure = () => setWidth(Math.max(240, Math.floor(node.clientWidth)));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, []);
  return { ref, width };
}
export function CandleChart({
  candles,
  active,
  price,
}: {
  candles: Candle[];
  active?: Signal;
  price: number | null;
}) {
  const { ref, width: W } = useWidth(),
    [range, setRange] = useState(48),
    [table, setTable] = useState(false),
    [hover, setHover] = useState<number | null>(null);
  const ind = indicators(candles),
    start = Math.max(
      0,
      candles.findIndex(
        (c) =>
          c.t >=
          (candles[candles.length - 1]?.t ?? 0) + 900000 - range * 900000,
      ),
    ),
    vis = candles.slice(start),
    n = vis.length;
  const narrow = W < 560,
    m = { l: 8, r: narrow ? 54 : 62, t: 8, b: 22 },
    mh = narrow ? 240 : 300,
    rh = narrow ? 66 : 80,
    ch = rh,
    gap = 18,
    H = m.t + mh + gap + rh + gap + ch + m.b;
  const pw = W - m.l - m.r,
    step = pw / Math.max(n, 1),
    X = (i: number) => m.l + (i + 0.5) * step,
    bw = Math.max(1, Math.min(14, step * 0.62)),
    x1 = W - m.r;
  const lv = active ? levels(active) : null,
    extra = lv ? Object.values(lv).filter(finite) : [];
  if (price !== null) extra.push(price);
  const min = Math.min(...vis.map((c) => c.l), ...extra),
    max = Math.max(...vis.map((c) => c.h), ...extra),
    padding = Math.max((max - min) * 0.05, 0.1),
    lo = min - padding,
    hi = max + padding;
  const Y = (v: number) => m.t + mh - ((v - lo) / (hi - lo)) * mh,
    top2 = m.t + mh + gap,
    top3 = top2 + rh + gap,
    Y2 = (v: number) => top2 + rh - (v / 100) * rh;
  const ma =
      Math.max(
        0.001,
        ...[
          ...ind.hist.slice(start),
          ...ind.macd.slice(start),
          ...ind.signal.slice(start),
        ]
          .filter(finite)
          .map(Math.abs),
      ) * 1.1,
    Y3 = (v: number) => top3 + ch / 2 - ((v / ma) * ch) / 2;
  const path = (a: (number | null)[], y: (v: number) => number) =>
    a
      .slice(start)
      .map((v, i) =>
        v === null
          ? ""
          : `${i === 0 || a[start + i - 1] === null ? "M" : "L"}${X(i)},${y(v)}`,
      )
      .join(" ");
  const signalStart = active
    ? Math.max(
        0,
        vis.findIndex((c) => c.t + 900000 > Date.parse(active.published_at)),
      )
    : 0;
  const showOverlay =
    lv &&
    lv.entry !== null &&
    lv.tp !== null &&
    lv.sl !== null &&
    vis.length &&
    Date.parse(active!.published_at) < vis[n - 1].t + 900000;
  const hovered = hover === null ? null : vis[hover];
  function move(e: React.PointerEvent<SVGSVGElement>) {
    const rect = e.currentTarget.getBoundingClientRect();
    setHover(
      clamp(
        Math.floor((((e.clientX - rect.left) * W) / rect.width - m.l) / step),
        0,
        n - 1,
      ),
    );
  }
  return (
    <>
      <div className="ctl">
        <div className="seg" role="group" aria-label="Khoảng thời gian">
          {[24, 48, 96].map((v) => (
            <button
              key={v}
              aria-pressed={range === v}
              onClick={() => {
                setRange(v);
                setHover(null);
              }}
            >
              {v / 4} giờ
            </button>
          ))}
        </div>
        <div className="seg" role="group" aria-label="Kiểu hiển thị">
          <button aria-pressed={!table} onClick={() => setTable(false)}>
            Biểu đồ
          </button>
          <button aria-pressed={table} onClick={() => setTable(true)}>
            Bảng
          </button>
        </div>
      </div>
      <div className="legend chart-legend">
        {[
          ["Nến tăng", "up"],
          ["Nến giảm", "down"],
          ["EMA 20", "s1"],
          ["EMA 50", "s2"],
          ["RSI 14", "s3"],
          ["Vào lệnh (entry)", "gold"],
        ].map(([name, color], i) => (
          <span key={name}>
            <i
              className={i < 2 ? "sq" : "sw"}
              style={
                i < 2
                  ? { background: `var(--${color})` }
                  : { borderColor: `var(--${color})` }
              }
            />
            {name}
          </span>
        ))}
      </div>
      <div ref={ref} className="chart-container">
        {n === 0 ? (
          <p className="empty">Chưa có nến M15.</p>
        ) : table ? (
          <div className="scroll" tabIndex={0}>
            <table>
              <thead>
                <tr>
                  {["UTC", "O", "H", "L", "C", "RSI 14"].map((t) => (
                    <th key={t}>{t}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {vis
                  .slice()
                  .reverse()
                  .map((c, i) => (
                    <tr key={c.t}>
                      <td className="mono">{utc(c.t)}</td>
                      {[
                        c.o,
                        c.h,
                        c.l,
                        c.c,
                        ind.rsi[candles.length - 1 - i],
                      ].map((v, j) => (
                        <td className="mono r" key={j}>
                          {fmt(v)}
                        </td>
                      ))}
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        ) : (
          <>
            <svg
              viewBox={`0 0 ${W} ${H}`}
              role="img"
              aria-label="Nến M15, EMA 20/50, RSI 14 và MACD 12·26·9"
              onPointerMove={move}
              onPointerDown={move}
              onPointerLeave={() => setHover(null)}
              style={{ touchAction: "pan-y" }}
            >
              <title>Biểu đồ XAUUSD · UTC</title>
              {Array.from(
                { length: 6 },
                (_, i) => lo + ((hi - lo) * i) / 5,
              ).map((v) => (
                <g key={v}>
                  <line className="grid" x1={m.l} x2={x1} y1={Y(v)} y2={Y(v)} />
                  <text className="tx" x={x1 + 6} y={Y(v) + 4}>
                    {fmt(v, 0)}
                  </text>
                </g>
              ))}
              {showOverlay && lv && (
                <>
                  {[
                    ["tp", "TP", "up"],
                    ["entry", "Entry", "gold"],
                    ["sl", "SL", "down"],
                  ].map(([key, label, color]) => {
                    const v = lv[key as keyof typeof lv]!;
                    return (
                      <g key={key}>
                        {key !== "entry" && (
                          <rect
                            x={X(signalStart)}
                            width={Math.max(0, x1 - X(signalStart))}
                            y={Math.min(Y(v), Y(lv.entry!))}
                            height={Math.abs(Y(v) - Y(lv.entry!))}
                            fill={`var(--${color})`}
                            opacity=".09"
                          />
                        )}
                        <line
                          x1={X(signalStart)}
                          x2={x1}
                          y1={Y(v)}
                          y2={Y(v)}
                          stroke={`var(--${color})`}
                          strokeDasharray="5 4"
                        />
                        <text
                          className="tl"
                          x={x1 - 4}
                          y={Y(v) - 5}
                          textAnchor="end"
                        >
                          {label} {fmt(v)}
                        </text>
                      </g>
                    );
                  })}
                </>
              )}
              {vis.map((c, i) => (
                <g className={c.c >= c.o ? "c-up" : "c-down"} key={c.t}>
                  <line x1={X(i)} x2={X(i)} y1={Y(c.h)} y2={Y(c.l)} />
                  <rect
                    x={X(i) - bw / 2}
                    y={Math.min(Y(c.o), Y(c.c))}
                    width={bw}
                    height={Math.max(1, Math.abs(Y(c.o) - Y(c.c)))}
                  />
                </g>
              ))}
              <path className="ln" stroke="var(--s1)" d={path(ind.e20, Y)} />
              <path className="ln" stroke="var(--s2)" d={path(ind.e50, Y)} />
              {price !== null && (
                <g>
                  <line
                    x1={m.l}
                    x2={x1}
                    y1={Y(price)}
                    y2={Y(price)}
                    stroke="var(--ink2)"
                    strokeDasharray="2 3"
                  />
                  <rect
                    x={x1 + 2}
                    y={Y(price) - 9}
                    width={m.r - 4}
                    height={18}
                    rx={3}
                    fill="var(--ink)"
                  />
                  <text
                    className="price-tag"
                    x={x1 + m.r / 2}
                    y={Y(price) + 4}
                    textAnchor="middle"
                  >
                    {price.toFixed(2)}
                  </text>
                </g>
              )}
              <rect
                x={m.l}
                y={Y2(70)}
                width={pw}
                height={Y2(30) - Y2(70)}
                fill="var(--ink)"
                opacity=".045"
              />
              {[30, 70].map((v) => (
                <g key={v}>
                  <line
                    className="grid"
                    x1={m.l}
                    x2={x1}
                    y1={Y2(v)}
                    y2={Y2(v)}
                    strokeDasharray="3 3"
                  />
                  <text className="tx" x={x1 + 6} y={Y2(v) + 4}>
                    {v}
                  </text>
                </g>
              ))}
              <path className="ln" stroke="var(--s3)" d={path(ind.rsi, Y2)} />
              <text className="tl" x={12} y={top2 + 12}>
                RSI 14
              </text>
              <line className="axis" x1={m.l} x2={x1} y1={Y3(0)} y2={Y3(0)} />
              {ind.hist
                .slice(start)
                .map((v, i) =>
                  v === null ? null : (
                    <rect
                      key={i}
                      className={v >= 0 ? "c-up" : "c-down"}
                      x={X(i) - bw / 2}
                      width={bw}
                      y={Math.min(Y3(v), Y3(0))}
                      height={Math.max(0.5, Math.abs(Y3(v) - Y3(0)))}
                    />
                  ),
                )}
              <path className="ln" stroke="var(--s1)" d={path(ind.macd, Y3)} />
              <path
                className="ln"
                stroke="var(--s2)"
                d={path(ind.signal, Y3)}
              />
              <text className="tl" x={12} y={top3 + 12}>
                MACD 12·26·9
              </text>
              {Array.from({ length: narrow ? 4 : 7 }, (_, j) =>
                Math.round((j * (n - 1)) / ((narrow ? 4 : 7) - 1)),
              ).map((i, j) => (
                <text
                  className="tx"
                  key={j}
                  x={X(i)}
                  y={H - 5}
                  textAnchor={
                    j === 0
                      ? "start"
                      : j === (narrow ? 3 : 6)
                        ? "end"
                        : "middle"
                  }
                >
                  {new Date(vis[i].t).toISOString().slice(11, 16)}
                </text>
              ))}
              {hovered && hover !== null && (
                <line
                  className="axis"
                  x1={X(hover)}
                  x2={X(hover)}
                  y1={m.t}
                  y2={top3 + ch}
                  strokeDasharray="3 3"
                />
              )}
            </svg>
            {hovered && hover !== null && (
              <div className="chart-tip" role="status">
                <b>
                  {utc(hovered.t)} ·{" "}
                  {hovered.c >= hovered.o ? "▲ Tăng" : "▼ Giảm"}
                </b>
                <div className="mono">
                  O {fmt(hovered.o)} · H {fmt(hovered.h)}
                  <br />L {fmt(hovered.l)} · C {fmt(hovered.c)}
                  <br />
                  EMA20 {fmt(ind.e20[start + hover])} · EMA50{" "}
                  {fmt(ind.e50[start + hover])}
                  <br />
                  RSI {fmt(ind.rsi[start + hover], 1)} · MACD{" "}
                  {fmt(ind.hist[start + hover])}
                </div>
              </div>
            )}
          </>
        )}
      </div>
      {candles.length > 0 && ind.continuous < 156 && (
        <p className="empty">
          Có {candles.length} nến, {ind.continuous} nến liên tục gần nhất. Cần
          96 nến hiển thị và 60 nến làm ấm; chỉ báo hiện còn thiếu dữ liệu.
        </p>
      )}
      <p className="caption">
        Nến M15 · giờ UTC · di chuột hoặc chạm để xem từng nến. ▲ tăng · ▼ giảm.
      </p>
    </>
  );
}
