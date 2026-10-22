defmodule GoldBackend.Services.GoldOhlcTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.GoldOhlc
  @open ~U[2026-10-22 14:45:00Z]
  @now ~U[2026-10-22 15:00:35Z]

  defp payload do
    %{
      "open" => "4100.2",
      "high" => 4104.0,
      "low" => 4099.0,
      "close" => 4100,
      "startTimestamp" => DateTime.to_unix(@open),
      "endTimestamp" => DateTime.to_unix(@open) + 899
    }
  end

  test "fetch authenticates by header and requests exactly one closed UTC interval" do
    get = fn url, headers, _ ->
      uri = URI.parse(url)
      assert uri.host == "api.gold-api.com"
      assert uri.path == "/ohlc/XAU"

      assert URI.decode_query(uri.query) == %{
               "startTimestamp" => "#{DateTime.to_unix(@open)}",
               "endTimestamp" => "#{DateTime.to_unix(@open) + 899}"
             }

      assert {"x-api-key", "test-secret"} in headers
      refute url =~ "test-secret"
      {:ok, %HTTPoison.Response{status_code: 200, body: Jason.encode!(payload())}}
    end

    assert {:ok, bar} =
             GoldOhlc.fetch(@open, 900, api_key: "test-secret", now: @now, http_get: get)

    assert bar.open == 4100.2
    assert bar.close == 4100.0
    assert bar.open_time == @open
    assert bar.confirmed
    assert bar.source == "gold_api_ohlc"
  end

  test "missing key, forming or unsettled intervals never make HTTP requests" do
    get = fn _, _, _ -> flunk("HTTP should not run") end
    assert {:error, :missing_key} = GoldOhlc.fetch(@open, 900, api_key: nil, http_get: get)

    for at <- [~U[2026-10-22 14:59:59Z], ~U[2026-10-22 15:00:29Z]] do
      assert {:error, :not_settled} =
               GoldOhlc.fetch(@open, 900, api_key: "key", now: at, http_get: get)
    end

    assert {:error, :invalid_interval} =
             GoldOhlc.fetch(DateTime.add(@open, 1), 900, api_key: "key", now: @now, http_get: get)
  end

  test "rejects invalid OHLC and mismatched response bounds instead of fabricating bars" do
    for changes <- [
          %{"high" => 4000},
          %{"low" => 4200},
          %{"open" => 0},
          %{"close" => nil},
          %{"close" => "NaN"},
          %{"close" => "12junk"},
          %{"startTimestamp" => 0},
          %{"endTimestamp" => DateTime.to_unix(@now)}
        ] do
      assert {:error, :invalid_ohlc} = GoldOhlc.parse(Map.merge(payload(), changes), @open, 900)
    end

    assert {:error, :invalid_ohlc} = GoldOhlc.parse([], @open, 900)
  end

  test "classifies HTTP failures without echoing credentials or response bodies" do
    for {status, error} <- [
          {401, :unauthorized},
          {403, :unauthorized},
          {429, :rate_limited},
          {503, {:http, 503}}
        ] do
      get = fn _, _, _ -> {:ok, %HTTPoison.Response{status_code: status, body: "secret"}} end

      assert {:error, ^error} =
               GoldOhlc.fetch(@open, 900, api_key: "secret", now: @now, http_get: get)
    end

    get = fn _, _, _ -> {:error, %{reason: "secret"}} end

    assert {:error, :network} =
             GoldOhlc.fetch(@open, 900, api_key: "secret", now: @now, http_get: get)
  end

  test "provider timestamps detect stale weekend quotes and future clock errors" do
    for {age, expected} <- [
          {0, :ok},
          {120, :ok},
          {121, :stale_quote},
          {3600, :stale_quote},
          {-6, :ok},
          {-36, :ok},
          {-60, :ok},
          {-61, :clock_skew}
        ] do
      body = %{
        "symbol" => "XAU",
        "currency" => "USD",
        "price" => 4100,
        "updatedAt" => DateTime.add(@now, -age) |> DateTime.to_iso8601()
      }

      get = fn _, headers, _ ->
        refute Enum.any?(headers, fn {key, _} -> key == "x-api-key" end)
        {:ok, %HTTPoison.Response{status_code: 200, body: Jason.encode!(body)}}
      end

      result = GoldOhlc.quote(now: @now, http_get: get)

      if expected == :ok,
        do: assert(match?({:ok, _}, result)),
        else: assert(result == {:error, expected})
    end
  end

  test "malformed quotes are distinct from old quotes and clock skew" do
    valid = %{
      "symbol" => "XAU",
      "currency" => "USD",
      "price" => 4100,
      "updatedAt" => DateTime.to_iso8601(@now)
    }

    for changes <- [
          %{"symbol" => "XAG"},
          %{"currency" => nil},
          %{"updatedAt" => nil},
          %{"updatedAt" => "invalid"},
          %{"price" => 0},
          %{"price" => "NaN"}
        ] do
      get = fn _, _, _ ->
        {:ok,
         %HTTPoison.Response{status_code: 200, body: Jason.encode!(Map.merge(valid, changes))}}
      end

      assert GoldOhlc.quote(now: @now, http_get: get) == {:error, :invalid_quote}
    end
  end
end
