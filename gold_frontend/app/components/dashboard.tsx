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
  const analyzingRef = useRef(false);

  useEffect(() => {
    analyzingRef.current = analyzing;
  }, [analyzing]);

  useEffect(() => {
    let cancelled = false;

    async function loadBoard() {
      try {
        const data = await fetchOverview();
        if (cancelled) return;
        setBoard(data);
        if (!analyzingRef.current) {
          setInsight(data.ai_insight ?? null);
          setInsightError(data.ai_error ?? null);
          setCachedAt(data.ai_cached_at ?? null);
        }
      } catch (error: unknown) {
        if (!cancelled) {
          setBoardError(error instanceof Error ? error.message : "Không tải được bảng giá.");
        }
      } finally {
        if (!cancelled) setLoadingBoard(false);
      }
    }

    void loadBoard();
    const id = window.setInterval(() => void loadBoard(), 180_000);

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

  async function onCrawl() {
    setCrawling(true);
    setCrawlError(null);

    try {
      const result = await crawlNews();
      setCrawl(result);
      setBoard(await fetchOverview());
    } catch (error) {
      setCrawlError(error instanceof Error ? error.message : "Không cập nhật được tin.");
    } finally {
      setCrawling(false);
    }
  }

  async function onAnalyze() {
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
      setAnalyzeError(error instanceof Error ? error.message : "Không lấy được nhận định.");
    } finally {
      analyzingRef.current = false;
      setAnalyzing(false);
    }
  }

  const view = board;
  const prices = view?.recent_prices.map((tick) => Number(tick.price)) ?? [];
  const first = prices[0];
  const last = prices[prices.length - 1];
  const delta = prices.length > 1 && first !== undefined && last !== undefined ? last - first : null;

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
          <button type="button" className="primary" onClick={onCrawl} disabled={crawling || loadingBoard}>
            {crawling ? "Đang cập nhật tin…" : "Cập nhật tin"}
          </button>
          <button type="button" onClick={onAnalyze} disabled={analyzing || !view}>
            {analyzing ? `Đang nhận định ${elapsed}s` : "Nhận định H1"}
          </button>
        </div>
      </header>

      {boardError ? <p className="banner bad">{boardError}</p> : null}
      {crawlError ? <p className="banner bad">{crawlError}</p> : null}
      {analyzeError ? <p className="banner bad">{analyzeError}</p> : null}
      {crawl ? <p className={crawl.status === "success" ? "banner ok" : "banner bad"}>{crawl.message}</p> : null}

      {crawl ? (
        <ul className="source-row">
          {crawl.sources.map((source) => (
            <li key={source.source} className={source.status === "ok" ? "ok" : "bad"}>
              <strong>{source.source}</strong>
              <span>
                {source.status === "ok" ? `Lưu ${source.saved}/${source.found}` : source.error || "Lỗi"}
              </span>
            </li>
          ))}
        </ul>
      ) : null}

      {loadingBoard && !view ? <p className="banner">Đang tải giá và tin mới nhất.</p> : null}

      {view ? (
        <>
          {view.warmup ? (
            <p className="banner warn">
              Giá 5 ngày gần đây vẫn còn dữ liệu khởi tạo, chưa phải giá thị trường liên tục. Phiếu lệnh đang để Không giao dịch.
            </p>
          ) : null}

          {view.events.length > 0 ? (
            <p className="banner warn">
              Tin USD tác động mạnh:{" "}
              {view.events.map((event) => `${event.title} (${when(event.time)})`).join(" · ")}. Không vào lệnh
              trong 30 phút trước và sau giờ ra tin.
            </p>
          ) : null}

          <TradeTicket plan={view.cfd_plan} />

          <section className="hero">
            <div>
              <p className="eyebrow">Giá hiện tại</p>
              <p className="price">{money(view.current_price)}</p>
              <p className="price-meta">
                <span className={view.price_origin === "synthetic" || view.price_origin === "seed" ? "pill warn" : "pill ok"}>
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
                {view.price_ticks_5d} tick · {view.hourly_samples} mẫu giờ · {view.indicator_basis}
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
