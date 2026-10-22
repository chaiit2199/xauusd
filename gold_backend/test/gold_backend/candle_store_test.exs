defmodule GoldBackend.CandleStoreTest do
  use ExUnit.Case, async: false
  @moduletag :database
  alias GoldBackend.Services.CandleStore
  alias GoldBackend.Repo
  alias GoldBackend.Trading.OhlcRequest

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "closed candles persist idempotently and forming intervals stay out of reads" do
    at = ~U[2026-10-22 15:00:00Z]

    bar = %{
      open_time: at,
      open: 4100.0,
      high: 4105.0,
      low: 4095.0,
      close: 4101.0,
      source: "gold_api_ohlc"
    }

    assert :ok = CandleStore.put(bar, 900)
    assert :ok = CandleStore.put(%{bar | close: 4102.0}, 900)
    assert [] = CandleStore.load(900, DateTime.add(at, 899))
    assert [stored] = CandleStore.load(900, DateTime.add(at, 900))
    assert stored.close == 4102.0
    assert stored.confirmed
  end

  test "rolling quota counts failures and reservations across callers and resets with time" do
    now = ~U[2026-10-22 15:00:35Z]

    for n <- 1..8 do
      assert {:ok, id} = CandleStore.reserve(DateTime.add(now, -n * 900), 900, now)
      CandleStore.finish(id, "network")
    end

    assert {:error, :quota_or_cooldown} = CandleStore.reserve(~U[2026-10-22 12:00:00Z], 3600, now)
    assert {:ok, _} = CandleStore.reserve(~U[2026-10-22 12:00:00Z], 3600, DateTime.add(now, 3601))

    assert [%{requested_at: %DateTime{}, open_time: %DateTime{}} | _] =
             CandleStore.recent_attempts(now)

    assert Repo.aggregate(OhlcRequest, :count) == 9
  end

  test "401 or 429 cools down even before the local quota is exhausted" do
    now = ~U[2026-10-22 15:00:35Z]
    assert {:ok, id} = CandleStore.reserve(~U[2026-10-22 14:45:00Z], 900, now)
    CandleStore.finish(id, "rate_limited")
    assert {:error, :quota_or_cooldown} = CandleStore.reserve(~U[2026-10-22 14:00:00Z], 3600, now)
  end
end
