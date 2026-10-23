defmodule GoldBackend.Services.OhlcSyncTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.{OhlcSync, OhlcContext}
  @slot ~U[2026-10-22 15:15:00Z]
  @now ~U[2026-10-22 15:15:35Z]

  defmodule Store do
    def load(seconds, _), do: Map.get(Process.get(:bars, %{}), seconds, [])
    def recent_attempts(_), do: []

    def reserve(at, seconds, _) do
      send(self(), {:reserve, seconds, at})
      Process.get(:reservation, {:ok, 1})
    end

    def put(bar, seconds) do
      Process.put(:bars, Map.update(Process.get(:bars, %{}), seconds, [bar], &(&1 ++ [bar])))
      :ok
    end

    def finish(_, status) do
      send(self(), {:finished, status})
      :ok
    end
  end

  defmodule Provider do
    def configured?, do: Process.get(:configured, true)
    defdelegate quote(opts), to: GoldBackend.Services.GoldOhlc
    defdelegate fetch(at, seconds, opts), to: GoldBackend.Services.GoldOhlc
  end

  test "refresh requests, validates and persists both intervals before context creation" do
    result = OhlcSync.refresh(@slot, sync_options(&http_ok/3))
    assert result == %{status: "ok", error: nil}
    assert [m15] = Store.load(900, @slot)
    assert [h1] = Store.load(3600, @slot)
    assert m15.open_time == ~U[2026-10-22 15:00:00Z]
    assert h1.open_time == ~U[2026-10-22 14:00:00Z]
    assert m15.confirmed and h1.confirmed
    assert_receive {:reserve, 900, _}
    assert_receive {:reserve, 3600, _}
  end

  test "missing key performs no network or storage work" do
    Process.put(:configured, false)
    result = OhlcSync.refresh(@slot, sync_options(fn _, _, _ -> flunk("no HTTP") end))
    assert result.status == "missing_key"
    refute_received {:reserve, _, _}
  end

  test "a quote 36 seconds ahead of the VPS allows closed M15 and H1 ingestion" do
    get = fn url, headers, options ->
      {:ok, response} = http_ok(url, headers, options)

      if String.contains?(url, "/price/") do
        body = Jason.decode!(response.body)
        body = Map.put(body, "updatedAt", DateTime.to_iso8601(DateTime.add(@now, 36)))
        {:ok, %{response | body: Jason.encode!(body)}}
      else
        {:ok, response}
      end
    end

    assert OhlcSync.refresh(@slot, sync_options(get)) == %{status: "ok", error: nil}
    assert [%{open_time: ~U[2026-10-22 15:00:00Z]}] = Store.load(900, @slot)
    assert [%{open_time: ~U[2026-10-22 14:00:00Z]}] = Store.load(3600, @slot)
  end

  test "excessive clock skew and malformed quotes explain the block without OHLC requests" do
    for {changes, message} <- [
          {%{"updatedAt" => DateTime.to_iso8601(DateTime.add(@now, 61))}, "đi trước máy chủ"},
          {%{"currency" => nil}, "không hợp lệ"}
        ] do
      get = fn url, headers, options ->
        refute String.contains?(url, "/ohlc/")
        {:ok, response} = http_ok(url, headers, options)
        body = response.body |> Jason.decode!() |> Map.merge(changes) |> Jason.encode!()
        {:ok, %{response | body: body}}
      end

      result = OhlcSync.refresh(@slot, sync_options(get))
      assert result.status == "error"
      assert result.error =~ message
      refute_received {:reserve, _, _}
      assert Store.load(900, @slot) == []
    end
  end

  test "rate limiting stops the batch and records the failed reservation" do
    get = fn url, headers, options ->
      if String.contains?(url, "/ohlc/"),
        do: {:ok, %HTTPoison.Response{status_code: 429, body: "secret"}},
        else: http_ok(url, headers, options)
    end

    result = OhlcSync.refresh(@slot, sync_options(get))
    assert result.status == "error"
    refute result.error =~ "secret"
    assert_receive {:finished, "rate_limited"}
    assert [] = Store.load(900, @slot)
    refute_received {:reserve, 3600, _}
  end

  test "local quota prevents an OHLC request and a stale quote prevents any reservation" do
    Process.put(:reservation, {:error, :quota_or_cooldown})

    get = fn url, headers, options ->
      refute String.contains?(url, "/ohlc/")
      http_ok(url, headers, options)
    end

    assert OhlcSync.refresh(@slot, sync_options(get)).status == "limited"
    assert_receive {:reserve, 900, _}

    stale = fn _, _, _ ->
      {:ok,
       %HTTPoison.Response{
         status_code: 200,
         body:
           Jason.encode!(%{
             symbol: "XAU",
             currency: "USD",
             price: 4100,
             updatedAt: "2026-10-21T15:15:00Z"
           })
       }}
    end

    assert OhlcSync.refresh(@slot, sync_options(stale)).status == "error"
    refute_received {:reserve, _, _}
  end

  defp sync_options(get),
    do: [store: Store, provider: Provider, now: @now, api_key: "fake-key", http_get: get]

  defp http_ok(url, _, _) do
    body =
      if String.contains?(url, "/ohlc/") do
        query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

        %{
          open: 4100,
          high: 4105,
          low: 4095,
          close: 4101,
          startTimestamp: String.to_integer(query["startTimestamp"]),
          endTimestamp: String.to_integer(query["endTimestamp"])
        }
      else
        %{symbol: "XAU", currency: "USD", price: 4101, updatedAt: DateTime.to_iso8601(@now)}
      end

    {:ok, %HTTPoison.Response{status_code: 200, body: Jason.encode!(body)}}
  end

  test "empty store prioritizes newest M15 and closed H1 with two requests" do
    assert OhlcSync.plan([], [], [], @slot, @now) == [
             {900, ~U[2026-10-22 15:00:00Z]},
             {3600, ~U[2026-10-22 14:00:00Z]}
           ]
  end

  test "backfill resumes from stored intervals without re-requesting successful candles" do
    m15 = [%{open_time: ~U[2026-10-22 15:00:00Z]}]
    h1 = [%{open_time: ~U[2026-10-22 14:00:00Z]}]
    assert OhlcSync.plan(m15, h1, [], @slot, @now) == [{3600, ~U[2026-10-22 13:00:00Z]}]
  end

  test "empty historical intervals are skipped for six hours so backfill progresses" do
    attempt = %{
      open_time: ~U[2026-10-22 14:00:00Z],
      timeframe: 3600,
      status: "invalid_ohlc",
      requested_at: DateTime.add(@now, -900)
    }

    assert List.last(OhlcSync.plan([], [], [attempt], @slot, @now)) ==
             {3600, ~U[2026-10-22 13:00:00Z]}

    attempt = %{attempt | requested_at: DateTime.add(@now, -6 * 3600)}

    assert List.last(OhlcSync.plan([], [], [attempt], @slot, @now)) ==
             {3600, ~U[2026-10-22 14:00:00Z]}
  end

  test "after H1 is ready remaining capacity repairs M15 gaps" do
    h1 = bars(~U[2026-10-22 15:00:00Z], 3600, 50)

    assert OhlcSync.plan([], h1, [], @slot, @now) == [
             {900, ~U[2026-10-22 15:00:00Z]},
             {900, ~U[2026-10-22 14:45:00Z]}
           ]
  end

  test "five minute checks do not consume history budget between M15 closes" do
    m15 = [%{open_time: ~U[2026-10-22 15:00:00Z]}]
    h1 = [%{open_time: ~U[2026-10-22 14:00:00Z]}]
    assert OhlcSync.plan(m15, h1, [], DateTime.add(@slot, 300), DateTime.add(@now, 300)) == []
  end

  test "repair M15 gaps as soon as 30 H1 candles are ready" do
    h1 = bars(~U[2026-10-22 15:00:00Z], 3600, 30)
    m15 = [%{open_time: ~U[2026-10-22 15:00:00Z]}]
    assert OhlcSync.plan(m15, h1, [], @slot, @now) == [{900, ~U[2026-10-22 14:45:00Z]}]
  end

  test "OHLC context uses provider closes and excludes forming H1 and M15 candles" do
    m15 = bars(@slot, 900, 50)
    h1 = bars(~U[2026-10-22 15:00:00Z], 3600, 50)
    forming_m15 = %{List.last(m15) | open_time: @slot, close: 9999.0}
    forming_h1 = %{List.last(h1) | open_time: ~U[2026-10-22 15:00:00Z], close: 9999.0}
    data = OhlcContext.build(m15 ++ [forming_m15], h1 ++ [forming_h1], @slot)
    assert data.h1_ready
    assert OhlcContext.build(m15, Enum.take(h1, -30), @slot).h1_ready
    refute OhlcContext.build(m15, Enum.take(h1, -29), @slot).h1_ready
    assert data.summary.indicators.current_price == 4100.0
    assert data.summary.indicators.atr_14 == 4.0
    assert Decimal.to_float(data.latest.price) == 4100.0
    assert data.latest.origin == "gold_api_ohlc"
    assert data.latest.timestamp == ~U[2026-10-22 15:14:59Z]
    assert data.m15_closed_at == "2026-10-22T15:15:00Z"
    refute OhlcContext.build(m15, Enum.drop(h1, -1), @slot).h1_ready
    assert OhlcContext.build([], h1, @slot) == nil
  end

  defp bars(slot, seconds, count) do
    Enum.map(count..1//-1, fn n ->
      %{
        open_time: DateTime.add(slot, -n * seconds),
        open: 4100.0,
        high: 4102.0,
        low: 4098.0,
        close: 4100.0,
        confirmed: true
      }
    end)
  end
end
