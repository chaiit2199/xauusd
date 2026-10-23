defmodule GoldBackend.Services.StoredSnapshotTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias GoldBackend.{Repo, Services.CandleStore}
  alias GoldBackendWeb.TradingController

  @now ~U[2026-10-23 08:05:00Z]
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp seed_candles do
    for {seconds, count} <- [{900, 50}, {3600, 60}], n <- 1..count do
      :ok =
        CandleStore.put(
          %{
            source: "gold_api_ohlc",
            open_time: DateTime.add(~U[2026-10-23 08:00:00Z], -n * seconds),
            open: 4100.0,
            high: 4102.0,
            low: 4098.0,
            close: 4101.0
          },
          seconds
        )
    end
  end

  test "stored candles restore prices and indicators without quote or calendar access or ticket creation" do
    seed_candles()
    assert {:ok, snapshot} = TradingController.stored_snapshot(as_of: @now)
    assert snapshot.snapshot_origin == "database"
    assert snapshot.current_price == "4101.00"
    assert snapshot.indicators_10.sma_20 == 4101.0
    assert snapshot.ohlc_feed.m15_count == 50
    assert snapshot.ohlc_feed.h1_count == 60
    assert snapshot.cfd_plan.action == "wait"
    assert snapshot.ai_status == "not_requested"
    assert snapshot.ai_insight == nil
    assert snapshot.events == []
    assert snapshot.rule_commentary =~ "dữ liệu đã lưu"
    assert Repo.one(from t in "strategy_tickets", select: count(t.id)) == 0
    assert Repo.one(from d in "strategy_decisions", select: count(d.id)) == 0
  end

  test "overview falls back to stored candles when ETS is empty even for historical data" do
    seed_candles()
    conn = TradingController.overview(Plug.Test.conn(:get, "/api/overview"), %{})
    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert response["data"]["snapshot_origin"] == "database"
    assert response["data"]["cfd_plan"]["action"] == "wait"
  end

  test "empty database returns a pending message about missing stored data" do
    conn = TradingController.overview(Plug.Test.conn(:get, "/api/overview"), %{})
    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["message"] =~ "Chưa có dữ liệu thị trường đã lưu"
  end
end
