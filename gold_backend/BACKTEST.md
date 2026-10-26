# XAUUSD data and replay

This workflow is research-only. Do not access production without explicit authorization. Price touches are not broker fills or realized P&L. No results here establish profitability.

## Existing storage

- `market_candles`: provider OHLC, keyed by source/timeframe/open time; 900=M15, 3600=H1, 300=M5. `ohlc_requests` records the shared provider quota. M5 remains disabled by default (`GOLD_M5_ENABLED=false`) and is never constructed from M15.
- `gold_prices`: chart prices, including rows marked `seed` or `synthetic`; these are not valid historical market data.
- `strategy_setups`: frozen selected setup. `strategy_candidates`: detected confirmation snapshots and first/last observation; `result` is a candle-touch simulation.
- `strategy_decisions`: latest plan snapshot per M15/version; `strategy_evaluations`: snapshot per minute/version; `strategy_observations`: append-only per evaluation including exact quote used and candidate/check snapshots.
- `strategy_signals`, `signal_outcomes`, and `strategy_invalidations`: published signals and candle-touch outcomes, not broker fills.

Historical records predating `strategy_observations` may lack evaluation quotes or non-selected candidate histories. `strategy_decisions` and `strategy_evaluations` use upserts, so they do not preserve every update. Do not fill missing history with synthetic prices. `market_candles` currently updates a provider candle in place on correction; it does not preserve the original version or when that revision became available, so corrected OHLC cannot establish a strict point-in-time replay. The Gold API reference quote is not verified as an executable CFD bid/ask from the user's broker.

## Migrations

For a new isolated database, run the normal Ecto migrations. Beyond the three strategy migrations `20261026000000`–`20261026000200`, migration `20261026000300_create_replay_observations` creates the append-only observation table and its time/version index. The new code expects the tables to exist. Do not execute migrations against production as part of this workflow. A rollback of `20261026000000` deletes M5 candles; rollback of the candidate/observation migrations loses their recorded data.

## Input format and read-only export

CSV must be unquoted, UTF-8, with exactly these six columns and UTC-aligned ISO 8601 times:

```csv
open_time,timeframe,open,high,low,close
2026-10-23T07:45:00Z,M15,4000,4002,3999,4001
2026-10-23T07:00:00Z,H1,3998,4002,3997,4001
```

JSON is an object with `candles` and optional `quotes`. Candle fields are as above; timeframe accepts M5/M15/H1 or 300/900/3600. Quote fields are `timestamp` and `price`, timestamped at the source, not import time:

```json
{"candles":[{"open_time":"2026-10-23T07:45:00Z","timeframe":"M15","open":4000,"high":4002,"low":3999,"close":4001}],"quotes":[{"timestamp":"2026-10-23T08:00:00Z","price":4001}]}
```

Malformed, unaligned, duplicate, unconfirmed or approximate candles are rejected; missing bars are not filled. CSV cannot carry quotes; use JSON for quote history. M5 may be imported but the current replay is deliberately M15-only.

On an explicitly authorized database with a read-only user, the export task opens a read-only transaction and emits JSON to stdout:

```sh
cd gold_backend
mix compile
PGDATABASE=gold_backend_test mix gold.export_ohlc > /tmp/xau-dataset.json
mix gold.replay /tmp/xau-dataset.json > /tmp/xau-replay.json
```

Use the connection settings for the authorized read-only database; never place credentials in command-line arguments or committed files. If the old database lacks `strategy_observations`, the export has no quotes. Exports include `gold_api_ohlc` only. For other sources, export into the documented CSV/JSON format; identify instrument, broker, price basis, timezone, sessions, spread and gaps separately.

## Replay methodology and limits

