defmodule GoldBackend.Services.M15SignalTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.M15Signal

  @now ~U[2026-10-21 15:00:00Z]
  @bear %{current_price: 100.0, sma_20: 101.0, macd: -1.0}
  @bull %{current_price: 100.0, sma_20: 99.0, macd: 1.0}

  test "closed upper sweep follows H1 sell with wick stop and 2R target" do
    setup = M15Signal.assess(bars(:sell), @bear, @now)
    refute setup.blocked
    assert setup.action == "sell"
    assert setup.pattern == "bearish_sweep_pinbar"
    assert setup.stop_loss == 105.5
    assert setup.take_profit == 89.0
    assert setup.atr > 2
  end

  test "closed lower sweep follows H1 buy symmetrically" do
    setup = M15Signal.assess(bars(:buy), @bull, @now)
    refute setup.blocked
    assert setup.action == "buy"
    assert setup.stop_loss == 94.5
    assert setup.take_profit == 111.0
  end

  test "countertrend or unconfirmed trend cannot authorize entry" do
    assert M15Signal.assess(bars(:sell), @bull, @now).blocked
    assert M15Signal.assess(bars(:buy), @bear, @now).blocked
    assert M15Signal.assess(bars(:sell), %{@bear | macd: 0}, @now).blocked
  end

  test "missing, stale, duplicate and gapped candles fail closed" do
    candles = bars(:sell)

    for invalid <- [
          [],
          Enum.take(candles, -29),
          Enum.map(candles, &%{&1 | open_time: DateTime.add(&1.open_time, -900)}),
          List.replace_at(candles, 20, Enum.at(candles, 19)),
          List.update_at(candles, 20, &%{&1 | open_time: DateTime.add(&1.open_time, -1800)})
        ] do
      assert M15Signal.assess(invalid, @bear, @now).blocked
    end
  end

  test "30 closed continuous candles are enough for analysis" do
    refute M15Signal.assess(Enum.take(bars(:sell), -30), @bear, @now).blocked
    assert M15Signal.assess(Enum.take(bars(:sell), -29), @bear, @now).blocked
  end

  test "invalid OHLC or provider confirmation cannot authorize entry" do
    for changes <- [
          %{high: 99.0},
          %{low: 101.0},
          %{close: "100"},
          %{confirmed: false},
          %{open_time: DateTime.add(@now, -899)}
        ] do
      invalid = List.update_at(bars(:sell), -1, &Map.merge(&1, changes))
      assert M15Signal.assess(invalid, @bear, @now).blocked
    end
  end

  test "forming candle is ignored even in its final five minutes" do
    candles = bars(:sell)
    forming = %{List.last(candles) | open_time: @now, confirmed: false}
    expected = M15Signal.assess(candles, @bear, @now)
    assert M15Signal.assess(candles ++ [forming], @bear, DateTime.add(@now, 12 * 60)) == expected
    assert M15Signal.assess(candles ++ [forming], @bear, DateTime.add(@now, 15 * 60)).blocked
  end

  test "a breakout that closes outside the range is not a sweep" do
    candles = List.update_at(bars(:sell), -1, &%{&1 | open: 102.0, close: 103.0})
    assert M15Signal.assess(candles, @bear, @now).blocked
  end

  test "a wick stop exceeding five ATR cannot authorize entry" do
    candles = List.update_at(bars(:sell), -1, &%{&1 | high: 140.0})
    setup = M15Signal.assess(candles, @bear, @now)
    assert setup.blocked
    assert setup.reason =~ "5 ATR"
  end

  test "RSI divergence uses confirmed swing highs and lows only" do
    values =
      Enum.map(0..34, &(100 + &1)) ++
        [140, 135, 134, 133, 134, 135, 136, 137, 138, 139, 141, 139, 138]

    candles = Enum.map(values, &%{close: &1 * 1.0, high: &1 + 0.5, low: &1 - 0.5})
    assert M15Signal.divergence(candles) == "bearish"
    assert M15Signal.divergence(Enum.drop(candles, -1)) == "none"

    mirrored =
      Enum.map(candles, &%{close: 300 - &1.close, high: 300 - &1.low, low: 300 - &1.high})

    assert M15Signal.divergence(mirrored) == "bullish"
  end

  defp bars(side) do
    base =
      Enum.map(0..49, fn i ->
        %{
          open_time: DateTime.add(@now, (i - 50) * 900),
          open: 100.0,
          close: 100.0,
          high: 101.0,
          low: 99.0,
          confirmed: true
        }
      end)

    List.update_at(base, -1, fn bar ->
      if side == :sell,
        do: %{bar | high: 104.0, open: 100.2},
        else: %{bar | low: 96.0, open: 99.8}
    end)
  end
end
