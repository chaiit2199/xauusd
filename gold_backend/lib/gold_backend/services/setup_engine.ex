defmodule GoldBackend.Services.SetupEngine do
  @moduledoc "Closed provider M15 triggers at a pre-existing ZOI; alternatives, not cumulative requirements."
  alias GoldBackend.Services.{CandleClock, Indicators, Zoi}

  def assess(bars, bias, zones, now) do
    slot = CandleClock.closed_at(now)

    bars =
      bars
      |> Enum.filter(&(DateTime.compare(DateTime.add(&1.open_time, 900), slot) != :gt))
      |> Enum.sort_by(& &1.open_time, DateTime)
      |> Enum.take(-50)

    base = %{
      blocked: true,
      action: "wait",
      state: "data_unavailable",
      reason: "Chờ chuỗi OHLC M15 đã đóng, hợp lệ, liên tục và đủ mới.",
      candle_closed_at: DateTime.to_iso8601(slot),
      pattern: nil,
      divergence: "none",
      indicators: nil,
      entry: nil,
      stop_loss: nil,
      take_profit: nil,
      atr: nil,
      zones: zones,
      zone: nil
    }

    valid =
      length(bars) >= 30 and Enum.all?(bars, &valid?/1) and
        Enum.chunk_every(bars, 2, 1, :discard)
        |> Enum.all?(fn [a, b] -> DateTime.diff(b.open_time, a.open_time) == 900 end)

    cond do
      not valid ->
        base

      DateTime.add(List.last(bars).open_time, 900) != slot ->
        base

      true ->
        last = List.last(bars)
        prev = Enum.at(bars, -2)
        i = Indicators.summarize_candles(bars, 900).indicators
        # One fixed target is retained when current quote is checked later.
        base = %{base | indicators: i, atr: i.atr_14, entry: last.close}
        touched = Enum.filter(zones, &Zoi.touch?(last, &1))

        found =
          Enum.find_value(touched, fn zone ->
            case pattern(last, prev, zone, bias.side) do
              nil -> nil
              name -> {name, zone}
            end
          end)

        cond do
          bias.side == "neutral" ->
            %{base | state: "idle", reason: bias.reason}

          touched == [] ->
            %{
              base
              | state: "wait_zoi",
                reason: "Chờ giá hồi về ZOI; chưa xét mẫu nến ngoài vùng."
            }

          is_nil(found) ->
            %{
              base
              | state: "wait_m15",
                reason: "Đã chạm ZOI; chờ pinbar, engulfing hoặc sweep–reclaim M15 cùng hướng H1."
            }

          true ->
            {name, zone} = found
            buffer = max(0.1 * i.atr_14, 0.01)

            stop =
              if bias.side == "buy",
                do: min(last.low, zone.low) - buffer,
                else: max(last.high, zone.high) + buffer

            risk = abs(last.close - stop)
            target = if bias.side == "buy", do: last.close + 2 * risk, else: last.close - 2 * risk
            # Cap at the nearest already-known opposing daily level.
            barriers =
              zones
              |> Enum.reject(&(&1.id == zone.id or &1.id == "sma20_h1"))
              |> Enum.map(& &1.mid)

            ahead =
              Enum.filter(barriers, fn p ->
                if bias.side == "buy", do: p > last.close, else: p < last.close
              end)

            target =
              Enum.reduce(ahead, target, fn p, t ->
                if bias.side == "buy", do: min(p, t), else: max(p, t)
              end)

            if risk <= 0 or risk > 5 * i.atr_14 or target <= 0 do
              %{
                base
                | state: "invalid_levels",
                  reason: "SL vượt 5 ATR M15 hoặc mức giá không hợp lệ."
              }
            else
              %{
                base
                | blocked: false,
                  action: bias.side,
                  state: "ready",
                  pattern: name,
                  zone: zone,
                  stop_loss: Float.round(stop, 2),
                  take_profit: Float.round(target, 2),
                  reason: "M15 đã đóng xác nhận #{name} tại #{zone.id}."
              }
            end
        end
    end
  end

  def pattern(b, p, z, side) when side in ["buy", "sell"] do
    span = b.high - b.low
    body = abs(b.close - b.open)
    buy = side == "buy"
    wick = if buy, do: min(b.open, b.close) - b.low, else: b.high - max(b.open, b.close)
    directional = if buy, do: b.close > b.open, else: b.close < b.open
    close_edge = if buy, do: b.high - b.close, else: b.close - b.low
    reject = if buy, do: b.close > z.mid, else: b.close < z.mid

    pin =
      span > 0 and directional and body <= 0.3 * span and wick >= 2 * body and wick >= 0.6 * span and
        close_edge <= 0.4 * span and reject

    engulf =
      directional and
        if(buy,
          do: p.close < p.open and b.open <= p.close and b.close >= p.open,
          else: p.close > p.open and b.open >= p.close and b.close <= p.open
        ) and reject

    reclaim =
      directional and
        if buy,
          do: b.low < z.low and b.close > z.mid and p.close >= z.low,
          else: b.high > z.high and b.close < z.mid and p.close <= z.high

    cond do
      pin -> "pullback_pinbar"
      engulf -> "pullback_engulfing"
      reclaim -> "sweep_reclaim"
      true -> nil
    end
  end

  def pattern(_, _, _, _), do: nil

  defp valid?(b),
    do:
      Map.get(b, :confirmed) == true and not Map.get(b, :approx, false) and
        not Map.get(b, :is_approximate, false) and rem(DateTime.to_unix(b.open_time), 900) == 0 and
        Enum.all?([b.open, b.high, b.low, b.close], &is_number/1) and b.low > 0 and
        b.high >= max(b.open, b.close) and b.low <= min(b.open, b.close)
end