`mix gold.replay` runs both the `zoi-v7-structure-ai` baseline copied from repository commit `650821f` and the current strategy against the same dataset. Legacy setup/plan/policy modules are copied from that commit, with observation-only instrumentation; shared indicator, structure, calendar and candle utilities remain shared and must be version-pinned before a formal study. The comparison currently uses the same minimum 50 H1 and 30 M15 warmup for both engines, and does not measure NEW-only behavior during missing H1. M15 candles are evaluated chronologically after close; H1 uses closed bars only, with at most the same 200 stored bars as the live pipeline. A quote is used only if its source timestamp is no later than the evaluation time and passes the strategy's freshness check. Calendar is optional in JSON: `"calendar":{"from":"...Z","until":"...Z","events":[{"time":"...Z","known_at":"...Z","title":"...","impact":"High","country":"USD"}]}`. All timestamps must be UTC and `known_at` must not be after the event. The declared coverage must include 30 minutes before and 15 minutes after each evaluation; events whose `known_at` is in the future are not used. Coverage is a data-provider assertion, not independently verified. Without complete calendar and fresh quotes, `ready_to_enter` is null and the observed subset is reported separately; a quote alone does not prove readiness.

Candidate counts are distinct detected confirmations, including rejections; branches with no confirmation are not candidates. Candidate simulations and selected setup simulations are reported separately. Simulation uses complete subsequent M15 bars, an entry-zone touch model and conservative ambiguity when a candle hits conflicting levels. It does not model bid/ask execution, slippage, fees, latency, partial fills, trading account, or transaction costs in realized outcomes. Candidate touch simulations do not enforce quote availability or news windows at the later touch; they measure technical opportunity, not a verified executable signal. Reference price drawdown is an unweighted sum of simulated USD/oz movements, not account drawdown; it excludes costs and unknown outcomes. Maximum losing streak is ordered by exit candle among settled observations; unknown/ambiguous cases are omitted and simultaneous exits cannot establish an intrabar sequence. An incomplete final horizon, data gap, missing zone or target must not be counted as a win or loss. Reference RR uses an assumed 0.40 USD cost, not a broker quote.

TP1/TP2 status, side/setup, rejected count, approximate entry distances and focus groups appear in JSON. OLD candidate classification follows the old engine and is not a reconstruction of historically published candidate/quote records. There is insufficient data to compare actual BEFORE/AFTER production performance without those records. Replay is a counterfactual comparison only; it cannot attribute changes to individual rules without controlled ablation runs.

For a preliminary engineering review, collect at least 90 trading days with enough complete H1 warmup and M15 bars, real timestamped quotes and USD news/calendar history, and report coverage and sample size for each subgroup. Reserve the latest 30% chronologically as untouched out-of-sample data; compare performance, drawdown and losing streak by period and direction. These are practical starting thresholds, not a statistical guarantee; sparse outcomes, overlapping positions and market regime changes can require much more data. Do not call the strategy profitable on synthetic fixtures or a short replay.

## Replay readiness and revision design (2026-10)

Replay is **not_fully_point_in_time**. Closed-bar selection, quotes with provider timestamp <= evaluation, and news with known_at <= evaluation are enforced. Provider quote timestamps do not establish when the quote was ingested; a provider may correct historical OHLC and `market_candles` overwrites it. News coverage is a declaration, not evidence that all events and later revisions were captured. OHLC gaps, weekends and feed outages require review before using outcomes. Outcomes describe a technical touch model, not execution eligibility or executable CFD fills; no spread/slippage or position sizing is modeled. `READY` requires observed quote and declared calendar coverage, but outcomes are not conditioned on quote/news availability at the eventual touch. Do not infer profitability or account drawdown.

OLD snapshots at `650821f6da540c5af587c394accc4d45b54b2dcd`: BiasEngine, Indicators (ATR, EMA/SMA and other indicator functions), Zoi (AOI), MarketStructure (swing/pivot, BoS/CHoCH and Fibonacci), BreakoutZone, MarketSchedule, CandleClock, EconomicCalendar, plus SetupEngine, SetupLifecycle, StrategyPlan, DecisionPlan, EntryQuality and StrategyPolicy. Candidate logging in the legacy setup modules is instrumentation and must not alter decisions. Replay validation and the common conservative outcome simulator are intentionally shared research infrastructure, not old production components. Frozen snapshots do not themselves prove exact equivalence: a regression against independent golden inputs captured at that commit is still needed.

