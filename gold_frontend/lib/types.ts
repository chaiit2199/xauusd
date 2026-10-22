export type SourceResult = {
  source: string;
  status: "ok" | "error";
  saved: number;
  found: number;
  error?: string | null;
};

export type Article = {
  title: string;
  title_vi?: string | null;
  url: string;
  source: string;
  published_at: string | null;
};

export type CfdPlan = {
  instrument: string;
  market: string;
  action: "buy" | "sell" | "wait";
  action_label: string;
  lean: "buy" | "sell";
  lean_label: string;
  entry: number;
  stop_loss: number;
  take_profit: number;
  stop_distance: number;
  take_distance: number;
  stop_points: number;
  take_points: number;
  point_size: number;
  reward_risk: number;
  reward_risk_after_spread: number;
  spread: number;
  risk_score: number;
  risk_label: string;
  market_state: string;
  block_reason: string | null;
  news_tone?: string | null;
  news_digest?: string | null;
  summary: string;
  notes: string[];
  watchlist?: LiquidityWatchZone[];
};

export type LiquidityWatchZone = {
  id: string;
  side: "buy" | "sell";
  title: string;
  priority: string;
  condition: string;
  entry_low: number;
  entry_high: number;
  stop_loss: number;
  take_profit: number;
  reward_risk: number;
};

export type CalendarEvent = {
  title: string;
  impact: string;
  time: string;
};

export type CrawlResponse = {
  status: "success" | "error";
  message: string;
  sources: SourceResult[];
  articles: Article[];
};

export type Indicators = {
  current_price: number;
  sma_20: number;
  ema_50: number;
  rsi_14: number;
  macd: number;
  bollinger_bands: { upper: number; lower: number };
  atr_14: number;
  stochastic_k: number;
  pivot_level: { p: number; r1: number; s1: number };
  roc_10: number;
  volatility_std: number;
};

export type PriceTick = {
  price: string;
  timestamp: string;
  origin: string;
};

export type MarketBoard = {
  current_price: string;
  currency: string;
  price_origin: string;
  as_of: string | null;
  price_ticks_5d: number;
  live_price_ticks?: number;
  hourly_samples: number;
  indicator_basis: string;
  warmup: boolean;
  warmup_detail?: string | null;
  recent_prices: PriceTick[];
  indicators_10: Indicators;
  alerts: string[];
  cfd_plan: CfdPlan;
  news_3d_count: number;
  news_3d: Article[];
  news_tone?: string | null;
  news_digest?: string | null;
  events: CalendarEvent[];
  analysis_interval_seconds?: number;
  ai_insight?: string | null;
  ai_error?: string | null;
  ai_cached_at?: string | null;
  ai_ttl_seconds?: number;
};

export type AnalyzeData = MarketBoard & {
  ai_insight: string | null;
  ai_error: string | null;
  ai_cached_at: string | null;
};
