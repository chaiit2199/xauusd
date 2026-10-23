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
  impact?: "High" | "Medium" | "Low" | null;
};

export type CfdPlan = {
  instrument: string;
  timeframe?: "H1" | "M15";
  trend_timeframe?: "H1";
  market: string;
  action: "buy" | "sell" | "wait";
  action_label: string;
  lean: "buy" | "sell" | "neutral";
  bias?: { side: "buy" | "sell" | "neutral"; reason: string; adx: number | null; slope: number | null; locked_until: string | null };
  setup_label?: string;
  blocking_reasons?: string[];
  checks?: { code: string; status: "pass" | "blocked" | "unknown"; reason: string }[];
  soft_flags?: string[];
  spread_source?: string;
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
  entry_guard?: { blocked: boolean; reasons: string[] };
  news_tone?: string | null;
  news_digest?: string | null;
  summary: string;
  notes: string[];
  watchlist?: LiquidityWatchZone[];
};

export type LiquidityWatchZone = {
  order_type?: "sell_limit" | "buy_limit";
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

export type M15Setup = {
  blocked: boolean;
  action: "buy" | "sell" | "wait";
  reason: string;
  candle_closed_at: string;
  pattern: string | null;
  divergence: "none" | "bearish" | "bullish";
  indicators: Indicators | null;
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
  analysis_candle_closed_at?: string;
  ai_next_analysis_at?: string;
  m15_setup?: M15Setup | null;
  ohlc_feed?: {
    source: string;
    configured: boolean;
    status: string;
    error: string | null;
    m15_count: number;
    h1_count: number;
    required: number;
    required_h1?: number;
    latest_m15_closed_at: string | null;
  } | null;
  rule_commentary?: string;
  ai_status?: "pending" | "ready" | "error" | "not_requested";
  ai_action?: "buy" | "sell" | "wait" | null;
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
