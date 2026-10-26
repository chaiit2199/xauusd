defmodule GoldBackend.Replay.Legacy.Indicators do
  @moduledoc """
  Ten technical readings from stored XAU/USD prices.

  The database stores sampled quotes. The default aggregation is hourly;
  M15Signal passes confirmed M15 closes with a 900-second aggregation.
  ATR uses the average absolute hourly close-to-close move because the table
  does not store high/low. The provider OHLC path in summarize_candles/2 instead
  uses real true ranges with Wilder RMA14 and high/low-based Stochastic.
  """

  def calculate_10_indicators(prices) when is_list(prices) and length(prices) > 0 do
    {indicators, _samples} = compute(prices)
    indicators
  end

  def summarize(prices, seconds \\ 3600) when is_list(prices) and length(prices) > 0 do
    {indicators, samples} = compute(prices, seconds)

    %{
      indicators: indicators,
      hourly_samples: samples,
      alerts: alerts(indicators)
    }
  end

  def summarize_candles(bars, seconds) when is_list(bars) and length(bars) > 0 do
    bars = Enum.sort_by(bars, & &1.open_time, DateTime)
    ticks = Enum.map(bars, &%{timestamp: &1.open_time, price: Decimal.from_float(&1.close * 1.0)})
    summary = summarize(ticks, seconds)

    atr = candle_atr(bars)

    recent = Enum.take(bars, -14)
    high = recent |> Enum.map(& &1.high) |> Enum.max()
    low = recent |> Enum.map(& &1.low) |> Enum.min()
    last = List.last(bars)
    k = if high == low, do: 50.0, else: (last.close - low) / (high - low) * 100
    # Previous available UTC day, or preceding bars during initial warmup.
    earlier =
      Enum.filter(
        bars,
        &(Date.compare(DateTime.to_date(&1.open_time), DateTime.to_date(last.open_time)) == :lt)
      )

    prior =
      if earlier == [] do
        case Enum.drop(bars, -1) do
          [] -> [last]
          values -> values
        end
      else
        day = List.last(earlier).open_time |> DateTime.to_date()
        Enum.filter(earlier, &(DateTime.to_date(&1.open_time) == day))
      end

    ph = prior |> Enum.map(& &1.high) |> Enum.max()
    pl = prior |> Enum.map(& &1.low) |> Enum.min()
    p = (ph + pl + List.last(prior).close) / 3

    i = %{
      summary.indicators
      | atr_14: round_num(atr, 2),
        stochastic_k: round_num(k, 2),
        pivot_level: %{
          p: round_num(p, 2),
          r1: round_num(2 * p - pl, 2),
          s1: round_num(2 * p - ph, 2)
        }
    }

    %{summary | indicators: i, alerts: alerts(i)}
  end

  def alerts(indicators) do
    price = indicators.current_price
    bands = indicators.bollinger_bands

    []
    |> push(
      "RSI 14 ở vùng cao (#{indicators.rsi_14}). Động lượng tăng còn mạnh.",
      indicators.rsi_14 >= 70
    )
    |> push(
      "RSI 14 ở vùng thấp (#{indicators.rsi_14}). Động lượng giảm còn mạnh, chưa phải tín hiệu mua.",
      indicators.rsi_14 <= 30
    )
    |> push("Giá đang trên SMA 20.", price > indicators.sma_20)
    |> push("Giá đang dưới SMA 20.", price < indicators.sma_20)
    |> push("Giá vượt biên trên Bollinger.", price > bands.upper)
    |> push("Giá thủng biên dưới Bollinger.", price < bands.lower)
    |> push("MACD dương — động lượng tăng.", indicators.macd > 0)
    |> push("MACD âm — động lượng giảm.", indicators.macd < 0)
    |> push(
      "Stochastic ở vùng cao. Chưa phải tín hiệu bán ngược xu hướng.",
      indicators.stochastic_k >= 80
    )
    |> push(
      "Stochastic ở đáy. Động lượng giảm, chưa phải tín hiệu đảo chiều.",
      indicators.stochastic_k <= 20
    )
    |> push("ROC 10 tăng mạnh (+#{indicators.roc_10}%).", indicators.roc_10 >= 1)
    |> push("ROC 10 giảm mạnh (#{indicators.roc_10}%).", indicators.roc_10 <= -1)
  end

  defp compute(prices, seconds \\ 3600) do
    bars = time_bars(prices, seconds)
    closes = Enum.map(bars, &elem(&1, 1))
    current = List.last(closes)

    sma_20 = sma(closes, 20)
    ema_50 = ema(closes, 50)
    rsi = rsi(closes, 14)
    macd = ema(closes, 12) - ema(closes, 26)
    deviation = closes |> window(20) |> stdev()
    atr = atr(closes, 14)
    stochastic = stochastic(closes, 14)
    pivot = pivot(bars)
    roc = roc(closes, 10)

    indicators = %{
      current_price: round_num(current, 2),
      sma_20: round_num(sma_20, 2),
      ema_50: round_num(ema_50, 2),
      rsi_14: round_num(rsi, 2),
      macd: round_num(macd, 4),
      bollinger_bands: %{
        upper: round_num(sma_20 + deviation * 2, 2),
        lower: round_num(sma_20 - deviation * 2, 2)
      },
      atr_14: round_num(atr, 2),
      stochastic_k: round_num(stochastic, 2),
      pivot_level: %{
        p: round_num(pivot.p, 2),
        r1: round_num(pivot.r1, 2),
        s1: round_num(pivot.s1, 2)
      },
      roc_10: round_num(roc, 2),
      volatility_std: round_num(deviation, 4)
    }

    {indicators, length(bars)}
  end

  defp time_bars(prices, seconds) do
    prices
    |> Enum.group_by(&GoldBackend.Replay.Legacy.CandleClock.closed_at(&1.timestamp, seconds))
    |> Enum.sort_by(fn {hour, _rows} -> hour end, DateTime)
    |> Enum.map(fn {hour, rows} ->
      latest = Enum.max_by(rows, & &1.timestamp, DateTime)
      {hour, decimal_to_float(latest.price)}
    end)
  end

  def rsi_values(closes) do
    closes
    |> Enum.with_index()
    |> Enum.map(fn {_value, index} ->
      if index < 14, do: nil, else: rsi(Enum.take(closes, index + 1), 14)
    end)
  end

  defp sma(list, period) do
    sample = window(list, period)
    Enum.sum(sample) / length(sample)
  end

  def ema(list, period) do
    k = 2 / (period + 1)
    seed_len = min(period, length(list))
    {seed, rest} = Enum.split(list, seed_len)
    seed_avg = Enum.sum(seed) / length(seed)

    Enum.reduce(rest, seed_avg, fn price, acc ->
      price * k + acc * (1 - k)
    end)
  end

  # Wilder ATR: seed with 14 true ranges, then RMA. The first uses high-low.
  def candle_atr(bars, period \\ 14) do
    ranges =
      [
        hd(bars).high - hd(bars).low
        | Enum.map(Enum.chunk_every(bars, 2, 1, :discard), fn [a, b] ->
            max(b.high - b.low, max(abs(b.high - a.close), abs(b.low - a.close)))
          end)
      ]

    {seed, rest} = Enum.split(ranges, period)

    Enum.reduce(rest, Enum.sum(seed) / length(seed), fn tr, atr ->
      (atr * (period - 1) + tr) / period
    end)
  end

  defp rsi(list, period) do
    changes = differences(list)

    cond do
      changes == [] ->
        50.0

      true ->
        use_period = min(period, length(changes))
        {seed, rest} = Enum.split(changes, use_period)
        avg_gain = average_gain(seed)
        avg_loss = average_loss(seed)

        {gain, loss} =
          Enum.reduce(rest, {avg_gain, avg_loss}, fn change, {gain, loss} ->
            up = max(change, 0)
            down = max(-change, 0)

            {(gain * (use_period - 1) + up) / use_period,
             (loss * (use_period - 1) + down) / use_period}
          end)

        cond do
          gain == 0 and loss == 0 -> 50.0
          loss == 0 -> 100.0
          true -> 100.0 - 100.0 / (1.0 + gain / loss)
        end
    end
  end

  defp atr(list, period) do
    changes = list |> differences() |> Enum.map(&abs/1)

    if changes == [] do
      0.0
    else
      changes |> window(period) |> then(&(Enum.sum(&1) / length(&1)))
    end
  end

  defp stochastic(list, period) do
    sample = window(list, period)
    high = Enum.max(sample)
    low = Enum.min(sample)
    current = List.last(list)

    if high == low, do: 50.0, else: (current - low) / (high - low) * 100.0
  end

  defp pivot(bars) do
    {last_at, last_price} = List.last(bars)
    yesterday = last_at |> DateTime.to_date() |> Date.add(-1)

    prior =
      Enum.filter(bars, fn {at, _price} ->
        DateTime.to_date(at) == yesterday
      end)

    prior =
      cond do
        prior != [] -> prior
        length(bars) > 1 -> bars |> Enum.drop(-1) |> window(24)
        true -> [{last_at, last_price}]
      end

    high = prior |> Enum.map(&elem(&1, 1)) |> Enum.max()
    low = prior |> Enum.map(&elem(&1, 1)) |> Enum.min()
    close = prior |> List.last() |> elem(1)
    pivot = (high + low + close) / 3

    %{p: pivot, r1: 2 * pivot - low, s1: 2 * pivot - high}
  end

  defp roc(list, period) do
    current = List.last(list)

    if length(list) <= period or current == 0 do
      0.0
    else
      previous = Enum.at(list, length(list) - 1 - period)
      if previous == 0, do: 0.0, else: (current - previous) / previous * 100.0
    end
  end

  defp stdev(list) do
    mean = Enum.sum(list) / length(list)

    list
    |> Enum.map(&:math.pow(&1 - mean, 2))
    |> Enum.sum()
    |> Kernel./(length(list))
    |> :math.sqrt()
  end

  defp differences(list) do
    list
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [older, newer] -> newer - older end)
  end

  defp window(list, period), do: Enum.take(list, -min(period, length(list)))

  defp average_gain(changes),
    do: changes |> Enum.map(&max(&1, 0)) |> Enum.sum() |> Kernel./(length(changes))

  defp average_loss(changes),
    do: changes |> Enum.map(&max(-&1, 0)) |> Enum.sum() |> Kernel./(length(changes))

  defp decimal_to_float(%Decimal{} = decimal),
    do: decimal |> Decimal.round(4) |> Decimal.to_float()

  defp round_num(value, decimals), do: value |> Kernel.*(1.0) |> Float.round(decimals)

  defp push(alerts, _message, false), do: alerts
  defp push(alerts, message, true), do: alerts ++ [message]
end
