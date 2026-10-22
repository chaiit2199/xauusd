"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { analyzeMarket, crawlNews, fetchOverview } from "../../lib/api";
import { expireAnalysis } from "../../lib/analysis-window";
import { when } from "../../lib/format";
import type { CrawlResponse, MarketBoard } from "../../lib/types";
import { AiReport } from "./ai-report";
import { IndicatorGrid } from "./indicator-grid";
import { NewsList } from "./news-list";
import { MarketOverview } from "./market-overview";
import { TradeTicket } from "./trade-ticket";
import { SiteHeader, type DeskPage } from "./site-header";
import { LotCalculator } from "./lot-calculator";
import { MarketContext } from "./market-context";
import { EconomicEvents } from "./economic-events";

const BOARD_MS = 60_000;

export function Dashboard({ page = "overview", initialSide = "buy" }: { page?: DeskPage; initialSide?: "buy" | "sell" }) {
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
      board?.ai_ttl_seconds ?? board?.analysis_interval_seconds ?? 900;

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

      const scheduledMs = board?.ai_next_analysis_at
        ? Date.parse(board.ai_next_analysis_at)
        : (Math.floor(cachedMs / (ttl * 1000)) + 1) * ttl * 1000;
      const remaining = Math.max(
        0,
        Math.ceil((scheduledMs - Date.now()) / 1000),
      );
      setNextIn(Number.isFinite(remaining) ? remaining : 0);
    }

    tick();
    const id = window.setInterval(tick, 1_000);
    return () => window.clearInterval(id);
  }, [cachedAt, board?.ai_ttl_seconds, board?.analysis_interval_seconds, board?.ai_next_analysis_at]);

  async function onCrawl() {
    setCrawling(true);
    setCrawlError(null);

    try {
      const result = await crawlNews();
      setCrawl(result);
      setBoard(await fetchOverview());
      setBoardError(null);
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
      setBoardError(null);
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

  const view = board ? expireAnalysis(board, Date.now()) : null;
  const expired = view !== board;
  const intervalSeconds =
    view?.analysis_interval_seconds ?? view?.ai_ttl_seconds ?? 900;

  return (
    <div className="page">
      <SiteHeader active={page}>
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
              ? `Đang phân tích · ${elapsed} giây`
              : nextIn != null && nextIn > 0
                ? `Cập nhật nhận định · còn ${Math.ceil(nextIn / 60)} phút`
                : "Cập nhật nhận định"}
          </button>
      </SiteHeader>
      <main id="content">
        <div className="section-intro">
          <p className="eyebrow">XAUUSD · CFD</p>
          <h1>{page === "overview" ? "Thị trường vàng" : page === "trading" ? "Kế hoạch giao dịch" : "Tin tức & phân tích"}</h1>
          <p>{page === "overview" ? "Giá vàng, tín hiệu và thông tin thị trường." : page === "trading" ? "H1 định hướng · M15 xác nhận điểm vào sau khi đóng nến." : "Theo dõi tin kinh tế và các sự kiện ảnh hưởng đến vàng."}</p>
        </div>

      {boardError ? <p className="banner bad" role="alert">Chưa thể cập nhật bảng giá. {view ? "Đang hiển thị báo giá gần nhất. " : ""}{boardError}</p> : null}
      {crawlError ? <p className="banner bad" role="alert">{crawlError}</p> : null}
      {analyzeError ? <p className="banner bad" role="alert">{analyzeError}</p> : null}
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

      {page === "trading" ? <LotCalculator initialSide={initialSide} currentPrice={view && !["seed", "synthetic"].includes(view.price_origin) ? view.current_price : undefined} /> : null}

      {loadingBoard && !view && page === "news" ? <p className="banner" role="status">Đang cập nhật tin thị trường…</p> : null}
      {loadingBoard && !view && page !== "news" ? (
        <section className="hero loading-quote" aria-busy="true" aria-label="Bảng giá XAUUSD">
          <p className="eyebrow">XAUUSD · USD / oz</p>
          <p className="price" aria-hidden="true">—</p>
          <p className="empty" role="status">Đang cập nhật báo giá XAUUSD…</p>
        </section>
      ) : null}

      {view ? (
        <>
          {page !== "news" ? <MarketOverview board={view} /> : null}
          {page === "overview" ? <>
            <MarketContext />
            <div className="trade-shortcuts">
              <span>Lập kế hoạch XAUUSD</span>
              <Link className="trade-link buy" href="/giao-dich?side=buy">Mua</Link>
              <Link className="trade-link sell" href="/giao-dich?side=sell">Bán</Link>
            </div>
          </> : null}

          {page !== "news" && view.warmup ? (
            <p className="banner warn">
              {view.warmup_detail ||
                "Đang khởi tạo chỉ báo H1. Chờ đủ dữ liệu thị trường để đánh giá điều kiện giao dịch."}
              {typeof view.live_price_ticks === "number"
                ? ` Số mẫu giá thị trường: ${view.live_price_ticks}/${view.price_ticks_5d}.`
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

          {view.m15_setup ? <section className="panel">
            <div className="panel-head"><h2>Xác nhận M15</h2><p>Mốc đóng nến {when(view.m15_setup.candle_closed_at)}</p></div>
            <p className="empty">{expired ? view.ai_error : view.m15_setup.reason}</p>
            <p className="basis">H1 định hướng · Chỉ đánh giá nến đã đóng · Mốc :00 / :15 / :30 / :45</p>
            {view.m15_setup.divergence !== "none" ? <p className="banner warn">Phân kỳ RSI {view.m15_setup.divergence === "bearish" ? "giảm" : "tăng"} · Cảnh báo, chưa phải lệnh.</p> : null}
          </section> : null}

          {page !== "news" ? <TradeTicket plan={view.cfd_plan} aiAction={view.ai_action} /> : null}

          {page === "trading" ? <IndicatorGrid indicators={view.indicators_10} alerts={view.alerts} /> : null}
          {page === "news" ? <EconomicEvents events={view.events} /> : null}

          {page !== "trading" ? <div className="news-band">
            <NewsList
              title="Tin mới nhất"
              filterable={page === "news"}
              articles={view.news_3d}
              empty="Chưa có tin trong 3 ngày gần nhất. Chọn “Cập nhật tin” để đồng bộ."
            />
          </div> : null}

          <AiReport
            insight={analyzing || expired ? null : insight}
            error={analyzing ? null : expired ? view.ai_error ?? null : insightError}
            pending={analyzing}
            elapsed={elapsed}
            cachedAt={analyzing ? null : cachedAt}
            newsTone={view.news_tone}
            nextInSeconds={analyzing ? null : nextIn}
            intervalSeconds={intervalSeconds}
          />

        </>
      ) : null}
      </main>
      <footer className="site-footer"><span>Vàng · XAUUSD</span><span>Phân tích thị trường & kế hoạch giao dịch</span></footer>
    </div>
  );
}
