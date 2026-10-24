defmodule GoldBackend.Services.SetupEngine do
  @moduledoc "Closed provider M15 triggers at a pre-existing ZOI; alternatives, not cumulative requirements."
  alias GoldBackend.Services.{
    CandleClock,
    DecisionPlan,
    EntryQuality,
    Indicators,
    MarketStructure,
    StrategyPolicy,
    Zoi
  }

  def assess(bars, bias, zones, now, context \\ nil) do
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
      zone: nil,
      barrier: nil,
      technical_context: context,
      supporting_evidence: [],
      candidate_count: 0,
      branches: [],
      rejected_candidates: [],
      setup_kind: nil,
      rejection_reason: nil,
      invalidation_price: nil
    }

    valid =
      length(bars) >= 30 and Enum.all?(bars, &valid?/1) and
        GoldBackend.Services.MarketSchedule.consecutive?(bars, 900)

    cond do
      not valid ->
        base

      DateTime.add(List.last(bars).open_time, 900) != slot ->
        base

      true ->
        last = List.last(bars)
        prev = Enum.at(bars, -2)
        i = Indicators.summarize_candles(bars, 900).indicators
        prior_atr = Indicators.candle_atr(Enum.drop(bars, -1))
        # One fixed target is retained when current quote is checked later.
        m15_targets =
          bars
          |> Enum.drop(-1)
          |> Zoi.swing_zones(prior_atr * 0.1, "m15_")
          |> Enum.map(&Map.put(&1, :target_only, true))

        breakouts = GoldBackend.Services.BreakoutZone.build(bars, prior_atr)
        zones = zones ++ m15_targets ++ breakouts
        base = %{base | indicators: i, atr: i.atr_14, entry: last.close, zones: zones}

        touched =
          Enum.filter(zones, &(not Map.get(&1, :target_only, false) and Zoi.touch?(last, &1)))

        # Structure near price may produce BUY or SELL. H1 indicator bias only
        # ranks preference and remains advisory; when H1 is neutral, only breakout–retest.
        sides = ["buy", "sell"]

        candidates =
          for zone <- touched,
              side <- sides,
              name = pattern(last, prev, zone, side),
              name != nil,
              bias.side != "neutral" or name == "breakout_retest",
              not Map.has_key?(zone, :side) or (zone.side == side and name == "breakout_retest"),
              entry_side?(zone, side) or name == "breakout_retest",
              do: candidate(base, last, zone, name, side)

        branches = branch_statuses(candidates, touched, breakouts, sides, bias)
        rejected = Enum.filter(candidates, &(&1.rejection_reason == "stop_cap"))
        base = %{base | branches: branches, rejected_candidates: rejected}

        cond do
          not StrategyPolicy.h1_ready?(bias) ->
            %{
              base
              | state: "data_unavailable",
                reason: "Chưa đủ dữ liệu H1 hợp lệ; không coi thiếu dữ liệu là H1 trung tính."
            }

          Map.get(bias, :regime) == "transition" ->
            %{base | state: "idle", reason: bias.reason}

          touched == [] ->
            %{
              base
              | state: "wait_zoi",
                reason:
                  "Chưa có tương tác vùng phù hợp; nhánh hồi và breakout–retest đang được xét độc lập."
            }

          candidates == [] ->
            %{
              base
              | state: "wait_m15",
                reason:
                  if(bias.side == "neutral",
                    do: "H1 trung tính; chỉ xét phá vỡ–retest M15 đã xác nhận.",
                    else:
                      "Chờ pinbar, engulfing, sweep–reclaim hoặc phá vỡ–retest M15 tại vùng gần giá."
                  )
            }

          true ->
            # Prefer H1-aligned candidates; counter-H1 structure still ranks if better quality.
            selected = Enum.max_by(candidates, &rank(&1, bias))

            %{
              selected
              | candidate_count: length(candidates),
                branches: branches,
                rejected_candidates: rejected
            }
        end
    end
  end

  defp candidate(base, last, zone, name, side) do
    buffer = max(0.1 * base.atr, 0.01)

    stop =
      if side == "buy",
        do: min(last.low, zone.low) - buffer,
        else: max(last.high, zone.high) + buffer

    risk = abs(last.close - stop)

    barrier =
      base.zones
      |> Enum.reject(
        &(&1.id == zone.id or &1.id == "sma20_h1" or Map.get(&1, :entry_only, false))
      )
      |> Enum.filter(fn z ->
        if side == "buy",
          do:
            z.id != "previous_day_low" and not String.contains?(z.id, "swing_low") and
              z.mid > last.close,
          else:
            z.id != "previous_day_high" and not String.contains?(z.id, "swing_high") and
              z.mid < last.close
      end)
      |> Enum.min_by(
        fn z -> {if(side == "buy", do: z.low - last.close, else: last.close - z.high), z.id} end,
        fn -> nil end
      )

    target = if barrier, do: if(side == "buy", do: barrier.low, else: barrier.high)

    base =
      %{
        base
        | action: side,
          pattern: name,
          setup_kind:
            if(name == "breakout_retest", do: "breakout_retest", else: "trend_pullback"),
          invalidation_price: if(side == "buy", do: zone.low, else: zone.high),
          zone: zone,
          barrier: barrier,
          stop_loss: Float.round(stop, 2),
          take_profit: if(target, do: Float.round(target * 1.0, 2))
      }
      |> GoldBackend.Services.SetupLifecycle.identify()

    if risk <= 0 or risk > StrategyPolicy.max_stop_atr() * base.atr or stop <= 0 or
         (is_number(target) and target <= 0) do
      %{
        base
        | state: "invalid_levels",
          reason: "SL vượt 5 ATR M15 hoặc mức giá không hợp lệ.",
          rejection_reason:
            if(risk > StrategyPolicy.max_stop_atr() * base.atr,
              do: "stop_cap",
              else: "invalid_price"
            )
      }
    else
      %{
        base
        | blocked: false,
          state: "ready",
          supporting_evidence: MarketStructure.evidence(base.technical_context, side, zone),
          reason: "M15 đã đóng xác nhận #{pattern_label(name)} tại #{zone.id}."
      }
    end
  end

  defp branch_statuses(candidates, touched, breakouts, sides, bias) do
    for kind <- ["trend_pullback", "breakout_retest"], side <- sides do
      matches = Enum.filter(candidates, &(&1.setup_kind == kind and &1.action == side))

      touched_branch =
        Enum.any?(touched, fn z ->
          if kind == "trend_pullback",
            do: not Map.has_key?(z, :side) and entry_side?(z, side),
            else: Map.get(z, :side) == side
        end)

      {status, reason} =
        cond do
          not StrategyPolicy.h1_ready?(bias) ->
            {"unknown", "Chờ dữ liệu H1 hợp lệ."}

          Map.get(bias, :regime) == "transition" ->
            {"unknown", "H1 đang chuyển hướng; chờ xác nhận bối cảnh."}

          kind == "trend_pullback" and bias.side == "neutral" ->
            {"warning", "H1 trung tính: chưa xét lệnh hồi theo xu hướng."}

          Enum.any?(matches, &(not &1.blocked)) ->
            {"pass", "Đã có xác nhận M15; còn kiểm tra giá mới, lịch tin và giới hạn rủi ro."}

          matches != [] ->
            {"blocked", "Có mẫu xác nhận nhưng SL vượt giới hạn hoặc mức giá không hợp lệ."}

          touched_branch ->
            {"unknown", "Đã chạm vùng của nhánh; chờ mẫu M15 xác nhận."}

          kind == "breakout_retest" and not Enum.any?(breakouts, &(&1.side == side)) ->
            {"unknown", "Chờ phá vỡ hợp lệ và retest; không vào theo phá vỡ chưa retest."}

          kind == "breakout_retest" ->
            {"unknown", "Đã có vùng sau phá vỡ; chờ retest hợp lệ."}

          true ->
            {"unknown", "Chờ giá tương tác vùng hồi theo xu hướng."}
        end

      %{kind: kind, side: side, status: status, reason: reason, candidate_count: length(matches)}
    end
  end

  defp rank(%{blocked: true}, _bias), do: {0, 0, 0.0, 0, ""}

  defp rank(s, bias) do
    cost = StrategyPolicy.assumed_spread()
    quality = if s.take_profit, do: EntryQuality.assess(s, s.entry, cost)
    aligned = if StrategyPolicy.direction_aligned?(s, bias), do: 1, else: 0

    tier =
      cond do
        quality && quality.target_reached -> 0
        quality && quality.levels_ok && quality.structure_ok && quality.reward_risk_ok -> 4
        DecisionPlan.entry_zone(s, cost) != nil -> 3
        quality != nil -> 2
        true -> 1
      end

    {tier, aligned, if(quality, do: quality.reward_risk, else: 0.0),
     Enum.count(s.supporting_evidence, & &1.supports), s.zone.id}
  end

  defp entry_side?(zone, side) do
    cond do
      zone.id in ["previous_day_high", "aoi_high_h1"] or
          String.starts_with?(zone.id, "swing_high") ->
        side == "sell"

      zone.id in ["previous_day_low", "aoi_low_h1"] or String.starts_with?(zone.id, "swing_low") ->
        side == "buy"

      true ->
        true
    end
  end

  defp pattern_label("breakout_retest"), do: "phá vỡ–retest"
  defp pattern_label("pullback_pinbar"), do: "pinbar"
  defp pattern_label("pullback_engulfing"), do: "engulfing"
  defp pattern_label("sweep_reclaim"), do: "sweep–reclaim"

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

    # Two closed candles: a body crosses the zone, then a directional retest
    # holds its far edge. The zone must already exist before the breakout bar.
    known_before_break =
      is_nil(Map.get(z, :known_at)) or
        (Map.has_key?(p, :open_time) and z.known_at <= DateTime.to_iso8601(p.open_time))

    retest =
      directional and known_before_break and
        if buy,
          do:
            p.open <= z.high and p.close > z.high and b.low <= z.high and b.low > z.low and
              b.close > z.high,
          else:
            p.open >= z.low and p.close < z.low and b.high >= z.low and b.high < z.high and
              b.close < z.low

    cond do
      retest -> "breakout_retest"
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
