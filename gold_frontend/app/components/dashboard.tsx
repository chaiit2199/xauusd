"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  analyzeMarket,
  crawlNews,
  fetchNews,
  fetchOverview,
  fetchSignalHistory,
  fetchCandles,
} from "../../lib/api";
import { expireAnalysis } from "../../lib/analysis-window";
import type { Article, MarketBoard, SignalHistoryData } from "../../lib/types";
import { Candle, normalizeCandles, recentNews } from "../../lib/template-data";
import {
  Header,
  PriceHero,
  BiasGauge,
  SignalActive,
  LoadState,
} from "./template/market";
import {
  SignalStats,
  SignalTable,
  NewsTimeline,
  NewsList,
} from "./template/history-news";
const initial: LoadState = { loading: true, error: null };
export function Dashboard() {
  const [board, setBoard] = useState<MarketBoard | null>(null),
    [candles, setCandles] = useState<Candle[]>([]),
    [history, setHistory] = useState<SignalHistoryData | null>(null),
    [articles, setArticles] = useState<Article[]>([]);
  const [boardState, setBoardState] = useState(initial),
    [candleState, setCandleState] = useState(initial),
    [signalState, setSignalState] = useState(initial),
    [newsState, setNewsState] = useState(initial),
    [now, setNow] = useState(0);
  const marketLock = useRef(false),
    newsLock = useRef(false),
    mounted = useRef(false);
  const market = useCallback(async (manual = false) => {
    if (marketLock.current) return;
    marketLock.current = true;
    const read = async <T,>(
      fetcher: () => Promise<T>,
      save: (v: T) => void,
      state: (v: LoadState) => void,
    ) => {
      if (mounted.current) state({ loading: true, error: null });
      try {
        const value = await fetcher();
        if (mounted.current) {
          save(value);
          state({ loading: false, error: null });
        }
      } catch (e) {
        if (mounted.current)
          state({
            loading: false,
            error: e instanceof Error ? e.message : "Không tải được dữ liệu.",
          });
      }
    };
    try {
      await Promise.allSettled([
        read(manual ? analyzeMarket : fetchOverview, setBoard, setBoardState),
        read(
          fetchCandles,
          (v) => setCandles(normalizeCandles(v)),
          setCandleState,
        ),
        read(fetchSignalHistory, setHistory, setSignalState),
      ]);
    } finally {
      marketLock.current = false;
    }
  }, []);
  const news = useCallback(async (manual = false) => {
    if (newsLock.current) return;
    newsLock.current = true;
    if (mounted.current) setNewsState({ loading: true, error: null });
    let crawlError: string | null = null;
    try {
      if (manual) {
        try {
          const response = await crawlNews();
          if (response.status === "error") crawlError = response.message;
          else if (response.sources.some((s) => s.status === "error"))
            crawlError = "Một số nguồn tin chưa cập nhật được.";
        } catch (e) {
          crawlError =
            e instanceof Error ? e.message : "Không cập nhật được nguồn tin.";
        }
      }
      const data = await fetchNews();
      if (mounted.current) {
        setArticles(data);
        setNewsState({ loading: false, error: crawlError });
      }
    } catch (e) {
      if (mounted.current)
        setNewsState({
          loading: false,
          error: e instanceof Error ? e.message : "Không tải được tin.",
        });
    } finally {
      newsLock.current = false;
    }
  }, []);
  useEffect(() => {
    mounted.current = true;
    setNow(Date.now());
    void market();
    void news();
    const timer = setInterval(() => {
        void market();
        void news();
      }, 60000),
      clock = setInterval(() => setNow(Date.now()), 1000);
    return () => {
      mounted.current = false;
      clearInterval(timer);
      clearInterval(clock);
    };
  }, [market, news]);
  const view = board && now ? expireAnalysis(board, now) : board,
    signals = history?.items ?? [],
    filtered = now ? recentNews(articles, now) : [];
  const active = signals.find(
    (s) =>
      ["pending_entry", "entry_touched"].includes(s.result.status) &&
      Date.parse(s.horizon_at ?? "") > now &&
      (s.result.entry_touched || s.validity === "active"),
  );
  return (
    <div className="template-dashboard">
      <div className="wrap">
        <Header
          newsBusy={newsState.loading}
          marketBusy={
            boardState.loading || signalState.loading || candleState.loading
          }
          onNews={() => void news(true)}
          onMarket={() => void market(true)}
        />
        <main className="hero">
          <PriceHero
            board={view}
            candles={candles}
            active={active}
            state={boardState}
            candleState={candleState}
            now={now}
          />
          <aside className="stack">
            <BiasGauge
              candles={candles}
              board={view}
              state={{
                loading: boardState.loading || candleState.loading,
                error: boardState.error || candleState.error,
              }}
            />
            <SignalActive
              signal={active}
              candles={candles}
              state={signalState}
            />
          </aside>
        </main>
        <section aria-labelledby="t-hist">
          <div className="sh">
            <h2 id="t-hist">Lịch sử tín hiệu và mô phỏng</h2>
            <p>
              {signals.length} tín hiệu gần nhất · kết quả mô phỏng theo nến
              M15, không phải lợi nhuận thực tế
            </p>
          </div>
          <SignalStats signals={signals} state={signalState} />
          <SignalTable
            signals={signals}
            candles={candles}
            state={signalState}
          />
        </section>
        <section aria-labelledby="t-news">
          <div className="sh">
            <h2 id="t-news">Tin mới nhất · hôm nay và hôm qua (UTC)</h2>
            <p>{filtered.length} bài</p>
          </div>
          <div className="two news-grid">
            <NewsTimeline articles={filtered} state={newsState} now={now} />
            <NewsList articles={filtered} state={newsState} />
          </div>
        </section>
        <footer className="foot">
          <span>Vàng · XAUUSD</span>
          <span>Dữ liệu &amp; phân tích thị trường</span>
        </footer>
      </div>
    </div>
  );
}
