defmodule GoldBackend.Services.NewsCrawler do
  @moduledoc """
  Pulls gold headlines from five macro/gold desks.

  Each source tries the pages in order. HTML pages are parsed with Floki.
  RSS/Atom feeds are accepted too, because several of these sites block the
  public HTML page and only serve a feed.
  """

  alias GoldBackend.Repo
  alias GoldBackend.Trading.NewsArticle

  require Logger

  @headers [
    {"User-Agent",
     "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"},
    {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
    {"Accept-Language", "en-US,en;q=0.9"}
  ]

  @sources [
    %{
      name: "Kitco Gold",
      pages: ["https://www.kitco.com/news/gold", "https://www.kitco.com/news"]
    },
    %{
      name: "FXStreet Gold",
      pages: [
        "https://www.fxstreet.com/markets/commodities/gold",
        "https://www.fxstreet.com/rss/gold"
      ]
    },
    %{
      name: "Investing.com Gold",
      pages: ["https://www.investing.com/commodities/gold-news"]
    },
    %{
      name: "FXEmpire Gold",
      pages: [
        "https://www.fxempire.com/commodities/gold/news",
        "https://www.fxempire.com/commodities/gold"
      ]
    },
    %{
      name: "MarketWatch Gold",
      pages: [
        "https://www.marketwatch.com/investing/future/gold",
        "https://feeds.content.dowjones.io/public/rss/mw_topstories"
      ]
    }
  ]

  @gold_terms ~w(gold xau bullion fed fomc dollar usd inflation metal treasury yield cpi powell)

  def fetch_and_save_all do
    @sources
    |> Task.async_stream(&crawl_source/1,
      timeout: 30_000,
      on_timeout: :kill_task,
      max_concurrency: 5
    )
    |> Enum.zip(@sources)
    |> Enum.map(fn
      {{:ok, result}, _source} ->
        result

      {{:exit, reason}, source} ->
        %{
          source: source.name,
          status: "error",
          saved: 0,
          found: 0,
          error: "Hết thời gian chờ hoặc tác vụ dừng: #{inspect(reason)}"
        }
    end)
  end

  def parse_body(source_name, page_url, body) when is_binary(body) do
    case Floki.parse_document(body) do
      {:ok, document} ->
        articles =
          if feed?(body) do
            parse_feed(source_name, document)
          else
            parse_html(source_name, page_url, document)
          end

        articles
        |> Enum.uniq_by(& &1.url)
        |> Enum.take(5)

      {:error, _reason} ->
        []
    end
  end

  defp crawl_source(source) do
    case read_first_useful_page(source) do
      {:ok, articles} ->
        saved = save_articles(articles)
        Logger.info("#{source.name}: found #{length(articles)}, saved #{saved}")

        %{
          source: source.name,
          status: "ok",
          saved: saved,
          found: length(articles)
        }

      {:error, reason} ->
        Logger.warning("#{source.name}: #{reason}")

        %{
          source: source.name,
          status: "error",
          saved: 0,
          found: 0,
          error: reason
        }
    end
  end

  defp read_first_useful_page(source) do
    Enum.reduce(source.pages, %{articles: [], error: nil, saw_ok: false, done: false}, fn url,
                                                                                          acc ->
      cond do
        acc.done ->
          acc

        true ->
          case fetch_page(url) do
            {:ok, body} ->
              articles = parse_body(source.name, url, body)

              if articles == [] do
                %{acc | saw_ok: true}
              else
                %{acc | articles: articles, saw_ok: true, done: true}
              end

            {:error, reason} ->
              %{acc | error: "#{reason} (#{url})"}
          end
      end
    end)
    |> case do
      %{articles: articles} when articles != [] -> {:ok, articles}
      %{saw_ok: true} -> {:ok, []}
      %{error: reason} -> {:error, reason || "Không tải được trang"}
    end
  end

  defp fetch_page(url) do
    options = [follow_redirect: true, timeout: 8_000, recv_timeout: 8_000]

    case HTTPoison.get(url, @headers, options) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, body}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, "HTTP #{status}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, inspect(reason)}
    end
  end

  defp feed?(body) do
    head = body |> String.slice(0, 400) |> String.downcase()
    String.contains?(head, ["<rss", "<feed"])
  end

  defp parse_feed(source_name, document) do
    items = Floki.find(document, "item") ++ Floki.find(document, "entry")

    Enum.flat_map(items, fn item ->
      title = item |> Floki.find("title") |> Floki.text() |> clean_text()
      url = item_link(item)

      if keep_title?(title) and is_binary(url) do
        description =
          item
          |> Floki.find("description")
          |> Floki.text()
          |> clean_text()

        [article(source_name, title, url, description, item_time(item))]
      else
        []
      end
    end)
  end

  defp parse_html(source_name, page_url, document) do
    document
    |> Floki.find("a")
    |> Enum.flat_map(fn anchor ->
      href = anchor |> Floki.attribute("href") |> List.first() || ""
      title = anchor |> Floki.text() |> clean_text()

      with url when is_binary(url) <- absolute_url(href, page_url),
           true <- keep_title?(title),
           true <- article_url?(url) do
        [article(source_name, title, url, title, utc_now())]
      else
        _ -> []
      end
    end)
  end

  defp article(source_name, title, url, content, published_at) do
    %{
      title: String.slice(title, 0, 400),
      url: url,
      source: source_name,
      content: content |> String.slice(0, 2_000),
      published_at: published_at
    }
  end

  defp item_link(item) do
    href = item |> Floki.find("link") |> Floki.attribute("href") |> List.first()
    text = item |> Floki.find("link") |> Floki.text() |> String.trim()

    cond do
      is_binary(href) and href != "" -> href
      String.starts_with?(text, "http") -> text
      true -> nil
    end
  end

  defp item_time(item) do
    raw =
      ["pubdate", "published", "updated"]
      |> Enum.find_value(fn tag ->
        text = item |> Floki.find(tag) |> Floki.text() |> String.trim()
        if text == "", do: nil, else: text
      end)

    parse_time(raw)
  end

  defp keep_title?(title) do
    String.length(title) > 20 and is_gold_related?(title) and not junk?(title)
  end

  defp is_gold_related?(title) do
    String.contains?(String.downcase(title), @gold_terms)
  end

  defp junk?(title) do
    down = String.downcase(title)

    Enum.any?(
      ["subscribe", "sign in", "log in", "cookie", "privacy", "newsletter", "buy/sell"],
      &String.contains?(down, &1)
    )
  end

  defp article_url?(url) do
    path = url |> URI.parse() |> Map.get(:path) |> to_string() |> String.downcase()

    String.contains?(path, ["/article", "/story", "/news/", "/analysis", "/commodities/"]) and
      not String.contains?(url, ["javascript:", "mailto:"])
  end

  defp absolute_url(href, page_url) do
    href = String.trim(href || "")

    cond do
      href == "" -> nil
      String.starts_with?(href, ["javascript:", "mailto:", "#"]) -> nil
      String.starts_with?(href, "http") -> href
      true -> page_url |> URI.merge(href) |> URI.to_string()
    end
  end

  defp parse_time(nil), do: utc_now()
  defp parse_time(""), do: utc_now()

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.truncate(datetime, :second)

      _ ->
        parse_rfc1123(value)
    end
  end

  defp parse_rfc1123(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{year, month, day}, {hour, minute, second}} ->
        {:ok, naive} = NaiveDateTime.new(year, month, day, hour, minute, second)
        DateTime.from_naive!(naive, "Etc/UTC")

      :bad_date ->
        utc_now()
    end
  end

  defp save_articles(articles) do
    Enum.count(articles, fn attrs ->
      result =
        %NewsArticle{}
        |> NewsArticle.changeset(attrs)
        |> Repo.insert(on_conflict: :nothing, conflict_target: :url)

      case result do
        {:ok, %{id: id}} when not is_nil(id) ->
          true

        {:ok, _} ->
          false

        {:error, changeset} ->
          Logger.warning("Skip article #{attrs.url}: #{inspect(changeset.errors)}")
          false
      end
    end)
  end

  defp clean_text(text) do
    cleaned =
      text
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    stripped =
      cleaned
      |> String.replace(
        ~r/\A.+?(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w*\.?\s+\d{1,2},\s+\d{4}\s*/,
        ""
      )
      |> String.trim()

    if String.length(stripped) > 20, do: stripped, else: cleaned
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