Recommended future additive table `market_candle_revisions`: source, instrument, timeframe, open_time, provider_timestamp (nullable), ingested_at (required database/server time), revision (monotonic per candle), revised_at, OHLC, confirmed, provider revision identifier/hash. Unique `(source, instrument, timeframe, open_time, revision)`; index `(source, instrument, timeframe, open_time, ingested_at DESC)` and optionally partition by ingested_at. Append each distinct revision transactionally, keep current `market_candles` for existing code; do not backdate ingested_at. Replay at T selects latest revision with ingested_at <= T and, where available, provider_timestamp <= T, with a closed candle at T. Store observed_at/ingested_at on quotes and versions of news/event coverage in the same way; capture provider correction and delayed availability explicitly. Existing exports cannot reconstruct prior revisions. This is a proposal; no migration was created or run for it.

Dataset validation: timestamps must be ISO-8601 UTC, aligned to their timeframe and strictly increasing per timeframe; duplicates, malformed OHLC, approximation, unsupported timeframes and unordered quotes are rejected. Quote timestamps later than an evaluation are excluded. Gaps are reported by timeframe (including normal closures) without filling; users must assess trading hours and data availability. Report gives overall warmup and quote/news coverage on M15 closes; coverage includes warmup and does not prove ingestion-time knowledge. OOS split is chronological by UTC dates with M15 candles: first 70% development, last 30% OOS, earlier data used only as OOS warmup; development outcomes beyond the boundary are not evaluated. Do not tune on OOS. Less than 90 observed dates is flagged `insufficient_sample`, and each focus group with fewer than 30 settled results is flagged likewise; these are operational minimums, not statistical guarantees.

`stages` shows technical plans, observed entry eligibility and simulated outcomes. Simulated outcomes are based on technical setup, not a subset guaranteed eligible at fill time. NEW-only uses side and confirmation timestamp, so two same-side branches at one time are grouped; it is an approximate comparison, not proof of rule attribution. Split and comparison results should not be interpreted as fills. `reference_price_drawdown_usd_per_oz` and expectancy are gross, unweighted sequential simulated price moves, not account P&L. Overlapping candidates and unknown/intrabar outcomes are excluded from settled-only metrics.

M5 remains disabled by default. Future integration should supply actual closed, timestamped candles through an injected provider callback `fetch(instrument, timeframe, from, until)` returning source, observed-at and revision metadata, or unavailable; schedule and rate-limit that adapter outside the strategy. The existing M15 path must receive `[]` when M5 is unavailable. Never aggregate M15 into M5; lower-timeframe ambiguity resolution must use genuine bars and preserve unresolved ties.

## Production migration checklist (do not execute without separate authorization)

1. `20261026000000_allow_m5_candles`: changes candle timeframe constraint; inspect existing M5 values, constraint DDL and lock duration.
2. `20261026000100_create_strategy_candidates`: creates candidate table and indexes; additive, verify old code remains functional and table privileges.
3. `20261026000200_candidate_outcomes`: adds outcome fields/indexes; additive, inspect default/backfill and lock behavior.
4. `20261026000300_create_replay_observations`: append-only snapshots and indexes; additive. Old application ignores table; new journal code requires it, so migrate before deploying new code. Roll back app before dropping new schema, and retain/export data before destructive down migrations. Test rollback on a staging clone; older code cannot read new fields but should not need them.

Exact locks/downtime depend on PostgreSQL version, table size, traffic and DDL; no reliable estimate without measuring a staging clone. Inspect indexes using EXPLAIN, monitor write latency and use concurrent index creation where appropriate in a separate nontransactional migration. Observations grow approximately `evaluations_per_day × mean_row_and_index_bytes × retention_days` plus WAL/vacuum overhead; measure p95 JSON size and index/WAL on staging. Define retention, archival, PII/operational access controls and deletion schedule with the owner before production. Rollback of data-bearing migrations loses history; backup and restore rehearsal required. A further revision table migration is only a design and is not included in these four.
