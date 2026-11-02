defmodule GoldBackendWeb.ChartControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  alias GoldBackend.{Repo, Services.CandleStore}
  @endpoint GoldBackendWeb.Endpoint
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "chart endpoint is read-only, ordered, bounded and excludes incomplete M15 candles" do
    now = DateTime.utc_now() |> GoldBackend.Services.CandleClock.closed_at()

    for i <- 0..205 do
      CandleStore.put(
        %{
          source: "gold_api_ohlc",
          open_time: DateTime.add(now, -900 * i),
          open: 100.0,
          high: 102.0,
          low: 99.0,
          close: 101.0
        },
        900
      )
    end

    response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/api/trading/candles")
      |> json_response(200)

    candles = response["data"]["candles"]
    assert length(candles) == 200
    assert Enum.map(candles, & &1["t"]) == Enum.sort(Enum.map(candles, & &1["t"]))
    assert List.last(candles)["t"] == DateTime.to_unix(DateTime.add(now, -900), :millisecond)
    assert List.last(candles)["c"] == 101.0
  end

  test "empty store returns an empty chart without triggering data ingestion" do
    assert %{"data" => %{"candles" => []}} =
             build_conn() |> get("/api/trading/candles") |> json_response(200)
  end
end
