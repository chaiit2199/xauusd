defmodule GoldBackend.Services.BiasEngine do
  @moduledoc "Closed H1 bias, replayed from stored bars. Neutral invalidates immediately; opposite sides have a two-hour cooldown."
  alias GoldBackend.Services.{CandleClock, Indicators}

  def assess(bars, now) do
    closed =
      bars
      |> Enum.filter(&(DateTime.compare(DateTime.add(&1.open_time, 3600), now) != :gt))
      |> Enum.sort_by(& &1.open_time, DateTime)

    base = %{
      side: "neutral",
      reason: "Cần ít nhất 50 nến H1 đã đóng, hợp lệ và đủ mới.",
      locked_until: nil,
      adx: nil,
      slope: nil
    }

    unique = Enum.uniq_by(closed, & &1.open_time) == closed
    valid = length(closed) >= 50 and unique and Enum.all?(closed, &valid?/1)

    fresh =
      closed != [] and
        DateTime.add(List.last(closed).open_time, 3600) == CandleClock.closed_at(now, 3600)

    if valid and fresh do
      Enum.reduce(50..length(closed), base, fn count, previous ->
        prefix = Enum.take(closed, count)
        i = Indicators.summarize_candles(prefix, 3600).indicators
        old_sma = prefix |> Enum.drop(-3) |> Enum.take(-20) |> Enum.map(& &1.close) |> mean()
        slope = (i.sma_20 - old_sma) / max(i.atr_14, 0.01)
        strength = adx(prefix)

        raw =
          cond do
            strength < 20 or abs(slope) < 0.1 -> "neutral"
            i.current_price > i.sma_20 and i.macd > 0 and score(i, :buy) >= 3 -> "buy"
            i.current_price < i.sma_20 and i.macd < 0 and score(i, :sell) >= 3 -> "sell"
            true -> "neutral"
          end

        at = DateTime.add(List.last(prefix).open_time, 3600)

        transition(previous, raw, at)
        |> Map.merge(%{adx: Float.round(strength, 2), slope: Float.round(slope, 3)})
      end)
    else
      base
    end
  end

  def transition(previous, raw, at) do
    locked =
      not is_nil(previous.locked_until) and DateTime.compare(at, previous.locked_until) == :lt

    opposite = raw != Map.get(previous, :last_direction, previous.side)

    cond do
      raw == "neutral" ->
        %{previous | side: "neutral", reason: "H1 chưa có xu hướng đủ rõ; chờ nến H1 mới."}

      locked and opposite ->
        %{
          previous
          | side: "neutral",
            reason: "Hướng cũ đã mất hiệu lực; chờ hết cooldown để đổi hướng."
        }

      previous.side == raw ->
        previous

      true ->
        Map.merge(previous, %{
          side: raw,
          last_direction: raw,
          locked_until: DateTime.add(at, 7200),
          reason: "H1 đã đóng có hướng; chờ setup M15 tại vùng giá."
        })
    end
  end

  defp valid?(b),
    do:
      Map.get(b, :confirmed) == true and not Map.get(b, :approx, false) and
        not Map.get(b, :is_approximate, false) and rem(DateTime.to_unix(b.open_time), 3600) == 0 and
        Enum.all?([b.open, b.high, b.low, b.close], &is_number/1) and
        b.low > 0 and b.high >= max(b.open, b.close) and b.low <= min(b.open, b.close)

  defp score(i, :buy),
    do:
      Enum.count(
        [
          i.current_price > i.sma_20,
          i.current_price > i.ema_50,
          i.macd > 0,
          i.roc_10 > 0,
          i.rsi_14 >= 55
        ],
        & &1
      )

  defp score(i, :sell),
    do:
      Enum.count(
        [
          i.current_price < i.sma_20,
          i.current_price < i.ema_50,
          i.macd < 0,
          i.roc_10 < 0,
          i.rsi_14 <= 45
        ],
        & &1
      )

  defp mean(xs), do: Enum.sum(xs) / length(xs)

  # Wilder smoothing, seeded with 14 observations; ADX uses 14 DX values.
  def adx(bars) do
    moves =
      Enum.chunk_every(bars, 2, 1, :discard)
      |> Enum.map(fn [a, b] ->
        up = b.high - a.high
        down = a.low - b.low

        {max(b.high - b.low, max(abs(b.high - a.close), abs(b.low - a.close))),
         if(up > down and up > 0, do: up, else: 0), if(down > up and down > 0, do: down, else: 0)}
      end)

    if length(moves) < 27 do
      0.0
    else
      seed =
        Enum.take(moves, 14)
        |> Enum.reduce({0.0, 0.0, 0.0}, fn {t, p, m}, {a, b, c} -> {a + t, b + p, c + m} end)

      smoothed =
        Enum.scan(Enum.drop(moves, 14), seed, fn {t, p, m}, {a, b, c} ->
          {a - a / 14 + t, b - b / 14 + p, c - c / 14 + m}
        end)

      dx =
        Enum.map([seed | smoothed], fn {_t, p, m} ->
          if p + m == 0, do: 0.0, else: 100 * abs(p - m) / (p + m)
        end)

      Enum.reduce(Enum.drop(dx, 14), mean(Enum.take(dx, 14)), fn x, acc -> (acc * 13 + x) / 14 end)
    end
  end
end
