defmodule GoldBackend.Services.GoldOhlc do
  @moduledoc "Gold API range OHLC. One request per closed interval, never sampled quotes."
  @base "https://api.gold-api.com"

  def configured? do
    case Application.get_env(:gold_backend, :gold_api_key) do
      key when is_binary(key) -> String.trim(key) != ""
      _ -> false
    end
  end

  def fetch(open_time, seconds, opts \\ []) when seconds in [900, 3600] do
    key = Keyword.get(opts, :api_key, Application.get_env(:gold_backend, :gold_api_key))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    start = DateTime.to_unix(open_time)
    finish = start + seconds - 1

    cond do
      not is_binary(key) or String.trim(key) == "" ->
        {:error, :missing_key}

      rem(start, seconds) != 0 or elem(open_time.microsecond, 0) != 0 ->
        {:error, :invalid_interval}

      DateTime.compare(DateTime.add(open_time, seconds + 30), now) == :gt ->
        {:error, :not_settled}

      true ->
        query = URI.encode_query(%{startTimestamp: start, endTimestamp: finish})

        with {:ok, data} <-
               get_json(@base <> "/ohlc/XAU?" <> query, [{"x-api-key", String.trim(key)}], opts) do
          parse(data, open_time, seconds)
        end
    end
  end

  def parse(data, open_time, seconds) when is_map(data) do
    start = DateTime.to_unix(open_time)

    with true <- data["startTimestamp"] == start and data["endTimestamp"] == start + seconds - 1,
         {:ok, o} <- number(data["open"]),
         {:ok, h} <- number(data["high"]),
         {:ok, l} <- number(data["low"]),
         {:ok, c} <- number(data["close"]),
         true <- l > 0 and h >= max(o, c) and l <= min(o, c) and h >= l do
      {:ok,
       %{
         open_time: open_time,
         open: o,
         high: h,
         low: l,
         close: c,
         confirmed: true,
         source: "gold_api_ohlc"
       }}
    else
      _ -> {:error, :invalid_ohlc}
    end
  end

  def parse(_, _, _), do: {:error, :invalid_ohlc}

  # Freshness uses the provider timestamp, not the local HTTP receipt time.
  def quote(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, data} <- get_json(@base <> "/price/XAU", [], opts),
         %{"symbol" => "XAU", "currency" => "USD", "updatedAt" => at} when is_binary(at) <- data,
         {:ok, timestamp, _} <- DateTime.from_iso8601(at),
         {:ok, price} <- number(data["price"]),
         true <- price > 0,
         age when age >= -5 and age <= 120 <- DateTime.diff(now, timestamp) do
      {:ok, %{price: price, timestamp: timestamp}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :stale_quote}
    end
  end

  defp get_json(url, headers, opts) do
    get = Keyword.get(opts, :http_get, &HTTPoison.get/3)

    case get.(url, [{"Accept", "application/json"} | headers],
           timeout: 5_000,
           recv_timeout: 10_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} when is_map(data) -> {:ok, data}
          _ -> {:error, :invalid_response}
        end

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        {:error, :rate_limited}

      {:ok, %HTTPoison.Response{status_code: status}} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http, status}}

      # Do not return/log raw errors or bodies that may echo API credentials.
      {:error, _} ->
        {:error, :network}
    end
  end

  defp number(n) when is_number(n) and n > 0 and n < 1_000_000, do: {:ok, n * 1.0}

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, ""} -> number(n)
      _ -> {:error, :invalid_number}
    end
  end

  defp number(_), do: {:error, :invalid_number}
end
