defmodule GoldBackendWeb.TradingController do
  use GoldBackendWeb, :controller

  import Ecto.Query

  alias GoldBackend.Repo

  alias GoldBackend.Services.{
    AiDecision,
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

  # Live quotes unlock the ticket. Seed fills ~5 days of hourly bars so SMA20 /
  # EMA50 / ATR can compute immediately; those rows alone must not lock trading
  # forever. Synthetic prints (API down) still count as warmup.
  @live_origins ~w(metals_dev gold_api)
  @min_live_ticks 3

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
        |> json(%{status: "pending", message: "Đang chuẩn bị nhận định đầu tiên."})

      data ->
        json(conn, %{status: "success", data: data})
    end
  end

  def analysis_snapshot(context, action, insight, error) do
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
        price_action: context.price_action
      )

    context = %{context | plan: plan}

    Map.merge(public_snapshot(context), %{
      ai_action: if(is_nil(error), do: Atom.to_string(action), else: nil),
      ai_insight: insight,
      ai_error: error,
      ai_cached_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      ai_ttl_seconds: InsightCache.interval_seconds()
    })
  end

  defp market_context(opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    prices = prices_since(DateTime.add(now, -5, :day))

    if prices == [] do
      {:error, "Chưa có dữ liệu giá vàng trong 5 ngày."}
    else
      news =
        news_since(DateTime.add(now, -3, :day))
        |> NewsTranslator.ensure_vietnamese(timeout: Keyword.get(opts, :translate_timeout, 8_000))

      latest = Enum.max_by(prices, & &1.timestamp, DateTime)
      summary = Indicators.summarize(prices)
      entry = latest.price |> Decimal.round(2) |> Decimal.to_float()
      live_ticks = Enum.count(prices, &(&1.origin in @live_origins))
      {warmup, warmup_detail} = warmup_state(latest, live_ticks)
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
          price_action: price_action
        )

      {:ok,
       %{
         latest: latest,
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
        &(&1.timestamp >= cutoff and &1.timestamp <= now and &1.origin in @live_origins)
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

  defp warmup_state(latest, live_ticks) do
    live? = latest.origin in @live_origins

    cond do
      not live? and latest.origin == "seed" ->
        {true,
         "Giá hiện tại vẫn là dữ liệu khởi tạo (seed). Cần ~5 ngày mẫu giờ để SMA20/EMA50/ATR ổn định; seed chỉ lấp chỗ trống lúc mở hệ thống. Chưa vào lệnh đến khi có giá thị trường thật."}

      not live? ->
        {true,
         "Giá hiện tại là giá nội bộ (synthetic) vì nguồn thị trường tạm lỗi. Chưa vào lệnh cho đến khi lấy lại được giá live."}

      live_ticks < @min_live_ticks ->
        {true,
         "Mới có #{live_ticks}/#{@min_live_ticks} tick giá thị trường thật. Lịch sử 5 ngày (gồm seed) dùng để tính chỉ báo; phiếu lệnh mở sau khi có đủ giá live liên tục."}

      true ->
        {false, nil}
    end
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
        "Giá đóng cửa theo giờ, khung H1 · cửa sổ 5 ngày (~120 mẫu) cho SMA20/EMA50",
      warmup: context.warmup,
      warmup_detail: context.warmup_detail,
      recent_prices: recent_prices(context.prices),
      indicators_10: context.indicators,
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
