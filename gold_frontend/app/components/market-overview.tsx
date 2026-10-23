"use client";

import { useEffect, useRef, useState } from "react";
import { money, num, originLabel, when } from "../../lib/format";
import type { MarketBoard } from "../../lib/types";
import { Sparkline } from "./sparkline";

export function MarketOverview({ board }: { board: MarketBoard }) {
  const price = Number(board.current_price);
  const previous = useRef({ price, origin: board.price_origin, at: board.as_of });
  const [movement, setMovement] = useState<"up" | "down" | null>(null);

  useEffect(() => {
    const last = previous.current;
    previous.current = { price, origin: board.price_origin, at: board.as_of };
    setMovement(null);

    if (
      Number.isFinite(price) && Number.isFinite(last.price) && price !== last.price &&
      board.price_origin === last.origin && board.as_of && last.at &&
      Date.parse(board.as_of) > Date.parse(last.at)
    ) {
      setMovement(price > last.price ? "up" : "down");
      const timeout = window.setTimeout(() => setMovement(null), 900);
      return () => window.clearTimeout(timeout);
    }
  }, [price, board.price_origin, board.as_of]);

  const ticks = board.recent_prices.filter(
    (tick) => tick.price.trim() !== "" && Number.isFinite(Number(tick.price)),
  );
  const prices = ticks.map((tick) => Number(tick.price));
  const first = prices[0];
  const last = prices[prices.length - 1];
  const delta = prices.length > 1 && first > 0 ? last - first : null;
  const percent = delta === null ? null : (delta / first) * 100;
  const simulated = board.price_origin === "synthetic" || board.price_origin === "seed";
  const candles = board.price_origin === "gold_api_ohlc";
  const changeTone = delta === null || delta === 0 ? "" : delta > 0 ? "up-text" : "down-text";

  return (
    <section className="hero" aria-label="Bảng giá XAUUSD">
      <div className="quote">
        <p className="eyebrow">XAUUSD · USD / oz</p>
        <p key={`${board.as_of}-${board.current_price}`} className={`price${movement ? ` price-${movement}` : ""}`}>
          {money(board.current_price)}
        </p>
        <div className="price-meta">
          <span className={simulated ? "pill warn" : "pill"}>{originLabel(board.price_origin)}</span>
          <span>Báo giá lúc {when(board.as_of)}</span>
        </div>
        <p className="quote-cadence">{candles ? "Giá đóng nến M15 dùng cho phân tích" : "Giá cập nhật mỗi 3 phút"} · Bảng giá làm mới mỗi 60 giây</p>
      </div>

      <figure className="quote-chart">
        <figcaption>
          <span>Diễn biến giá · {prices.length} mẫu gần nhất</span>
          <span>{ticks.length > 0 ? `${when(ticks[0].timestamp)} – ${when(ticks[ticks.length - 1].timestamp)}` : "Chưa có lịch sử giá"}</span>
        </figcaption>
        {prices.length > 1 ? <Sparkline values={prices} /> : <p className="empty">Đang chờ thêm báo giá để hiển thị biểu đồ.</p>}
      </figure>

      <dl className="quote-stats">
        <div>
          <dt>Thay đổi trong mẫu</dt>
          <dd className={changeTone}>{percent === null ? "—" : `${percent > 0 ? "+" : ""}${num(percent)}%`}</dd>
          <span>{delta === null ? "Cần ít nhất 2 mẫu giá" : `${delta > 0 ? "+" : ""}${money(delta)}`}</span>
        </div>
        <div>
          <dt>Cao nhất trong mẫu</dt>
          <dd>{prices.length ? money(Math.max(...prices)) : "—"}</dd>
          <span>Trong phạm vi biểu đồ</span>
        </div>
        <div>
          <dt>Thấp nhất trong mẫu</dt>
          <dd>{prices.length ? money(Math.min(...prices)) : "—"}</dd>
          <span>Trong phạm vi biểu đồ</span>
        </div>
        {board.cfd_plan.spread_source === "observed" ? <div>
          <dt>Spread</dt>
          <dd>{money(board.cfd_plan.spread)}</dd>
          <span>Chênh lệch giá mua / bán</span>
        </div> : null}
      </dl>

    </section>
  );
}
