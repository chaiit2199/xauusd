defmodule GoldBackend.Services.MarketScheduleTest do
  use ExUnit.Case, async: false
  alias GoldBackend.Services.{MarketSchedule, SetupEngine, OhlcSync, TelegramNotifier}

  setup do
    old = Application.get_env(:gold_backend, :market_closures)

    on_exit(fn ->
      if old,
        do: Application.put_env(:gold_backend, :market_closures, old),
        else: Application.delete_env(:gold_backend, :market_closures)
    end)

    :ok
  end

  test "only declared fully closed intervals excuse missing candles and prevent new signals" do
    first = ~U[2026-10-23 06:00:00Z]
    last = ~U[2026-10-23 07:00:00Z]
    Application.put_env(:gold_backend, :market_closures, [%{from: first, until: last}])
    refute MarketSchedule.open?(first)
    assert MarketSchedule.open?(last)
    assert MarketSchedule.closed_interval?(first, 3600)
    refute MarketSchedule.closed_interval?(DateTime.add(first, -900), 3600)

    assert MarketSchedule.consecutive?(
             [%{open_time: DateTime.add(first, -900)}, %{open_time: last}],
             900
           )

    refute MarketSchedule.consecutive?(
             [%{open_time: DateTime.add(first, -1800)}, %{open_time: last}],
             900
           )

    assert Enum.all?(OhlcSync.plan([], [], [], last, DateTime.add(last, 35)), fn {seconds, at} ->
             not MarketSchedule.closed_interval?(at, seconds)
           end)
  end

  test "M15 history crosses a declared break, but an undeclared hole still blocks" do
    bars =
      Enum.map(0..34, fn n ->
        %{
          open_time: DateTime.add(~U[2026-10-23 08:00:00Z], (n - 35) * 900),
          open: 100.0,
          close: 100.0,
          low: 99.0,
          high: 101.0,
          confirmed: true
        }
      end)

    missing = Enum.at(bars, 10).open_time
    with_gap = List.delete_at(bars, 10)
    bias = %{side: "buy", reason: "H1 tăng"}
    Application.put_env(:gold_backend, :market_closures, [])

    assert SetupEngine.assess(with_gap, bias, [], ~U[2026-10-23 08:00:35Z]).state ==
             "data_unavailable"

    Application.put_env(:gold_backend, :market_closures, [
      %{from: missing, until: DateTime.add(missing, 900)}
    ])

    refute SetupEngine.assess(with_gap, bias, [], ~U[2026-10-23 08:00:35Z]).state ==
             "data_unavailable"
  end

  test "notification hours are independently configurable, including midnight crossings" do
    old = Application.get_env(:gold_backend, :notification_hours)

    on_exit(fn ->
      if old,
        do: Application.put_env(:gold_backend, :notification_hours, old),
        else: Application.delete_env(:gold_backend, :notification_hours)
    end)

    Application.put_env(:gold_backend, :notification_hours, "14-22")
    assert TelegramNotifier.notification_allowed?(~U[2026-10-23 07:00:00Z])
    refute TelegramNotifier.notification_allowed?(~U[2026-10-23 15:00:00Z])
    Application.put_env(:gold_backend, :notification_hours, "22-7")
    assert TelegramNotifier.notification_allowed?(~U[2026-10-23 16:00:00Z])
    refute TelegramNotifier.notification_allowed?(~U[2026-10-23 08:00:00Z])
    Application.put_env(:gold_backend, :notification_hours, "all")
    assert TelegramNotifier.notification_allowed?(~U[2026-10-23 08:00:00Z])
  end
end
