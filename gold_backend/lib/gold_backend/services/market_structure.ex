defmodule GoldBackend.Services.MarketStructure do
  @moduledoc "Closed H1 context. Two-bar pivots are only visible at confirmation; evidence is not a probability or a veto."
  alias GoldBackend.Services.Indicators
  @periods [20, 25, 30, 35, 40, 45, 50, 55]

  def assess(bars, at) do
    bars =
      bars
      |> Enum.filter(
        &(Map.get(&1, :confirmed) == true and not Map.get(&1, :approx, false) and
            not Map.get(&1, :is_approximate, false) and
            DateTime.compare(DateTime.add(&1.open_time, 3600), at) != :gt)
      )
      |> Enum.sort_by(& &1.open_time, DateTime)

    structure = structure(bars)

    %{
      as_of: DateTime.to_iso8601(at),
      ribbon: ribbon(bars),
      structure: structure,
      fibonacci: fibonacci(structure),
      aoi: aoi(bars),
      rolling_4h: rolling(bars, GoldBackend.Services.CandleClock.closed_at(at, 3600), 4),
      rolling_24h: rolling(bars, GoldBackend.Services.CandleClock.closed_at(at, 3600), 24)
    }
  end

  def ribbon(bars) when length(bars) < 55, do: %{side: "unknown", values: []}

  def ribbon(bars) do
    closes = Enum.map(bars, & &1.close)
    values = Enum.map(@periods, &%{period: &1, value: Indicators.ema(closes, &1)})
    pairs = Enum.chunk_every(values, 2, 1, :discard)

    side =
      cond do
        Enum.all?(pairs, fn [a, b] -> a.value > b.value end) -> "buy"
        Enum.all?(pairs, fn [a, b] -> a.value < b.value end) -> "sell"
        true -> "mixed"
      end

    %{side: side, values: Enum.map(values, &%{&1 | value: Float.round(&1.value, 4)})}
  end

  def structure(bars) do
    initial = %{side: "neutral", high: nil, low: nil, event: nil, events: []}

    bars
    |> Enum.with_index()
    |> Enum.reduce(initial, fn {bar, index}, state ->
      state = if index >= 4, do: confirm(state, Enum.slice(bars, index - 4, 5)), else: state

      cond do
        state.high && not state.high.broken && bar.close > state.high.price ->
          break_level(state, :high, "buy", bar)

        state.low && not state.low.broken && bar.close < state.low.price ->
          break_level(state, :low, "sell", bar)

        true ->
          state
      end
    end)
  end

  defp confirm(state, [a, b, c, d, e]) do
    Enum.reduce([:high, :low], state, fn side, acc ->
      price = Map.fetch!(c, side)

      pivot? =
        Enum.all?([a, b, d, e], fn other ->
          if side == :high, do: price > other.high, else: price < other.low
        end)

      if pivot? do
        previous = Map.get(acc, side)

        label =
          cond do
            is_nil(previous) -> if(side == :high, do: "H", else: "L")
            price == previous.price -> if(side == :high, do: "EH", else: "EL")
            side == :high -> if(price > previous.price, do: "HH", else: "LH")
            true -> if(price > previous.price, do: "HL", else: "LL")
          end

        Map.put(acc, side, %{
          price: price,
          label: label,
          broken: previous != nil and previous.price == price and previous.broken,
          pivot_at: DateTime.to_iso8601(c.open_time),
          confirmed_at: DateTime.to_iso8601(DateTime.add(e.open_time, 3600))
        })
      else
        acc
      end
    end)
  end

  defp break_level(state, key, side, bar) do
    pivot = Map.fetch!(state, key)

    kind =
      cond do
        state.side == "neutral" -> "Break"
        state.side == side -> "BoS"
        true -> "CHoCH"
      end

    event = %{
      kind: kind,
      side: side,
      price: pivot.price,
      pivot_at: pivot.pivot_at,
      confirmed_at: DateTime.to_iso8601(DateTime.add(bar.open_time, 3600))
    }

    state
    |> Map.put(key, %{pivot | broken: true})
    |> Map.merge(%{side: side, event: event, events: state.events ++ [event]})
  end

  defp fibonacci(%{high: h, low: l}) when not is_nil(h) and not is_nil(l) do
    if h.price > l.price and h.pivot_at != l.pivot_at do
      side = if h.pivot_at > l.pivot_at, do: "buy", else: "sell"

      levels =
        Enum.map([0.236, 0.382, 0.5, 0.618, 0.786], fn ratio ->
          price =
            if side == "buy",
              do: h.price - ratio * (h.price - l.price),
              else: l.price + ratio * (h.price - l.price)

          %{ratio: ratio, price: Float.round(price, 2)}
        end)

      %{side: side, high: h, low: l, levels: levels}
    end
  end

  defp fibonacci(_), do: nil

  defp aoi(bars) when length(bars) < 50, do: []

  defp aoi(bars) do
    recent = Enum.take(bars, -50)
    upper = recent |> Enum.map(&max(&1.open, &1.close)) |> Enum.max()
    lower = recent |> Enum.map(&min(&1.open, &1.close)) |> Enum.min()
    atr = Indicators.candle_atr(bars)

    [
      %{id: "aoi_high_h1", low: upper, high: upper + atr, mid: upper + atr / 2, entry_only: true},
      %{id: "aoi_low_h1", low: lower - atr, high: lower, mid: lower - atr / 2, entry_only: true}
    ]
  end

  defp rolling(bars, at, hours) do
    cutoff = DateTime.add(at, -hours * 3600)
    sample = Enum.filter(bars, &(DateTime.compare(&1.open_time, cutoff) != :lt))
    # Do not label partial slices or an overnight/weekend gap as a full window.
    if length(sample) == hours and hd(sample).open_time == cutoff and
         Enum.all?(Enum.chunk_every(sample, 2, 1, :discard), fn [a, b] ->
           DateTime.diff(b.open_time, a.open_time) == 3600
         end) do
      %{high: Enum.max_by(sample, & &1.high).high, low: Enum.min_by(sample, & &1.low).low}
    end
  end

  def evidence(nil, _, _), do: []

  def evidence(context, side, zone) do
    fib = context.fibonacci

    fib_match =
      fib && zone && fib.side == side &&
        Enum.any?(fib.levels, &(&1.price >= zone.low and &1.price <= zone.high))

    [
      %{
        code: "ema_ribbon",
        supports: side in ["buy", "sell"] and context.ribbon.side == side,
        reason: "Dải EMA20–55 H1: #{direction(context.ribbon.side)}; tính là một nhóm bằng chứng."
      },
      %{
        code: "structure",
        supports: side in ["buy", "sell"] and context.structure.side == side,
        reason: structure_reason(context.structure)
      },
      %{
        code: "fibonacci",
        supports: fib_match == true,
        reason:
          if(fib_match,
            do: "Vùng vào trùng mức hồi Fibonacci của nhịp đã xác nhận.",
            else: "Chưa có Fibonacci cùng hướng trùng vùng vào; không chặn setup."
          )
      }
    ]
  end

  defp structure_reason(%{event: nil}),
    do: "Chưa có phá vỡ cấu trúc H1 đã xác nhận; không chặn setup."

  defp structure_reason(%{event: e}),
    do: "Cấu trúc H1: #{e.kind} #{direction(e.side)} qua #{e.price}, xác nhận #{e.confirmed_at}."

  defp direction("buy"), do: "tăng"
  defp direction("sell"), do: "giảm"
  defp direction("mixed"), do: "đan xen"
  defp direction(_), do: "chưa đủ dữ liệu"
end
