defmodule GoldBackend.Services.MarketStructureTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.{Indicators, MarketStructure}
  @start ~U[2026-10-20 00:00:00Z]

  defp bar(index, high, low, close) do
    %{
      open_time: DateTime.add(@start, index * 3600),
      open: close,
      high: high,
      low: low,
      close: close,
      confirmed: true
    }
  end

  defp swings do
    [
      {101, 99, 100},
      {102, 100, 101},
      {105, 101, 103},
      {103, 99, 101},
      {102, 98, 100},
      {106, 100, 105.5},
      {104, 101, 103},
      {103, 99, 101},
      {107, 102, 106.5},
      {105, 101, 103},
      {104, 97, 98}
    ]
    |> Enum.with_index()
    |> Enum.map(fn {{h, l, c}, index} -> bar(index, h, l, c) end)
  end

  test "Wilder ATR uses the seeded history rather than a rolling mean" do
    seed = Enum.map(0..13, &bar(&1, 101.0, 99.0, 100.0))
    shock = bar(14, 108.0, 92.0, 100.0)
    assert Indicators.candle_atr(seed) == 2.0
    assert Indicators.candle_atr(seed ++ [shock]) == 3.0

    assert_in_delta Indicators.candle_atr(seed ++ [shock, bar(15, 101.0, 99.0, 100.0)]),
                    41 / 14,
                    1.0e-10

    assert_in_delta Indicators.ema([1.0, 2.0, 3.0, 4.0], 3), 3.0, 1.0e-10
  end

  test "ribbon is a single directional group and waits for EMA55 history" do
    up = Enum.map(0..59, &bar(&1, 101.0 + &1, 99.0 + &1, 100.0 + &1))
    assert MarketStructure.ribbon(up).side == "buy"
    assert length(MarketStructure.ribbon(up).values) == 8
    assert MarketStructure.ribbon(Enum.take(up, 54)).side == "unknown"
    down = Enum.map(up, &%{&1 | close: 300 - &1.close})
    assert MarketStructure.ribbon(down).side == "sell"
    assert MarketStructure.ribbon(Enum.map(up, &%{&1 | close: 100.0})).side == "mixed"
  end

  test "pivots require two right-hand closed candles, including their confirmation time" do
    bars = swings()
    at = DateTime.add(@start, 4 * 3600)
    assert MarketStructure.assess(bars, at).structure.high == nil
    pivot = MarketStructure.assess(bars, DateTime.add(at, 3600)).structure.high
    assert pivot.price == 105
    assert pivot.pivot_at == "2026-10-20T02:00:00Z"
    assert pivot.confirmed_at == "2026-10-20T05:00:00Z"
    # Future bars cannot change any already-known reading.
    assert MarketStructure.assess(bars, at) == MarketStructure.assess(Enum.take(bars, 4), at)
  end

  test "unconfirmed or approximate right-hand candles cannot confirm a pivot" do
    bars = Enum.take(swings(), 5)
    at = DateTime.add(@start, 5 * 3600)
    assert MarketStructure.assess(bars, at).structure.high.price == 105

    for flag <- [%{confirmed: false}, %{approx: true}, %{is_approximate: true}] do
      changed = List.update_at(bars, -1, &Map.merge(&1, flag))
      assert MarketStructure.assess(changed, at).structure.high == nil
    end
  end

  test "close breaks produce one event per level; continuation and reversal are distinguished" do
    state = MarketStructure.structure(swings())

    assert Enum.map(state.events, &{&1.kind, &1.side}) == [
             {"Break", "buy"},
             {"BoS", "buy"},
             {"CHoCH", "sell"}
           ]

    assert state.high.label == "HH"
    assert state.low.label == "HL"
    assert state.side == "sell"
    repeated = MarketStructure.structure(swings() ++ [bar(11, 100, 96, 98), bar(12, 100, 96, 98)])
    assert repeated.events == state.events
    # A wick above the pivot is insufficient without a close above it.
    wick_only = swings() |> Enum.take(6) |> List.update_at(-1, &%{&1 | close: 104.0})
    assert MarketStructure.structure(wick_only).events == []
  end

  test "Fibonacci anchors use confirmed swings and retain exact anchor timestamps" do
    context = MarketStructure.assess(swings(), DateTime.add(@start, 11 * 3600))
    fib = context.fibonacci
    assert fib.side == "buy"
    assert fib.high.price == 107
    assert fib.low.price == 99
    assert Enum.find(fib.levels, &(&1.ratio == 0.5)).price == 103.0
    assert fib.high.confirmed_at == "2026-10-20T11:00:00Z"

    assert MarketStructure.assess(Enum.take(swings(), 4), DateTime.add(@start, 4 * 3600)).fibonacci ==
             nil
  end

  test "AOI uses body extrema plus Wilder ATR; missing volume is never invented" do
    bars = Enum.map(0..59, &bar(&1, 102.0, 98.0, 100.0))
    at = DateTime.add(@start, 60 * 3600)
    context = MarketStructure.assess(bars, at)
    assert [%{low: 100.0, high: 104.0}, %{low: 96.0, high: 100.0}] = context.aoi
    assert context.rolling_4h == %{high: 102.0, low: 98.0}
    assert context.rolling_24h == %{high: 102.0, low: 98.0}
    refute Map.has_key?(context, :volume)
    assert MarketStructure.assess(Enum.take(bars, 49), at).aoi == []
    assert MarketStructure.assess(Enum.drop(bars, -1), at).rolling_4h == nil
  end
end
