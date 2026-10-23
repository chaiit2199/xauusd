defmodule GoldBackend.Services.SignalSimulatorTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.SignalSimulator
  @published ~U[2026-10-23 08:00:35Z]
  defp signal,
    do: %{
      published_at: @published,
      entry_expires_at: ~U[2026-10-23 08:30:00Z],
      horizon_at: ~U[2026-10-23 10:00:35Z],
      cancelled_at: nil,
      side: "buy",
      entry_low: 99.0,
      entry_high: 101.0,
      stop_loss: 95.0,
      take_profit: 110.0
    }

  defp bar(minutes, changes \\ %{}),
    do:
      Map.merge(
        %{
          open_time: DateTime.add(~U[2026-10-23 08:00:00Z], minutes * 60),
          open: 100.0,
          high: 102.0,
          low: 99.0,
          close: 100.0,
          confirmed: true
        },
        changes
      )

  test "ignores the publication candle and forming candles" do
    result =
      SignalSimulator.evaluate(
        signal(),
        [bar(0, %{high: 120.0, low: 90.0}), bar(15)],
        ~U[2026-10-23 08:20:00Z]
      )

    assert result.status == "pending_entry"
    refute result.entry_touched
    assert result.observed_from == "2026-10-23T08:15:00Z"
  end

  test "entry then target and entry then stop are symmetric for BUY and SELL" do
    for side <- ["buy", "sell"], hit <- ["tp_first", "sl_first"] do
      exit =
        if hit == "tp_first",
          do: bar(30, %{high: 111.0, close: 110.0}),
          else: bar(30, %{low: 94.0})

      s =
        if side == "buy",
          do: signal(),
          else: %{signal() | side: "sell", stop_loss: 105.0, take_profit: 90.0}

      bars =
        if side == "buy",
          do: [bar(15), exit],
          else:
            Enum.map([bar(15), exit], fn b ->
              %{
                b
                | open: 200 - b.open,
                  close: 200 - b.close,
                  high: 200 - b.low,
                  low: 200 - b.high
              }
            end)

      result = SignalSimulator.evaluate(s, bars, ~U[2026-10-23 08:45:00Z])
      assert result.status == hit
      assert result.entry_touched
      assert result.entry_price == 100.0
    end
  end

  test "both exits touched in a candle cannot be called a win" do
    result =
      SignalSimulator.evaluate(
        signal(),
        [bar(15), bar(30, %{high: 111.0, low: 94.0})],
        ~U[2026-10-23 08:45:00Z]
      )

    assert result.status == "ambiguous"
  end

  test "intrabar entry plus target is ambiguous, opening inside the zone establishes entry first" do
    unknown =
      SignalSimulator.evaluate(
        signal(),
        [bar(15, %{open: 105.0, high: 111.0, low: 100.0, close: 105.0})],
        ~U[2026-10-23 08:30:00Z]
      )

    assert unknown.status == "ambiguous"

    known =
      SignalSimulator.evaluate(signal(), [bar(15, %{high: 111.0})], ~U[2026-10-23 08:30:00Z])

    assert known.status == "tp_first"
  end

  test "a gap beyond stop is not fabricated as an entry" do
    result =
      SignalSimulator.evaluate(
        signal(),
        [bar(15, %{open: 94.0, low: 93.0})],
        ~U[2026-10-23 08:30:00Z]
      )

    assert result.status == "invalidated_before_entry"
    refute result.entry_touched
  end

  test "missing, invalid, approximate or duplicate candles leave outcome unknown" do
    for bars <- [
          [bar(30)],
          [bar(15, %{confirmed: false})],
          [bar(15, %{approx: true})],
          [bar(15, %{low: 101.0})],
          [bar(15), bar(15)]
        ] do
      assert SignalSimulator.evaluate(signal(), bars, ~U[2026-10-23 08:45:00Z]).status ==
               "data_gap"
    end

    assert SignalSimulator.evaluate(
             signal(),
             [bar(15), bar(45, %{high: 111.0})],
             ~U[2026-10-23 09:00:00Z]
           ).status == "data_gap"
  end

  test "no observed entry before deadline expires, later touches do not enter" do
    no_touch = bar(15, %{open: 105.0, high: 106.0, low: 104.0, close: 105.0})
    result = SignalSimulator.evaluate(signal(), [no_touch, bar(30)], ~U[2026-10-23 08:45:00Z])
    assert result.status == "expired_without_entry"
    refute result.entry_touched
  end

  test "monitoring ends at the fixed horizon and never uses later targets" do
    bars = Enum.map(1..8, &bar(&1 * 15)) ++ [bar(135, %{high: 111.0})]
    result = SignalSimulator.evaluate(signal(), bars, ~U[2026-10-23 11:00:00Z])
    assert result.status == "expired_after_entry"
    assert result.observed_through == "2026-10-23T10:00:00Z"
  end

  test "cancellation before entry prevents later simulated entry" do
    s = %{signal() | cancelled_at: ~U[2026-10-23 08:10:00Z]}

    assert SignalSimulator.evaluate(s, [bar(15)], ~U[2026-10-23 08:30:00Z]).status ==
             "cancelled_without_entry"

    s = %{signal() | cancelled_at: ~U[2026-10-23 08:20:00Z]}
    assert SignalSimulator.evaluate(s, [bar(15)], ~U[2026-10-23 08:30:00Z]).status == "ambiguous"
  end

  test "mid-candle cancellation waits for that candle before deciding entry order" do
    s = %{signal() | cancelled_at: ~U[2026-10-23 08:20:00Z]}

    assert SignalSimulator.evaluate(s, [bar(15)], ~U[2026-10-23 08:20:01Z]).status ==
             "pending_entry"

    assert SignalSimulator.evaluate(s, [bar(15)], ~U[2026-10-23 08:30:00Z]).status == "ambiguous"
  end
end
