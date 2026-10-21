defmodule GoldBackendWeb.TradingController do
  use GoldBackendWeb, :controller

  import Ecto.Query

  alias GoldBackend.Repo

  alias GoldBackend.Services.{
    EconomicCalendar,
    Indicators,
    NewsCrawler,
    NewsTranslator,
    TradePlan,
    InsightCache
  }

  alias GoldBackend.Trading.{GoldPrice, NewsArticle}

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

  def write_commentary(context), do: {TradePlan.commentary(context.plan), nil}

  def overview(conn, _params) do
    case market_context(translate_timeout: 4_000) do
      {:error, message} ->
        conn |> put_status(400) |> json(%{status: "error", message: message})

      {:ok, context} ->
        json(conn, %{
          status: "success",
          data: Map.merge(public_snapshot(context), InsightCache.peek())
        })
    end
  end

  def analyze_and_get_data(conn, _params) do
    case market_context(translate_timeout: 8_000) do
      {:error, message} ->
        conn |> put_status(400) |> json(%{status: "error", message: message})

      {:ok, context} ->
        json(conn, %{
          status: "success",
          data: Map.merge(public_snapshot(context), InsightCache.resolve(context))
        })
    end
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
      warmup = Enum.any?(prices, &(&1.origin in ["seed", "synthetic"]))
      events = EconomicCalendar.upcoming_usd(now)
      blocking = EconomicCalendar.blocking(events, now)

      plan =
        TradePlan.build(summary.indicators, entry,
          warmup: warmup,
          blocking_event: blocking
        )

      {:ok,
       %{
         latest: latest,
         prices: prices,
         news: news,
         summary: summary,
         indicators: summary.indicators,
         warmup: warmup,
         events: events,
         plan: plan,
         price_ticks: length(prices)
       }}
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
      hourly_samples: context.summary.hourly_samples,
      indicator_basis: "Giá đóng cửa theo giờ, khung H1",
      warmup: context.warmup,
      recent_prices: recent_prices(context.prices),
      indicators_10: context.indicators,
      alerts: context.summary.alerts,
      cfd_plan: context.plan,
      news_3d_count: length(context.news),
      news_3d: Enum.map(context.news, &article_json/1),
      events: Enum.map(context.events, &event_json/1)
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
