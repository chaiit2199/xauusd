"use client";

import { useEffect, useRef, useState } from "react";
import { analyzeMarket, crawlNews, fetchOverview } from "../../lib/api";
import { money, originLabel, when } from "../../lib/format";
import type { CrawlResponse, MarketBoard } from "../../lib/types";
import { AiReport } from "./ai-report";
import { IndicatorGrid } from "./indicator-grid";
import { NewsList } from "./news-list";
import { Sparkline } from "./sparkline";
import { TradeTicket } from "./trade-ticket";

const BOARD_MS = 60_000;

export function Dashboard() {
  const [crawling, setCrawling] = useState(false);
  const [analyzing, setAnalyzing] = useState(false);
  const [loadingBoard, setLoadingBoard] = useState(true);
  const [elapsed, setElapsed] = useState(0);
  const [crawl, setCrawl] = useState<CrawlResponse | null>(null);
  const [board, setBoard] = useState<MarketBoard | null>(null);
  const [insight, setInsight] = useState<string | null>(null);
  const [insightError, setInsightError] = useState<string | null>(null);
  const [cachedAt, setCachedAt] = useState<string | null>(null);
  const [crawlError, setCrawlError] = useState<string | null>(null);
  const [analyzeError, setAnalyzeError] = useState<string | null>(null);
  const [boardError, setBoardError] = useState<string | null>(null);
  const [nextIn, setNextIn] = useState<number | null>(null);
  const analyzingRef = useRef(false);
  const analyzeLock = useRef(false);

  useEffect(() => {
    analyzingRef.current = analyzing;
  }, [analyzing]);

  useEffect(() => {
    let cancelled = false;

    async function loadBoard() {
      try {
        const data = await fetchOverview();
        if (cancelled) return;
        setBoardError(null);
        setBoard(data);
        if (!analyzingRef.current) {
          setInsight(data.ai_insight ?? null);
          setInsightError(data.ai_error ?? null);
          setCachedAt(data.ai_cached_at ?? null);
        }
      } catch (error: unknown) {
        if (!cancelled) {
          setBoardError(
            error instanceof Error ? error.message : "Không tải được bảng giá.",
          );
        }
      } finally {
        if (!cancelled) setLoadingBoard(false);
      }
    }

    void loadBoard();
    const id = window.setInterval(() => void loadBoard(), BOARD_MS);

    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, []);

  useEffect(() => {
    if (!analyzing) {
      setElapsed(0);
      return;
    }

    const started = Date.now();
    const id = window.setInterval(() => {
      setElapsed(Math.floor((Date.now() - started) / 1000));
    }, 250);

    return () => window.clearInterval(id);
  }, [analyzing]);

  useEffect(() => {
    const ttl =
      board?.ai_ttl_seconds ?? board?.analysis_interval_seconds ?? 300;

    function tick() {
      if (!cachedAt) {
        setNextIn(null);
        return;
      }

      const cachedMs = new Date(cachedAt).getTime();
      if (Number.isNaN(cachedMs)) {
        setNextIn(null);
        return;
      }

      const remaining = Math.max(
        0,
        Math.ceil((cachedMs + ttl * 1000 - Date.now()) / 1000),
      );
      setNextIn(remaining);
    }

    tick();
    const id = window.setInterval(tick, 1_000);
    return () => window.clearInterval(id);
  }, [cachedAt, board?.ai_ttl_seconds, board?.analysis_interval_seconds]);

  async function onCrawl() {
    setCrawling(true);
    setCrawlError(null);

    try {
      const result = await crawlNews();
      setCrawl(result);
      setBoard(await fetchOverview());
    } catch (error) {
      setCrawlError(
        error instanceof Error ? error.message : "Không cập nhật được tin.",
      );
    } finally {
      setCrawling(false);
    }
  }

  async function onAnalyze() {
    if (analyzeLock.current) return;
    analyzeLock.current = true;
    analyzingRef.current = true;
    setAnalyzing(true);
    setAnalyzeError(null);

    try {
      const result = await analyzeMarket();
      setBoard(result);
      setInsight(result.ai_insight);
      setInsightError(result.ai_error);
      setCachedAt(result.ai_cached_at);
    } catch (error) {
      setAnalyzeError(
        error instanceof Error ? error.message : "Không lấy được nhận định.",
      );
    } finally {
      analyzingRef.current = false;
      setAnalyzing(false);
      analyzeLock.current = false;
    }
  }

  const view = board;
  const prices = view?.recent_prices.map((tick) => Number(tick.price)) ?? [];
  const first = prices[0];
  const last = prices[prices.length - 1];
  const delta =
    prices.length > 1 && first !== undefined && last !== undefined
      ? last - first
      : null;
  const intervalSeconds =
    view?.analysis_interval_seconds ?? view?.ai_ttl_seconds ?? 300;

  return (
    <main className="page">
      <header className="topbar">
        <div className="brand">
          <span className="mark">Au</span>
          <div>
            <p className="eyebrow">XAUUSD · CFD</p>
            <h1>Bàn lệnh vàng</h1>
          </div>
        </div>
        <div className="actions">
          <button
            type="button"
            className="primary"
            onClick={onCrawl}
            disabled={crawling || loadingBoard}
          >
            {crawling ? "Đang cập nhật tin…" : "Cập nhật tin"}
          </button>
          <button
            type="button"
            onClick={onAnalyze}
            disabled={analyzing || !view}
          >
            {analyzing
              ? `Đang nhận định ${elapsed}s`
              : nextIn != null && nextIn > 0
                ? `Tải lại nhận định · còn ${Math.ceil(nextIn / 60)}p`
                : "Tải lại nhận định"}
          </button>
        </div>
      </header>

      {boardError ? <p className="banner bad">{boardError}</p> : null}
      {crawlError ? <p className="banner bad">{crawlError}</p> : null}
      {analyzeError ? <p className="banner bad">{analyzeError}</p> : null}
      {crawl ? (
        <p className={crawl.status === "success" ? "banner ok" : "banner bad"}>
          {crawl.message}
        </p>
      ) : null}

      {crawl ? (
        <ul className="source-row">
          {crawl.sources.map((source) => (
            <li
              key={source.source}
              className={source.status === "ok" ? "ok" : "bad"}
            >
              <strong>{source.source}</strong>
              <span>
                {source.status === "ok"
                  ? `Lưu ${source.saved}/${source.found}`
                  : source.error || "Lỗi"}
              </span>
            </li>
          ))}
        </ul>
      ) : null}

      {loadingBoard && !view ? (
        <p className="banner">Đang tải giá và tin mới nhất.</p>
      ) : null}

      {view ? (
        <>
          {view.warmup ? (
            <p className="banner warn">
              {view.warmup_detail ||
                "Đang warmup chỉ báo: cần cửa sổ ~5 ngày giá theo giờ (SMA20/EMA50/ATR). Seed chỉ để khởi tạo lịch sử — phiếu lệnh khóa «Không giao dịch» đến khi có đủ giá thị trường thật."}
              {typeof view.live_price_ticks === "number"
                ? ` Tick live hiện có: ${view.live_price_ticks}/${view.price_ticks_5d}.`
                : null}
            </p>
          ) : null}

          {view.events.length > 0 ? (
            <p className="banner warn">
              Tin USD tác động mạnh:{" "}
              {view.events
                .map((event) => `${event.title} (${when(event.time)})`)
                .join(" · ")}
              . Không vào lệnh trong 30 phút trước và sau giờ ra tin.
            </p>
          ) : null}

          {view.news_digest ? (
            <p className="banner">{view.news_digest}</p>
          ) : null}

          <TradeTicket plan={view.cfd_plan} aiAction={view.ai_action} />

          <section className="hero">
            <div>
              <p className="eyebrow">Giá hiện tại</p>
              <p className="price">{money(view.current_price)}</p>
              <p className="price-meta">
                <span
                  className={
                    view.price_origin === "synthetic" ||
                    view.price_origin === "seed"
                      ? "pill warn"
                      : "pill ok"
                  }
                >
                  {originLabel(view.price_origin)}
                </span>
                <span>{when(view.as_of)}</span>
                {delta !== null ? (
                  <span className={delta >= 0 ? "up-text" : "down-text"}>
                    {delta >= 0 ? "+" : ""}
                    {money(delta)} trên biểu đồ
                  </span>
                ) : null}
              </p>
              <p className="basis">
                {view.price_ticks_5d} tick / 5 ngày
                {typeof view.live_price_ticks === "number"
                  ? ` · ${view.live_price_ticks} live`
                  : ""}{" "}
                · {view.hourly_samples} mẫu giờ · {view.indicator_basis}
              </p>
            </div>
            <Sparkline values={prices} />
          </section>

          <IndicatorGrid indicators={view.indicators_10} alerts={view.alerts} />

          <AiReport
            insight={analyzing ? null : insight}
            error={analyzing ? null : insightError}
            pending={analyzing}
            elapsed={elapsed}
            cachedAt={analyzing ? null : cachedAt}
            newsTone={view.news_tone}
            nextInSeconds={analyzing ? null : nextIn}
            intervalSeconds={intervalSeconds}
          />
          <div className="news-band">
            <NewsList
              title="Tin mới nhất"
              articles={view.news_3d}
              empty="Chưa có tin trong 3 ngày. Bấm Cập nhật tin."
            />
          </div>
        </>
      ) : null}
    </main>
  );
}
