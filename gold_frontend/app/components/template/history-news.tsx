"use client";
import type { Article } from "../../../lib/types";
import {
  Candle,
  Signal,
  fmt,
  utc,
  levels,
  riskReward,
  simulatedR,
  resultOf,
  observed,
} from "../../../lib/template-data";
import { BlockState, LoadState } from "./market";
import { useWidth } from "./candle-chart";
export function SignalStats({
  signals,
  state,
}: {
  signals: Signal[];
  state: LoadState;
}) {
  const { ref, width: W } = useWidth(600),
    groups = new Map<string, { label: string; color: string; count: number }>();
  signals.forEach((s) => {
    const r = resultOf(s),
      old = groups.get(r.label);
    groups.set(r.label, { ...r, count: (old?.count ?? 0) + 1 });
  });
  const rows = [...signals].reverse(),
    rs = rows.map(simulatedR);
  let cumulative = 0;
  const cum = rs.map((v) => {
    cumulative += v ?? 0;
    return cumulative;
  });
  const H = 210,
    m = { l: 42, r: 12, t: 20, b: 25 },
    lo = Math.min(-1, ...rs.map((v) => v ?? 0), ...cum) - 0.3,
    hi = Math.max(1, ...rs.map((v) => v ?? 0), ...cum) + 0.3,
    Y = (v: number) => m.t + ((hi - v) / (hi - lo)) * (H - m.t - m.b),
    X = (i: number) =>
      m.l + ((i + 0.5) * (W - m.l - m.r)) / Math.max(rows.length, 1),
    bw = Math.min(30, ((W - m.l - m.r) / Math.max(rows.length, 1)) * 0.5);
  let offset = 0;
  return (
    <div className="two">
      <div className="card">
        <h3>Kết quả theo loại</h3>
        <BlockState {...state} />
        {!signals.length ? (
          <p className="empty">Chưa có tín hiệu để thống kê.</p>
        ) : (
          <div className="donut">
            <svg
              viewBox="0 0 160 160"
              role="img"
              aria-label={`${signals.length} tín hiệu mô phỏng`}
            >
              <circle
                cx={80}
                cy={80}
                r={57}
                fill="none"
                stroke="var(--line)"
                strokeWidth={20}
              />
              {[...groups.values()].map((g) => {
                const length = (g.count / signals.length) * 358.14,
                  o = offset;
                offset += length;
                return (
                  <circle
                    key={g.label}
                    cx={80}
                    cy={80}
                    r={57}
                    fill="none"
                    stroke={g.color}
                    strokeWidth={20}
                    strokeDasharray={`${Math.max(0, length - 3)} ${358.14 - Math.max(0, length - 3)}`}
                    strokeDashoffset={-o}
                    transform="rotate(-90 80 80)"
                  >
                    <title>
                      {g.label}: {g.count}
                    </title>
                  </circle>
                );
              })}
              <text x={80} y={80} textAnchor="middle" className="donut-total">
                {signals.length}
              </text>
              <text x={80} y={99} textAnchor="middle" className="tx">
                tín hiệu
              </text>
            </svg>
            <div className="dl">
              {[...groups.values()].map((g) => (
                <div key={g.label}>
                  <span className="pill">
                    <i style={{ background: g.color }} />
                  </span>
                  {g.label}
                  <b className="mono">{g.count}</b>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
      <div className="card">
        <h3>R mô phỏng theo từng tín hiệu</h3>
        <BlockState {...state} />
        <div className="legend chart-legend">
          <span>
            <i className="sq" style={{ background: "var(--up)" }} />
            Chạm TP
          </span>
          <span>
            <i className="sq" style={{ background: "var(--down)" }} />
            Chạm SL (−1R)
          </span>
          <span>
            <i className="sw" style={{ borderColor: "var(--s1)" }} />R lũy kế
          </span>
        </div>
        <div className="ch" ref={ref}>
          {rows.length ? (
            <svg
              viewBox={`0 0 ${W} ${H}`}
              role="img"
              aria-label="R mô phỏng và R lũy kế"
            >
              <title>
                Kết quả mô phỏng theo backend, không phải lợi nhuận thực tế
              </title>
              {Array.from(
                { length: 5 },
                (_, i) => lo + ((hi - lo) * i) / 4,
              ).map((v) => (
                <g key={v}>
                  <line
                    className="grid"
                    x1={m.l}
                    x2={W - m.r}
                    y1={Y(v)}
                    y2={Y(v)}
                  />
                  <text
                    className="tx"
                    x={m.l - 5}
                    y={Y(v) + 4}
                    textAnchor="end"
                  >
                    {fmt(v, 1)}R
                  </text>
                </g>
              ))}
              <line
                className="axis"
                x1={m.l}
                x2={W - m.r}
                y1={Y(0)}
                y2={Y(0)}
              />
              {rows.map((s, i) => (
                <g key={s.setup_id}>
                  <rect
                    x={X(i) - bw / 2}
                    y={Math.min(Y(rs[i] ?? 0), Y(0))}
                    width={bw}
                    height={Math.max(2, Math.abs(Y(rs[i] ?? 0) - Y(0)))}
                    fill={resultOf(s).color}
                  >
                    <title>
                      {utc(s.published_at)} · {resultOf(s).label} · {fmt(rs[i])}
                      R
                    </title>
                  </rect>
                  {(i === 0 || i === rows.length - 1) && (
                    <text
                      x={X(i)}
                      y={H - 5}
                      textAnchor={i === 0 ? "start" : "end"}
                      className="tx"
                    >
                      {utc(s.published_at).slice(5, 16)}
                    </text>
                  )}
                </g>
              ))}
              <polyline
                className="ln"
                stroke="var(--s1)"
                points={cum.map((v, i) => `${X(i)},${Y(v)}`).join(" ")}
              />
              {cum.map((v, i) => (
                <circle key={i} cx={X(i)} cy={Y(v)} r={3.5} fill="var(--s1)">
                  <title>Lũy kế {fmt(v)}R</title>
                </circle>
              ))}
            </svg>
          ) : (
            <p className="empty">Chưa có kết quả mô phỏng.</p>
          )}
        </div>
        {rs.some((v) => v === null) && (
          <p className="caption">
            Một số kết quả thiếu entry/SL/TP để tính R; không cộng vào lũy kế.
          </p>
        )}
      </div>
    </div>
  );
}
export function SignalTable({
  signals,
  candles,
  state,
}: {
  signals: Signal[];
  candles: Candle[];
  state: LoadState;
}) {
  return (
    <div className="card history-table">
      <BlockState {...state} />
      <div className="scroll" tabIndex={0} aria-label="Bảng lịch sử tín hiệu">
        <table>
          <thead>
            <tr>
              {[
                "Thời gian UTC",
                "Hướng",
                "Entry / vùng",
                "TP",
                "SL",
                "R:R",
                "Kết quả mô phỏng",
                "R",
                "Biên độ theo dõi",
              ].map((t) => (
                <th key={t}>{t}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {signals.map((s) => {
              const l = levels(s),
                o = observed(s, candles),
                r = resultOf(s),
                bounds = [l.entry, l.tp, l.sl, o.hi, o.lo].filter(
                  (v): v is number => v !== null,
                ),
                low = Math.min(...bounds),
                high = Math.max(...bounds),
                X = (v: number) =>
                  4 + ((v - low) / Math.max(high - low, 0.01)) * 182;
              return (
                <tr key={s.setup_id}>
                  <td className="mono">{utc(s.published_at)}</td>
                  <td>
                    <span className={`side ${s.side}`}>
                      {s.side === "buy" ? "▲ BUY" : "▼ SELL"}
                    </span>
                  </td>
                  <td className="mono r">
                    {fmt(l.entry)}
                    {s.plan?.entry_zone && (
                      <small className="cell-sub">
                        {fmt(s.plan.entry_zone.low)}–
                        {fmt(s.plan.entry_zone.high)}
                      </small>
                    )}
                  </td>
                  {[l.tp, l.sl, riskReward(s)].map((v, i) => (
                    <td key={i} className="mono r">
                      {fmt(v)}
                    </td>
                  ))}
                  <td>
                    <span className="pill">
                      <i style={{ background: r.color }} />
                      {r.label}
                    </span>
                  </td>
                  <td className="mono r">{fmt(simulatedR(s))}</td>
                  <td>
                    {o.hi !== null && o.lo !== null ? (
                      <svg
                        width="190"
                        height="34"
                        role="img"
                        aria-label={`Cao ${fmt(o.hi)}, thấp ${fmt(o.lo)}`}
                      >
                        <line
                          x1={X(o.lo)}
                          x2={X(o.hi)}
                          y1={15}
                          y2={15}
                          stroke="var(--axis)"
                          strokeWidth={6}
                        />
                        {[
                          [l.entry, "gold"],
                          [l.tp, "up"],
                          [l.sl, "down"],
                        ].map(([v, c], i) =>
                          typeof v === "number" ? (
                            <line
                              key={i}
                              x1={X(v)}
                              x2={X(v)}
                              y1={7}
                              y2={23}
                              stroke={`var(--${c})`}
                              strokeWidth={2}
                            />
                          ) : null,
                        )}
                        <title>
                          Hi {fmt(o.hi)} · Lo {fmt(o.lo)} · Entry/TP/SL
                        </title>
                      </svg>
                    ) : (
                      <span className="caption">Chưa đủ nến để tính hi/lo</span>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {!signals.length && !state.loading && (
        <p className="empty">Chưa có tín hiệu.</p>
      )}
      <details>
        <summary>Cách tính kết quả</summary>
        <p>
          Giữ nguyên mô phỏng vùng entry của backend: xét nến M15 trọn vẹn sau
          thời điểm phát tín hiệu, tối đa 2 giờ. Chạm entry không chứng minh
          khớp lệnh; kết quả là mô phỏng, không phải lợi nhuận thực tế.
        </p>
        <p>
          Cùng nến chạm TP và SL, hoặc không xác định được thứ tự entry/thoát:
          không xác định. Thiếu nến: chưa kết luận. Kết quả hủy/hết hạn được giữ
          nguyên, không chuyển thành thắng hoặc thua.
        </p>
        <p>
          R hiển thị: chạm TP = |TP − entry| / |entry − SL|; chạm SL = −1; các
          kết quả khác = 0. Dùng entry mô phỏng nếu đã có, nếu chưa thì dùng
          entry lưu trong plan. Đây là R thô, chưa trừ chi phí; không thay thế
          estimated_net_r của backend. Hi/lo chỉ hiển thị khi đủ nến đã quan
          sát.
        </p>
      </details>
    </div>
  );
}
export function NewsTimeline({
  articles,
  state,
  now,
}: {
  articles: Article[];
  state: LoadState;
  now: number;
}) {
  const { ref, width: W } = useWidth(1000),
    d = new Date(now),
    start =
      Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) - 86400000,
    end = start + 2 * 86400000,
    X = (t: number) => 42 + ((t - start) / (end - start)) * (W - 62);
  return (
    <div className="card">
      <h3>Dòng tin theo thời gian và tâm lý</h3>
      <BlockState {...state} />
      <div className="legend chart-legend">
        <span>
          <i className="sq" style={{ background: "var(--neutral)" }} />
          Tin đã xuất bản · chưa có dữ liệu tâm lý
        </span>
      </div>
      <div className="ch" ref={ref}>
        {articles.length ? (
          <svg
            viewBox={`0 0 ${W} 150`}
            role="img"
            aria-label="Thời điểm xuất bản tin theo UTC; chưa có sentiment"
          >
            <title>Tin thật theo thời gian UTC, không gán điểm cảm xúc</title>
            <line className="axis" x1={42} x2={W - 20} y1={80} y2={80} />
            {(W < 560 ? [0, 24, 48] : [0, 12, 24, 36, 48]).map((h) => (
              <g key={h}>
                <line
                  className="grid"
                  x1={X(start + h * 3600000)}
                  x2={X(start + h * 3600000)}
                  y1={15}
                  y2={110}
                />
                <text
                  className="tx"
                  x={X(start + h * 3600000)}
                  y={132}
                  textAnchor={h === 0 ? "start" : h === 48 ? "end" : "middle"}
                >
                  {W < 560
                    ? utc(start + h * 3600000).slice(5, 10)
                    : utc(start + h * 3600000).slice(5, 16)}
                </text>
              </g>
            ))}
            {articles.map((a, i) => (
              <circle
                key={a.url + i}
                cx={X(Date.parse(a.published_at!))}
                cy={80}
                r={5}
                fill="var(--neutral)"
                stroke="var(--surface)"
                strokeWidth={1}
              >
                <title>
                  {utc(a.published_at)} · {a.title_vi || a.title} · Chưa có
                  sentiment
                </title>
              </circle>
            ))}
          </svg>
        ) : (
          <p className="empty">
            {state.loading
              ? "Đang tải tin…"
              : "Chưa có tin hôm nay và hôm qua theo UTC"}
          </p>
        )}
      </div>
      <p className="caption">
        Vị trí dọc không biểu thị cảm xúc; API chưa cung cấp sentiment.
      </p>
    </div>
  );
}
export function NewsList({
  articles,
  state,
}: {
  articles: Article[];
  state: LoadState;
}) {
  return (
    <div className="card nl">
      <BlockState {...state} />
      {articles.length
        ? articles.map((a, i) => {
            let url: string | null = null;
            try {
              const u = new URL(a.url);
              if (["https:", "http:"].includes(u.protocol)) url = u.href;
            } catch {}
            return (
              <article className="ni" key={a.url + i}>
                <time className="mono" dateTime={a.published_at ?? undefined}>
                  {utc(a.published_at)}
                </time>
                <div>
                  <em>{a.source} · Chưa có chủ đề</em>
                  {url ? (
                    <a href={url} target="_blank" rel="noreferrer">
                      {a.title_vi || a.title}
                    </a>
                  ) : (
                    a.title_vi || a.title
                  )}
                </div>
                <span className="caption">Chưa có dữ liệu tâm lý</span>
              </article>
            );
          })
        : !state.loading && (
            <p className="empty">Chưa có tin hôm nay và hôm qua theo UTC</p>
          )}
    </div>
  );
}
