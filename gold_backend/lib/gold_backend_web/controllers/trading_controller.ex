defmodule GoldBackendWeb.TradingController do
  use GoldBackendWeb, :controller

  import Ecto.Query

  alias GoldBackend.Repo

  alias GoldBackend.Services.{
    AiDecision,
    CandleClock,
    CandleStore,
    GoldOhlc,
    OhlcContext,
    M15Signal,
    EconomicCalendar,
    Indicators,
    NewsBias,
    NewsCrawler,
    NewsTranslator,
    OllamaAnalyzer,
    TradePlan,
    InsightCache
  }

  alias GoldBackend.Trading.{GoldPrice, NewsArticle}

  # Seed supports display only. Trading requires 30 closed live H1 samples
  # and a confirmed provider M15 setup. Synthetic quotes remain warmup data.
  @live_origins ~w(metals_dev gold_api)

  def trigger_crawl_news(conn, _params) do
    sources = NewsCrawler.fetch_and_save_all()
    saved = Enum.reduce(sources, 0, fn source, acc -> acc + source.saved end)
    ok? = Enum.any?(sources, &(&1.status == "ok"))

    articles =
      NewsArticle
      |> order_by(desc: :published_at)
      |> limit(20)
      |> Repo.all()
      |> NewsTranslator.ensure_vietnamese()
      |> Enum.map(&article_json/1)

    status = if ok?, do: 200, else: 502

    conn
    |> put_status(status)
    |> json(%{
      status: if(ok?, do: "success", else: "error"),
      message: crawl_message(saved, ok?),
      sources: Enum.map(sources, &source_json/1),
      articles: articles
    })
  end

  def build_context(opts \\ []), do: market_context(opts)

  def write_commentary(context) do
    extras = %{
      indicators: context.indicators,
      news_digest: context.news_bias.digest
    }

    case OllamaAnalyzer.analyze_market(
           context.indicators,
           context.news,
           context.price_ticks,
           context.plan,
           context.news_bias
         ) do
      {:ok, text} ->
        {:ok, aligned} = OllamaAnalyzer.align({:ok, text}, context.plan)
        {aligned, nil}

      {:error, reason} ->
        {TradePlan.commentary(context.plan, extras), reason}
    end
  end

  def overview(conn, _params), do: cached_response(conn)
  def analyze_and_get_data(conn, _params), do: cached_response(conn)

  defp cached_response(conn) do
    case InsightCache.snapshot() do
      nil ->
        conn
        |> put_status(503)
        |> json(%{
          status: "pending",
          message: "Đang chờ lần kiểm tra tiếp theo sau mỗi 5 phút."
        })

      data ->
        json(conn, %{status: "success", data: data})
    end
  end

  def rule_snapshot(context, reason \\ nil) do
    rule_action = context.plan.action
    reason = reason || context.plan.block_reason || "Chưa có tín hiệu đủ điều kiện."

    plan =
      Map.merge(context.plan, %{
        action: "wait",
        action_label: "Đứng ngoài",
        block_reason: reason,
        summary: reason
      })

    context = %{context | plan: plan}

    Map.merge(public_snapshot(context), %{
      rule_action: rule_action,
      ai_action: nil,
      ai_insight: nil,
      ai_error: nil,
      ai_cached_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      ai_ttl_seconds: InsightCache.interval_seconds(),
      analysis_candle_closed_at: DateTime.to_iso8601(CandleClock.closed_at(context.analysis_at)),
      ai_next_analysis_at: DateTime.to_iso8601(CandleClock.next_close(context.analysis_at))
    })
  end

  def analysis_snapshot(context, action, insight, error) do
    rule_action = context.plan.action

    {action, insight, error} =
      if is_nil(error) do
        case AiDecision.parse(%{"action" => to_string(action), "reason" => insight}) do
          {:ok, valid_action, valid_reason} -> {valid_action, valid_reason, nil}
          {:error, reason} -> {:wait, "Không có quyết định AI hợp lệ; tiếp tục theo dõi.", reason}
        end
      else
        {:wait, "Không có quyết định AI hợp lệ; tiếp tục theo dõi.", error}
      end

    plan =
      TradePlan.build(context.indicators, context.plan.entry,
        ai_action: action,
        warmup: context.warmup,
        warmup_detail: context.warmup_detail,
        blocking_event: EconomicCalendar.blocking(context.events),
        news_bias: context.news_bias,
        price_action: context.price_action,
        m15_setup: Map.get(context, :m15_setup)
      )

    context = %{context | plan: plan}

    Map.merge(public_snapshot(context), %{
      rule_action: rule_action,
      ai_action: if(is_nil(error), do: Atom.to_string(action), else: nil),
      ai_insight: insight,
      ai_error: error,
      ai_cached_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      ai_ttl_seconds: InsightCache.interval_seconds(),
      analysis_candle_closed_at:
        DateTime.to_iso8601(
          CandleClock.closed_at(Map.get(context, :analysis_at, DateTime.utc_now()))
        ),
      ai_next_analysis_at:
        DateTime.to_iso8601(
          CandleClock.next_close(Map.get(context, :analysis_at, DateTime.utc_now()))
        )
    })
  end

  defp market_context(opts) do
    now = Keyword.get(opts, :as_of, DateTime.utc_now())
    m15 = Keyword.get_lazy(opts, :m15_candles, fn -> CandleStore.load(900, now) end)
    h1 = Keyword.get_lazy(opts, :h1_candles, fn -> CandleStore.load(3600, now) end)
    ohlc = OhlcContext.build(m15, h1, now)
    feed = Keyword.get(opts, :ohlc_feed, %{status: "stored", error: nil})

    feed =
      Map.merge(feed, %{
        source: "gold_api_ohlc",
        configured: GoldOhlc.configured?(),
        m15_count: length(m15),
        h1_count: length(h1),
        required: 30,
        latest_m15_closed_at: if(ohlc, do: ohlc.m15_closed_at, else: nil)
      })

    prices =
      prices_since(DateTime.add(now, -5, :day))
      |> Enum.filter(&(DateTime.compare(&1.timestamp, now) == :lt))

    prices = if ohlc, do: ohlc.prices, else: prices
    h1_end = CandleClock.closed_at(now, 3600)
    closed_h1 = Enum.filter(prices, &(DateTime.compare(&1.timestamp, h1_end) == :lt))

    if prices == [] or (closed_h1 == [] and is_nil(ohlc)) do
      {:error, feed.error || "Đang tích lũy OHLC M15/H1 từ Gold API."}
    else
      news =
        if Keyword.get(opts, :news_today, false) do
          start = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
          news_between(start, now)
        else
          news_since(DateTime.add(now, -3, :day))
          |> NewsTranslator.ensure_vietnamese(
            timeout: Keyword.get(opts, :translate_timeout, 8_000)
          )
        end

      latest =
        case Keyword.get(opts, :quote) do
          %{price: price, timestamp: timestamp} ->
            %{
              price: Decimal.from_float(price * 1.0),
              timestamp: timestamp,
              currency: "USD",
              origin: "gold_api"
            }

          _ ->
            Enum.max_by(prices, & &1.timestamp, DateTime)
        end

      live_h1 = Enum.filter(closed_h1, &(&1.origin in ["gold_api_ohlc" | @live_origins]))

      summary =
        if ohlc,
          do: ohlc.summary,
          else: Indicators.summarize(if(live_h1 == [], do: closed_h1, else: live_h1))

      h1_ready = not is_nil(ohlc) and ohlc.h1_ready
      entry = latest.price |> Decimal.round(2) |> Decimal.to_float()
      live_ticks = Enum.count(prices, &(&1.origin in ["gold_api_ohlc" | @live_origins]))

      {warmup, warmup_detail} =
        cond do
          feed.error ->
            {true, feed.error}

          not h1_ready ->
            {true,
             "Đang tích lũy OHLC Gold API: M15 #{length(m15)}/30, H1 #{length(h1)}/30; cần H1 mới nhất đã đóng."}

          true ->
            {false, nil}
        end

      m15_setup = M15Signal.assess(m15, summary.indicators, now)
      events = EconomicCalendar.upcoming_usd(now)
      blocking = EconomicCalendar.blocking(events, now)
      news_bias = NewsBias.assess(news, now)
      price_action = recent_price_action(prices, latest, now)

      plan =
        TradePlan.build(summary.indicators, entry,
          warmup: warmup,
          warmup_detail: warmup_detail,
          blocking_event: blocking,
          news_bias: news_bias,
          price_action: price_action,
          m15_setup: m15_setup
        )

      {:ok,
       %{
         latest: latest,
         analysis_at: now,
         ohlc_feed: feed,
         m15_setup: m15_setup,
         prices: prices,
         news: news,
         news_bias: news_bias,
         summary: summary,
         indicators: summary.indicators,
         warmup: warmup,
         warmup_detail: warmup_detail,
         live_price_ticks: live_ticks,
         events: events,
         plan: plan,
         price_ticks: length(prices),
         price_action: price_action
       }}
    end
  end

  defp recent_price_action(prices, latest, now) do
    cutoff = DateTime.add(now, -90 * 60, :second)

    values =
      prices
      |> Enum.filter(
        &(&1.timestamp >= cutoff and &1.timestamp <= now and
            &1.origin in ["gold_api_ohlc" | @live_origins])
      )
      |> Enum.sort_by(& &1.timestamp, DateTime)
      |> Enum.map(&(&1.price |> Decimal.round(4) |> Decimal.to_float()))

    current = latest.price |> Decimal.round(4) |> Decimal.to_float()
    low = if values == [], do: current, else: Enum.min(values)
    high = if values == [], do: current, else: Enum.max(values)

    %{
      window_minutes: 90,
      prices: values,
      low: Float.round(low, 2),
      high: Float.round(high, 2),
      rebound_from_low: Float.round(max(current - low, 0.0), 2),
      pullback_from_high: Float.round(max(high - current, 0.0), 2)
    }
  end

  defp public_snapshot(context) do
    latest = context.latest

    %{
      current_price: decimal_string(latest.price),
      currency: latest.currency,
      price_origin: latest.origin,
      as_of: DateTime.to_iso8601(latest.timestamp),
      price_ticks_5d: context.price_ticks,
      live_price_ticks: context.live_price_ticks,
      hourly_samples: context.summary.hourly_samples,
      indicator_basis:
        if(latest.origin == "gold_api_ohlc",
          do:
            "OHLC XAU/USD từ Gold API · H1 định hướng, M15 xác nhận điểm vào · ATR từ High/Low/Close",
          else: "Báo giá tham khảo; đang chờ OHLC Gold API đủ để phân tích H1/M15"
        ),
      ohlc_feed: Map.get(context, :ohlc_feed),
      warmup: context.warmup,
      warmup_detail: context.warmup_detail,
      recent_prices: recent_prices(context.prices),
      indicators_10: context.indicators,
      m15_setup: Map.get(context, :m15_setup),
      alerts: context.summary.alerts,
      cfd_plan: context.plan,
      news_3d_count: length(context.news),
      news_3d: Enum.map(context.news, &article_json/1),
      news_tone: context.news_bias.tone_label,
      news_digest: context.news_bias.digest,
      events: Enum.map(context.events, &event_json/1),
      analysis_interval_seconds: InsightCache.interval_seconds()
    }
  end

  defp prices_since(from) do
    GoldPrice
    |> where([price], price.timestamp >= ^from)
    |> order_by(desc: :timestamp)
    |> Repo.all()
  end

  defp news_between(from, now) do
    NewsArticle
    |> where([article], article.published_at >= ^from and article.published_at <= ^now)
    |> order_by(desc: :published_at)
    |> limit(15)
    |> Repo.all()
  end

  defp news_since(from) do
    NewsArticle
    |> where([article], article.published_at >= ^from)
    |> order_by(desc: :published_at)
    |> limit(15)
    |> Repo.all()
  end

  defp crawl_message(saved, true),
    do: "Đã cập nhật tin. Lưu mới #{saved} bài."

  defp crawl_message(_saved, false),
    do: "Không tải được tin từ các nguồn."

  defp source_json(source) do
    %{
      source: source.source,
      status: source.status,
      saved: source.saved,
      found: source.found,
      error: Map.get(source, :error)
    }
  end

  defp article_json(article) do
    %{
      title: article.title,
      title_vi: Map.get(article, :title_vi),
      url: article.url,
      source: article.source,
      published_at: article.published_at && DateTime.to_iso8601(article.published_at)
    }
  end

  defp recent_prices(prices) do
    prices
    |> Enum.sort_by(& &1.timestamp, DateTime)
    |> Enum.take(-80)
    |> Enum.map(fn price ->
      %{
        price: decimal_string(price.price),
        timestamp: DateTime.to_iso8601(price.timestamp),
        origin: price.origin
      }
    end)
  end

  defp event_json(event) do
    %{
      title: event.title,
      impact: event.impact,
      time: DateTime.to_iso8601(event.time)
    }
  end

  defp decimal_string(%Decimal{} = decimal) do
    decimal |> Decimal.round(2) |> Decimal.to_string(:normal)
  end
end
