defmodule GoldBackend.Services.M15Signal do
  @moduledoc """
  Closed provider OHLC only. Adapter contract: numeric open/high/low/close,
  UTC open_time (quarter-hour), confirmed: true. Sampled quotes are not OHLC.
  Pattern and divergence checks are deterministic strategy assumptions.
  """
  alias GoldBackend.Services.{CandleClock, EntryRules, Indicators}

  def assess(candles, h1, now) do
    slot = CandleClock.closed_at(now)

    base = %{
      blocked: true,
      action: "wait",
      reason: "Chờ dữ liệu OHLC M15 đã đóng từ nguồn thị trường.",
      candle_closed_at: DateTime.to_iso8601(slot),
      pattern: nil,
      divergence: "none",
      indicators: nil,
      entry: nil,
      stop_loss: nil,
      take_profit: nil,
      atr: nil
    }

    with true <- is_list(candles) and candles != [],
         true <- Enum.all?(candles, &valid_time?/1) do
      closed =
        candles
        |> Enum.filter(&(DateTime.compare(DateTime.add(&1.open_time, 900), slot) != :gt))
        |> Enum.sort_by(& &1.open_time, DateTime)
        |> Enum.take(-50)

      cond do
        length(closed) < 30 ->
          %{base | reason: "Cần ít nhất 30 nến OHLC M15 đã đóng để tính chỉ báo."}

        not Enum.all?(closed, &valid_bar?/1) ->
          %{base | reason: "OHLC M15 không hợp lệ hoặc chưa được nguồn xác nhận đóng nến."}

        not continuous?(closed) ->
          %{base | reason: "Chuỗi nến M15 bị trùng hoặc thiếu khoảng thời gian."}

        DateTime.compare(DateTime.add(List.last(closed).open_time, 900), slot) != :eq ->
          %{base | reason: "Chưa có nến M15 vừa đóng; không dùng nến cũ để vào lệnh."}

        true ->
          analyze(closed, h1, base)
      end
    else
      _ -> base
    end
  end

  defp analyze(bars, h1, base) do
    last = List.last(bars)
    prior = bars |> Enum.drop(-1) |> Enum.take(-4)
    range_high = prior |> Enum.map(& &1.high) |> Enum.max()
    range_low = prior |> Enum.map(& &1.low) |> Enum.min()
    atr = true_atr(bars)
    range? = range_high - range_low <= 2 * atr

    upper_sweep? =
      range? and last.high > range_high and last.close < range_high and last.close >= range_low and
        pinbar?(last, :sell)

    lower_sweep? =
      range? and last.low < range_low and last.close > range_low and last.close <= range_high and
        pinbar?(last, :buy)

    trend = EntryRules.trend(h1)
    divergence = divergence(bars)
    indicators = indicators(bars, atr)

    pattern =
      cond do
        upper_sweep? -> "bearish_sweep_pinbar"
        lower_sweep? -> "bullish_sweep_pinbar"
        true -> nil
      end

    base = %{
      base
      | divergence: divergence,
        pattern: pattern,
        indicators: indicators,
        atr: atr,
        entry: last.close
    }

    cond do
      trend == :wait ->
        %{base | reason: "H1 chưa xác nhận xu hướng bằng SMA20 và MACD."}

      (trend == :buy and divergence == "bearish") or (trend == :sell and divergence == "bullish") ->
        %{base | reason: "Phân kỳ RSI M15 ngược hướng H1; chờ xác nhận thêm."}

      (trend == :sell and not upper_sweep?) or (trend == :buy and not lower_sweep?) ->
        %{base | reason: "Chờ nến M15 đóng xác nhận quét thanh khoản và pinbar cùng hướng H1."}

      true ->
        # Fixed $1.50 wick buffer within the requested $1–2 range; never imply
        # guaranteed fills. Risk filters in TradePlan still have final say.
        stop = if trend == :sell, do: last.high + 1.5, else: last.low - 1.5
        risk = abs(stop - last.close)
        target = if trend == :sell, do: last.close - 2 * risk, else: last.close + 2 * risk

        if risk <= 0 or risk > 5 * atr or stop <= 0 or target <= 0 do
          %{base | reason: "SL ngoài râu nến vượt 5 ATR M15 hoặc mức giá không hợp lệ."}
        else
          %{
            base
            | blocked: false,
              action: Atom.to_string(trend),
              reason: "Nến M15 đã đóng xác nhận quét thanh khoản cùng hướng H1.",
              stop_loss: Float.round(stop * 1.0, 2),
              take_profit: Float.round(target * 1.0, 2)
          }
        end
    end
  end

  defp valid_time?(%{open_time: %DateTime{} = at}),
    do: rem(DateTime.to_unix(at), 900) == 0 and elem(at.microsecond, 0) == 0

  defp valid_time?(_), do: false

  defp valid_bar?(%{open: o, high: h, low: l, close: c, confirmed: true})
       when is_number(o) and is_number(h) and is_number(l) and is_number(c),
       do: l > 0 and h >= max(o, c) and l <= min(o, c) and h >= l

  defp valid_bar?(_), do: false

  defp continuous?(bars),
    do:
      bars
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> DateTime.diff(b.open_time, a.open_time) == 900 end)

  defp pinbar?(bar, side) do
    span = bar.high - bar.low
    body = abs(bar.close - bar.open)

    wick =
      if side == :sell,
        do: bar.high - max(bar.open, bar.close),
        else: min(bar.open, bar.close) - bar.low

    close_position = if side == :sell, do: bar.close - bar.low, else: bar.high - bar.close
    span > 0 and body <= 0.3 * span and wick >= 0.6 * span and close_position <= 0.4 * span
  end

  defp true_atr(bars) do
    ranges =
      bars
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.take(-14)
      |> Enum.map(fn [previous, bar] ->
        max(
          bar.high - bar.low,
          max(abs(bar.high - previous.close), abs(bar.low - previous.close))
        )
      end)

    Enum.sum(ranges) / length(ranges)
  end

  defp indicators(bars, atr) do
    i = Indicators.summarize_candles(bars, 900).indicators
    %{i | atr_14: Float.round(atr, 2)}
  end

  def divergence(bars) do
    rsis = bars |> Enum.map(& &1.close) |> Indicators.rsi_values()
    points = Enum.with_index(bars)
    highs = pivots(points, rsis, :high)
    lows = pivots(points, rsis, :low)

    cond do
      diverges?(highs, :high, length(bars)) -> "bearish"
      diverges?(lows, :low, length(bars)) -> "bullish"
      true -> "none"
    end
  end

  defp pivots(points, rsis, key) do
    points
    |> Enum.chunk_every(5, 1, :discard)
    |> Enum.flat_map(fn [a, b, {center, index}, d, e] ->
      value = Map.fetch!(center, key)
      peers = Enum.map([a, b, d, e], fn {bar, _} -> Map.fetch!(bar, key) end)

      pivot? =
        if key == :high,
          do: Enum.all?(peers, &(value > &1)),
          else: Enum.all?(peers, &(value < &1))

      rsi = Enum.at(rsis, index)
      if pivot? and is_number(rsi), do: [%{index: index, price: value, rsi: rsi}], else: []
    end)
  end

  defp diverges?(points, key, count) do
    case Enum.take(points, -2) do
      [a, b] when b.index >= count - 8 ->
        if key == :high,
          do: b.price > a.price and b.rsi < a.rsi,
          else: b.price < a.price and b.rsi > a.rsi

      _ ->
        false
    end
  end
end
