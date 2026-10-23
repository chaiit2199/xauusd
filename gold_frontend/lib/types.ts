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
  strategy_version?: string;
  mode?: "signals_only";
  setup_id?: string | null;
  setup_status?: "watching" | "wait_confirmation" | "wait_pullback" | "wait_target" | "signal_ready" | "expired" | "invalidated" | "paused" | "news_window";
  decision_plan?: DecisionPlan;
  setup_formed_at?: string | null;
  setup_expires_at?: string | null;
  reference_entry?: number | null;
  reference_atr?: number | null;
  entry_adverse?: number | null;
  entry_limit?: number | null;
  barrier?: { id: string; low: number; mid: number; high: number } | null;
  execution_status?: "not_tracked";
  execution_ready?: boolean;
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
  signal_valid_until?: string | null;
  next_evaluation_at?: string;
  rule_statistics?: RuleStatistics;
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

export type RuleStatistics = {
  version: string;
  days: number;
  evaluations: number;
  checks: { code: string; evaluated: number; pass: number; blocked: number; unknown: number; sole_blocker: number }[];
};

export type DecisionPlan = {
  side: "buy" | "sell" | "neutral";
  source: string;
  evidence: string[];
  candidate_count?: number;
  cost_sensitivity?: { stress_cost: number; stress_reward_risk: number; max_cost_for_min_rr: number } | null;
  supporting_evidence?: { code: string; supports: boolean; reason: string }[];
  technical_context?: {
    as_of: string;
    ribbon: { side: string; values: { period: number; value: number }[] };
    structure: { side: string; high: StructurePivot | null; low: StructurePivot | null };
    fibonacci: { side: string; high: StructurePivot; low: StructurePivot; levels: { ratio: number; price: number }[] } | null;
    aoi: { id: string; low: number; high: number }[];
    rolling_4h: { high: number; low: number } | null;
    rolling_24h: { high: number; low: number } | null;
  } | null;
  entry_zone: { low: number; high: number } | null;
  entry_zone_kind: "eligible" | "watch";
  confirmation: string;
  trigger: string;
  stop_loss: number | null;
  stop_reason: string;
  take_profit: number | null;
  target_reason: string;
  reward_risk: number | null;
  reward_risk_basis: string;
  cost: { spread: number; source: string; description: string };
  formed_at: string | null;
  expires_at: string | null;
  cancellation: string[];
  simulation_seconds: number;
};

type StructurePivot = { price: number; label: string; pivot_at: string; confirmed_at: string };

export type SignalHistoryData = {
  model: string;
  limit: number;
  summary: Record<string, number>;
  items: {
    setup_id: string;
    side: "buy" | "sell";
    version: string;
    published_at: string;
    expires_at: string | null;
    horizon_at: string | null;
    validity: "active" | "expired" | "invalidated" | "unknown";
    validity_reason: string | null;
    plan: DecisionPlan | null;
    result: { status: string; entry_touched: boolean; entry_price?: number | null; entry_bar_at?: string | null; exit_bar_at?: string | null; observed_from?: string; observed_through?: string | null; detail?: string };
  }[];
};

export type AnalyzeData = MarketBoard & {
  ai_insight: string | null;
  ai_error: string | null;
  ai_cached_at: string | null;
};
