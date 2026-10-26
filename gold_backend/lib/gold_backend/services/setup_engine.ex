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

  def assess(bars, bias, zones, now, context \\ nil, seconds \\ 900) do
    slot = CandleClock.closed_at(now, seconds)

    bars =
      bars
      |> Enum.filter(&(DateTime.compare(DateTime.add(&1.open_time, seconds), slot) != :gt))
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
      candidate_log: [],
      branches: [],
      rejected_candidates: [],
      setup_kind: nil,
      rejection_reason: nil,
      invalidation_price: nil
    }

    valid =
      length(bars) >= 30 and Enum.all?(bars, &valid?(&1, seconds)) and
        GoldBackend.Services.MarketSchedule.consecutive?(bars, seconds)

    cond do
      not valid ->
        base

      DateTime.add(List.last(bars).open_time, seconds) != slot ->
        base

      true ->
        last = List.last(bars)
        prev = Enum.at(bars, -2)
        i = Indicators.summarize_candles(bars, seconds).indicators
        prior_atr = Indicators.candle_atr(Enum.drop(bars, -1))
        # One fixed target is retained when current quote is checked later.
        m15_targets =
          bars
          |> Enum.drop(-1)
          |> Zoi.swing_zones(prior_atr * 0.1, "m15_")
          |> Enum.map(&Map.put(&1, :target_only, true))

        breakouts =
          if seconds == 900,
            do: GoldBackend.Services.BreakoutZone.build(bars, prior_atr),
            else: []

        # Confirmed M15 swings may provide location when H1 history is missing.
        m15_locations =
          if zones == [] do
            Enum.map(m15_targets, fn z ->
              z
              |> Map.delete(:target_only)
              |> Map.put(:known_at, DateTime.to_iso8601(last.open_time))
            end)
          else
            []
          end

        zones = zones ++ m15_targets ++ m15_locations ++ breakouts
        base = %{base | indicators: i, atr: i.atr_14, entry: last.close, zones: zones}

        touched =
          Enum.filter(zones, fn z ->
            not Map.get(z, :target_only, false) and
              Enum.any?(Enum.take(bars, -3), fn b ->
                known = Map.get(z, :formed_at) || Map.get(z, :known_at)
                (is_nil(known) or known <= DateTime.to_iso8601(b.open_time)) and Zoi.touch?(b, z)
              end)
          end)

        # Structure near price may produce BUY or SELL. H1 indicator bias only
        # ranks preference and remains advisory.
        sides = ["buy", "sell"]

        candidates =
          for zone <- touched,
              side <- sides,
              name = pattern(last, prev, zone, side),
              name != nil,
              zone_intact?(bars, zone, side),
              not Map.has_key?(zone, :side) or (zone.side == side and name == "breakout_retest"),
              entry_side?(zone, side) or name == "breakout_retest",
              do: candidate(base, last, zone, name, side, bias, bars, seconds)

        branches = branch_statuses(candidates, touched, breakouts, sides, bias)
        rejected = Enum.filter(candidates, &(&1.rejection_reason == "stop_cap"))

        candidate_log =
          Enum.map(candidates, fn c ->
            c
            |> Map.take([
              :id,
              :action,
              :setup_kind,
              :zone,
              :pattern,
              :entry,
              :stop_loss,
              :take_profit,
              :take_profit_2,
              :invalidation_price,
              :formed_at,
              :expires_at,
              :zone_touched_at,
              :confirmation_at,
              :confirmation_close,
              :timeframe_seconds,
              :blocked,
              :reason,
              :rejection_reason
            ])
            |> Map.put(:h1_bias, bias.side)
            |> Map.put(:entry_zone, DecisionPlan.entry_zone(c, StrategyPolicy.assumed_spread()))
            |> Map.put(
              :estimated_rr,
              if(is_number(c.take_profit),
                do:
                  Float.round(
                    EntryQuality.assess(c, c.entry, StrategyPolicy.assumed_spread()).reward_risk,
                    2
                  )
              )
            )
            |> Map.put(
              :warnings,
              if(bias.side in ["buy", "sell"] and c.action != bias.side,
                do: ["Countertrend setup — ngược bias H1, ưu tiên mục tiêu ngắn."],
                else: []
              ) ++
                if(abs(c.entry - c.stop_loss) > 3, do: ["SL rộng hơn scalp target."], else: [])
            )
          end)

        base =
          base
          |> Map.put(:candidate_log, candidate_log)
          |> Map.merge(%{branches: branches, rejected_candidates: rejected})

        cond do
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
                  "Chờ pinbar, engulfing, sweep–reclaim hoặc phá vỡ–retest tại vùng gần giá."
            }

          true ->
            # Prefer H1-aligned candidates; counter-H1 structure still ranks if better quality.
            selected = Enum.max_by(candidates, &rank(&1, bias))

            %{
              selected
              | candidate_log: candidate_log,
                candidate_count: length(candidates),
                branches: branches,
                rejected_candidates: rejected
            }
        end
    end
  end

  defp zone_intact?(bars, zone, side) do
    recent = Enum.take(bars, -3)
    known = Map.get(zone, :formed_at) || Map.get(zone, :known_at)

    touch_index =
      recent
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {bar, i} ->
        if (is_nil(known) or known <= DateTime.to_iso8601(bar.open_time)) and
             Zoi.touch?(bar, zone),
           do: i
      end)

    is_integer(touch_index) and
      Enum.all?(Enum.slice(recent, touch_index, length(recent) - touch_index - 1), fn bar ->
        if side == "buy", do: bar.close > zone.low, else: bar.close < zone.high
      end)
  end

  defp candidate(base, last, zone, name, side, bias, bars, seconds) do
    touch =
      bars
      |> Enum.take(-3)
      |> Enum.reverse()
      |> Enum.find(fn b ->
        known = Map.get(zone, :formed_at) || Map.get(zone, :known_at)
        (is_nil(known) or known <= DateTime.to_iso8601(b.open_time)) and Zoi.touch?(b, zone)
      end)

    reference =
      if side == "buy",
        do: zone.low + (zone.high - zone.low) * 0.25,
        else: zone.high - (zone.high - zone.low) * 0.25

    buffer = max(0.1 * base.atr, 0.01)

    stop =
      if side == "buy",
        do: min(touch.low, min(last.low, zone.low)) - buffer,
        else: max(touch.high, max(last.high, zone.high)) + buffer

    risk = abs(reference - stop)

    barrier =
      base.zones
      |> Enum.reject(
        &(&1.id == zone.id or &1.id == "sma20_h1" or Map.get(&1, :entry_only, false))
      )
      |> Enum.filter(fn z ->
        if side == "buy",
          do:
            z.id != "previous_day_low" and not String.contains?(z.id, "swing_low") and
              z.mid > reference,
          else:
            z.id != "previous_day_high" and not String.contains?(z.id, "swing_high") and
              z.mid < reference
      end)
      |> Enum.min_by(
        fn z -> {if(side == "buy", do: z.low - reference, else: reference - z.high), z.id} end,
        fn -> nil end
      )

    scalp_target = if side == "buy", do: reference + 5.0, else: reference - 5.0

    target =
      if barrier,
        do:
          if(side == "buy",
            do: min(scalp_target, barrier.low),
            else: max(scalp_target, barrier.high)
          ),
        else: scalp_target

    target2 = if side == "buy", do: reference + 8.0, else: reference - 8.0

    target2 =
      if barrier && if(side == "buy", do: barrier.low < target2, else: barrier.high > target2),
        do: nil,
        else: target2

    base =
      %{
        base
        | action: side,
          entry: Float.round(reference * 1.0, 2),
          pattern: name,
          setup_kind:
            cond do
              name == "breakout_retest" -> "breakout_retest"
              bias.side in ["buy", "sell"] and bias.side != side -> "countertrend_reversal"
              true -> "trend_pullback"
            end,
          invalidation_price: if(side == "buy", do: zone.low, else: zone.high),
          zone: zone,
          barrier: barrier,
          stop_loss: Float.round(stop, 2),
          take_profit: if(target, do: Float.round(target * 1.0, 2))
      }
      |> Map.merge(%{
        timeframe_seconds: seconds,
        zone_id: zone.id,
        zone_touched_at: DateTime.to_iso8601(DateTime.add(touch.open_time, seconds)),
        confirmation_at: base.candle_closed_at,
        confirmation_close: last.close,
        take_profit_2: if(target2 && target2 > 0, do: Float.round(target2 * 1.0, 2)),
        zone_valid_until: DateTime.to_iso8601(DateTime.add(touch.open_time, 3 * seconds))
      })
      |> GoldBackend.Services.SetupLifecycle.identify()

    if risk <= 0 or risk > 5.0 or stop <= 0 or
         abs(target - reference) < 5.0 - 1.0e-9 or
         (is_number(target) and target <= 0) do
      %{
        base
        | state: "invalid_levels",
          reason: "SL vượt 5 USD, mục tiêu bị cản trước 5 USD hoặc mức giá không hợp lệ.",
          rejection_reason:
            cond do
              risk > 5.0 -> "stop_cap"
              abs(target - reference) < 5.0 - 1.0e-9 -> "target_blocked"
              true -> "invalid_price"
            end
      }
    else
      %{
        base
        | blocked: false,
          state: "ready",
          supporting_evidence: MarketStructure.evidence(base.technical_context, side, zone),
          reason:
            "#{if seconds == 300, do: "M5", else: "M15"} đã đóng xác nhận #{pattern_label(name)} tại #{zone.id}."
      }
    end
  end

  defp branch_statuses(candidates, touched, breakouts, sides, _bias) do
    for kind <- ["trend_pullback", "breakout_retest", "countertrend_reversal"], side <- sides do
      matches = Enum.filter(candidates, &(&1.setup_kind == kind and &1.action == side))

      touched_branch =
        Enum.any?(touched, fn z ->
          if kind in ["trend_pullback", "countertrend_reversal"],
            do: not Map.has_key?(z, :side) and entry_side?(z, side),
            else: Map.get(z, :side) == side
        end)

      {status, reason} =
        cond do
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

  def select(candidates, bias), do: Enum.max_by(candidates, &rank(&1, bias))

  defp rank(%{blocked: true}, _bias), do: {0, 0, 0.0, 0.0, 0, ""}

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

    {tier, aligned, -(s.zone.high - s.zone.low), if(quality, do: quality.reward_risk, else: 0.0),
     Enum.count(s.supporting_evidence, & &1.supports), s.zone.id}
  end

  defp entry_side?(zone, side) do
    cond do
      zone.id in ["previous_day_high", "aoi_high_h1"] or
          (String.starts_with?(zone.id, "swing_high") or
             String.starts_with?(zone.id, "m15_swing_high")) ->
        side == "sell"

      zone.id in ["previous_day_low", "aoi_low_h1"] or
          (String.starts_with?(zone.id, "swing_low") or
             String.starts_with?(zone.id, "m15_swing_low")) ->
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

  defp valid?(b, seconds),
    do:
      Map.get(b, :confirmed) == true and not Map.get(b, :approx, false) and
        not Map.get(b, :is_approximate, false) and
        rem(DateTime.to_unix(b.open_time), seconds) == 0 and
        Enum.all?([b.open, b.high, b.low, b.close], &is_number/1) and b.low > 0 and
        b.high >= max(b.open, b.close) and b.low <= min(b.open, b.close)
end
