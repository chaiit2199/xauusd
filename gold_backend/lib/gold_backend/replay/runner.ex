defmodule GoldBackend.Replay.Runner do
  @moduledoc "Offline chronological M15 replay. Inputs must be closed candles and real timestamped quotes."
  alias GoldBackend.Services.{BiasEngine, Indicators, SignalSimulator}

  def run(%{candles: candles, quotes: quotes} = dataset, mode, opts \\ [])
      when mode in [:old, :new] do
    evaluation_from = Keyword.get(opts, :evaluation_from)
    m15 = Enum.filter(candles, &(&1.timeframe == 900))
    h1 = Enum.filter(candles, &(&1.timeframe == 3600))

    lifecycle =
      if mode == :old,
        do: GoldBackend.Replay.Legacy.SetupLifecycle,
        else: GoldBackend.Services.SetupLifecycle

    planner =
      if mode == :old,
        do: GoldBackend.Replay.Legacy.StrategyPlan,
        else: GoldBackend.Services.StrategyPlan

    {observations, candidates, decisions} =
      Enum.reduce(m15, {%{}, %{}, 0}, fn bar, {acc, candidates, count} ->
        at = DateTime.add(bar.open_time, 900)

        prior_m15 =
          Enum.filter(m15, &(DateTime.compare(DateTime.add(&1.open_time, 900), at) != :gt))
          |> Enum.take(-200)

        prior_h1 =
          Enum.filter(h1, &(DateTime.compare(DateTime.add(&1.open_time, 3600), at) != :gt))
          |> Enum.take(-200)

        if length(prior_m15) >= 30 and length(prior_h1) >= 50 and
             (is_nil(evaluation_from) or DateTime.compare(at, evaluation_from) != :lt) do
          bias_module =
            if mode == :old, do: GoldBackend.Replay.Legacy.BiasEngine, else: BiasEngine

          indicators_module =
            if mode == :old, do: GoldBackend.Replay.Legacy.Indicators, else: Indicators

          calendar_module =
            if mode == :old,
              do: GoldBackend.Replay.Legacy.EconomicCalendar,
              else: GoldBackend.Services.EconomicCalendar

          bias = bias_module.assess(prior_h1, at)
          setup = lifecycle.assess(prior_m15, prior_h1, bias, at, [])

          candidates =
            Enum.reduce(Map.get(setup, :candidate_log, []), candidates, fn candidate, seen ->
              if is_binary(Map.get(candidate, :id)) and
                   in_window?(Map.get(candidate, :formed_at), evaluation_from),
                 do: Map.put_new(seen, candidate.id, candidate),
                 else: seen
            end)

          if is_binary(Map.get(setup, :id)) and
               in_window?(Map.get(setup, :formed_at), evaluation_from) do
            indicators = indicators_module.summarize_candles(prior_h1, 3600).indicators
            # Only a quote whose provider timestamp is at or before evaluation may be used.
            quote =
              quotes |> Enum.filter(&(DateTime.compare(&1.timestamp, at) != :gt)) |> List.last()

            calendar = Map.get(dataset, :calendar)
            calendar_ok = calendar_available?(calendar, at)

            events =
              if calendar_ok,
                do:
                  Enum.filter(
                    calendar.events,
                    &(DateTime.compare(&1.known_at, at) != :gt and &1.impact == "High" and
                        &1.country in ["USD", "All"])
                  ),
                else: []

            event = calendar_module.blocking(events, at)

            plan =
              planner.build(indicators, setup.entry,
                bias: bias,
                m15_setup: setup,
                as_of: at,
                quote: quote,
                calendar_status: if(calendar_ok, do: "ok", else: "unavailable"),
                calendar_valid_until: if(calendar_ok, do: DateTime.to_iso8601(calendar.until)),
                blocking_event: event
              )

            if not Map.has_key?(acc, setup.id) do
              zone = get_in(plan, [:decision_plan, :entry_zone])

              value = %{
                id: setup.id,
                side: setup.action,
                setup_type: Map.get(setup, :setup_kind),
                formed_at: setup.formed_at,
                expires_at: setup.expires_at,
                reference: setup.entry,
                stop: setup.stop_loss,
                tp1: setup.take_profit,
                tp2: Map.get(setup, :take_profit_2),
                zone: zone,
                plan_ready: Map.get(plan, :planning_action) in ["buy", "sell"],
                readiness:
                  cond do
                    not calendar_ok ->
                      "unknown_calendar"

                    not GoldBackend.Services.EntryQuality.fresh_quote?(quote, at) ->
                      "unknown_quote"

                    plan.action in ["buy", "sell"] ->
                      "ready"

                    true ->
                      "blocked"
                  end,
                confirmation_close: Map.get(setup, :confirmation_close),
                invalidation: Map.get(setup, :invalidation_price)
              }

              {Map.put(acc, setup.id, value), candidates, count + 1}
            else
              prior = acc[setup.id]

              readiness =
                cond do
                  plan.action in ["buy", "sell"] and calendar_ok -> "ready"
                  prior.readiness == "ready" -> "ready"
                  String.starts_with?(prior.readiness, "unknown") -> prior.readiness
                  not calendar_ok -> "unknown_calendar"
                  not GoldBackend.Services.EntryQuality.fresh_quote?(quote, at) -> "unknown_quote"
                  true -> "blocked"
                end

              updated = %{
                prior
                | readiness: readiness,
                  plan_ready:
                    prior.plan_ready or Map.get(plan, :planning_action) in ["buy", "sell"]
              }

              {Map.put(acc, setup.id, updated), candidates, count + 1}
            end
          else
            {acc, candidates, count + 1}
          end
        else
          {acc, candidates, count}
        end
      end)

    end_at =
      case List.last(m15) do
        nil -> nil
        b -> DateTime.add(b.open_time, 900)
      end

    rows =
      observations
      |> Map.values()
      |> Enum.sort_by(& &1.formed_at)
      |> Enum.map(&outcome(&1, m15, end_at))

    candidate_rows =
      candidates
      |> Map.values()
      |> Enum.map(fn c ->
        row = %{
          id: c.id,
          side: c.action,
          setup_type: Map.get(c, :setup_kind),
          formed_at: Map.get(c, :formed_at),
          expires_at: Map.get(c, :expires_at),
          reference: c.entry,
          stop: c.stop_loss,
          tp1: c.take_profit,
          tp2: Map.get(c, :take_profit_2),
          zone: Map.get(c, :entry_zone),
          blocked: c.blocked,
          confirmation_close: Map.get(c, :confirmation_close),
          invalidation: Map.get(c, :invalidation_price),
          rejection_reason: Map.get(c, :rejection_reason),
          estimated_rr: candidate_rr(c),
          stop_distance:
            if(is_number(c.entry) and is_number(c.stop_loss), do: abs(c.entry - c.stop_loss)),
          reward_distance:
            if(is_number(c.entry) and is_number(c.take_profit), do: abs(c.take_profit - c.entry)),
          entry_to_invalidation:
            if(is_number(c.entry) and is_number(Map.get(c, :invalidation_price)),
              do: abs(c.entry - c.invalidation_price)
            ),
          close_to_entry_zone:
            zone_distance(Map.get(c, :confirmation_close), Map.get(c, :entry_zone))
        }

        if c.blocked,
          do:
            Map.merge(row, %{
              outcome: "rejected",
              tp2_status: nil,
              simulated_entry: nil,
              exit_bar_at: nil
            }),
          else: outcome(row, m15, end_at)
      end)

    %{
      strategy: Atom.to_string(mode),
      daily: daily_stats(m15, rows, evaluation_from),
      point_in_time: "not_fully_point_in_time",
      stages: %{
        technical_plan: Enum.count(rows, & &1.plan_ready),
        entry_eligible_observed: Enum.count(rows, &(&1.readiness == "ready")),
        simulated_outcome: Enum.frequencies_by(rows, & &1.outcome)
      },
      evaluated_cycles: decisions,
      data_quality: %{
        m15_candles: length(m15),
        h1_candles: length(h1),
        status:
          if(decisions == 0, do: "insufficient_data", else: "requires_gap_and_source_review")
      },
      selected_setups: if(decisions == 0, do: nil, else: length(rows)),
      candidate_count: if(decisions == 0, do: nil, else: map_size(candidates)),
      candidates_by_side: candidates |> Map.values() |> Enum.frequencies_by(& &1.action),
      candidates_by_setup:
        candidates
        |> Map.values()
        |> Enum.frequencies_by(&(Map.get(&1, :setup_kind) || "unknown")),
      candidates_rejected:
        candidates |> Map.values() |> Enum.count(&Map.get(&1, :blocked, false)),
      candidate_count_note:
        "Distinct detected confirmations observed in replay; excludes branches without a confirmation.",
      candidate_outcomes: Enum.frequencies_by(candidate_rows, & &1.outcome),
      candidate_tp2_hit: Enum.count(candidate_rows, &(&1.tp2_status == "hit")),
      candidate_metrics: metrics(candidate_rows),
      focus_groups:
        Map.merge(group_metrics(candidate_rows), %{
          sl_le_3:
            Enum.count(candidate_rows, &(is_number(&1.stop_distance) and &1.stop_distance <= 3)),
          tp1_ge_5:
            Enum.count(
              candidate_rows,
              &(is_number(&1.reward_distance) and &1.reward_distance >= 5 - 1.0e-9)
            ),
          tp1_ge_10:
            Enum.count(
              candidate_rows,
              &(is_number(&1.reward_distance) and &1.reward_distance >= 10)
            ),
          rr_below_1_5_tp_5_to_10:
            Enum.count(
              candidate_rows,
              &(is_number(&1.estimated_rr) and &1.estimated_rr < 1.5 and
                  is_number(&1.reward_distance) and &1.reward_distance >= 5 - 1.0e-9 and
                  &1.reward_distance <= 10)
            ),
          countertrend: Enum.count(candidate_rows, &(&1.setup_type == "countertrend_reversal"))
        }),
      candidate_observations: candidate_rows,
      counts_by_side: Enum.frequencies_by(rows, & &1.side),
      counts_by_setup: Enum.frequencies_by(rows, &(&1.setup_type || "unknown")),
      plan_ready: Enum.count(rows, & &1.plan_ready),
      ready_to_enter:
        if(
          is_nil(Map.get(dataset, :calendar)) or quotes == [] or
            Enum.any?(rows, &String.starts_with?(&1.readiness, "unknown")),
          do: nil,
          else: Enum.count(rows, &(&1.readiness == "ready"))
        ),
      ready_to_enter_observed: Enum.count(rows, &(&1.readiness == "ready")),
      readiness_unknown: Enum.count(rows, &String.starts_with?(&1.readiness, "unknown")),
      readiness_note:
        "READY requires a fresh recorded quote and verified calendar coverage; unknown observations are not counted as zero.",
      outcomes: Enum.frequencies_by(rows, & &1.outcome),
      metrics: metrics(rows),
      observations: rows,
      methodology:
        "Candidates and selected setups are reported separately; M15 closed OHLC touch model, no fills, no future data in detection. Missing bars and intrabar conflicts remain unknown. Loss streak counts settled candidates by exit bar and ignores unknown outcomes."
    }
  end

  defp daily_stats(m15, rows, from) do
    dates =
      m15
      |> Enum.map(&DateTime.add(&1.open_time, 900))
      |> Enum.filter(&(is_nil(from) or DateTime.compare(&1, from) != :lt))
      |> Enum.map(&DateTime.to_date/1)
      |> Enum.uniq()

    plan_dates =
      rows
      |> Enum.filter(& &1.plan_ready)
      |> Enum.map(fn row ->
        {:ok, at, _} = DateTime.from_iso8601(row.formed_at)
        DateTime.to_date(at)
      end)
      |> MapSet.new()

    %{
      observed_dates: length(dates),
      dates_without_plan: Enum.count(dates, &(not MapSet.member?(plan_dates, &1))),
      plans_per_observed_date:
        if(dates == [], do: nil, else: Enum.count(rows, & &1.plan_ready) / length(dates)),
      note:
        "Observed M15 dates include warmup and can include partial sessions; missing dates cannot be counted."
    }
  end

  defp in_window?(_, nil), do: true

  defp in_window?(value, from) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> DateTime.compare(at, from) != :lt
      _ -> false
    end
  end

  defp in_window?(_, _), do: false

  defp calendar_available?(nil, _at), do: false

  defp calendar_available?(calendar, at) do
    DateTime.compare(calendar.from, DateTime.add(at, -1800)) != :gt and
      DateTime.compare(calendar.until, DateTime.add(at, 900)) != :lt
  end

  defp outcome(row, bars, end_at) do
    with %{low: low, high: high} <- row.zone,
         true <- is_number(row.stop) and is_number(row.tp1),
         {:ok, formed, _} <- DateTime.from_iso8601(row.formed_at),
         {:ok, expiry, _} <- DateTime.from_iso8601(row.expires_at),
         true <- not is_nil(end_at) do
      signal = %{
        published_at: formed,
        entry_expires_at: expiry,
        horizon_at: DateTime.add(formed, 7200),
        cancelled_at: nil,
        side: row.side,
        entry_low: low,
        entry_high: high,
        stop_loss: row.stop,
        take_profit: row.tp1,
        take_profit_2: row.tp2,
        invalidation: Map.get(row, :invalidation)
      }

      result = SignalSimulator.evaluate(signal, bars, end_at)

      Map.merge(row, %{
        outcome: result.status,
        tp2_status: Map.get(result, :tp2_status),
        simulated_entry: result.entry_price,
        exit_bar_at: result.exit_bar_at
      })
    else
      _ ->
        Map.merge(row, %{
          outcome: "not_simulatable",
          tp2_status: nil,
          simulated_entry: nil,
          exit_bar_at: nil
        })
    end
  end

  def metrics(rows) do
    settled =
      rows
      |> Enum.filter(&(&1.outcome in ["tp_first", "sl_first"]))
      |> Enum.sort_by(&{&1.exit_bar_at, &1.formed_at, &1.id})

    wins = Enum.count(settled, &(&1.outcome == "tp_first"))

    {_, streak} =
      Enum.reduce(settled, {0, 0}, fn row, {current, longest} ->
        next = if row.outcome == "sl_first", do: current + 1, else: 0
        {next, max(longest, next)}
      end)

    {_, _, max_drawdown} =
      Enum.reduce(settled, {0.0, 0.0, 0.0}, fn row, {equity, peak, drawdown} ->
        change =
          if row.outcome == "tp_first",
            do: abs(row.tp1 - row.simulated_entry),
            else: -abs(row.stop - row.simulated_entry)

        equity = equity + change
        peak = max(peak, equity)
        {equity, peak, max(drawdown, peak - equity)}
      end)

    %{
      settled: length(settled),
      wins: wins,
      losses: length(settled) - wins,
      win_rate: if(settled == [], do: nil, else: wins / length(settled)),
      maximum_losing_streak: if(settled == [], do: nil, else: streak),
      reference_price_drawdown_usd_per_oz: if(settled == [], do: nil, else: max_drawdown),
      average_reward:
        average(
          for r <- settled,
              r.outcome == "tp_first" and is_number(r.simulated_entry),
              do: abs(r.tp1 - r.simulated_entry)
        ),
      expectancy:
        if(settled == [],
          do: nil,
          else:
            Enum.sum(
              Enum.map(settled, fn r ->
                if r.outcome == "tp_first",
                  do: abs(r.tp1 - r.simulated_entry),
                  else: -abs(r.stop - r.simulated_entry)
              end)
            ) / length(settled)
        ),
      average_stop:
        average(
          for r <- settled,
              r.outcome == "sl_first" and is_number(r.simulated_entry),
              do: abs(r.stop - r.simulated_entry)
        )
    }
  end

  defp group_metrics(rows) do
    groups = %{
      sl_le_2: fn r -> is_number(r.stop_distance) and r.stop_distance <= 2 end,
      sl_2_to_3: fn r ->
        is_number(r.stop_distance) and r.stop_distance > 2 and r.stop_distance <= 3
      end,
      sl_3_to_5: fn r ->
        is_number(r.stop_distance) and r.stop_distance > 3 and r.stop_distance <= 5
      end,
      sl_gt_5: fn r -> is_number(r.stop_distance) and r.stop_distance > 5 end,
      tp1_under_5: fn r -> is_number(r.reward_distance) and r.reward_distance < 5 - 1.0e-9 end,
      tp2_ge_10: fn r ->
        is_number(r.reference) and is_number(r.tp2) and abs(r.tp2 - r.reference) >= 10
      end,
      rr_under_1_2: fn r -> is_number(r.estimated_rr) and r.estimated_rr < 1.2 end,
      rr_1_2_to_1_5: fn r ->
        is_number(r.estimated_rr) and r.estimated_rr >= 1.2 and r.estimated_rr < 1.5
      end,
      rr_ge_1_5: fn r -> is_number(r.estimated_rr) and r.estimated_rr >= 1.5 end,
      scalp_rr_1_2_to_1_5: fn r ->
        is_number(r.estimated_rr) and r.estimated_rr >= 1.2 and r.estimated_rr < 1.5 and
          is_number(r.stop_distance) and r.stop_distance >= 2 and r.stop_distance <= 3 and
          is_number(r.reward_distance) and r.reward_distance >= 5 - 1.0e-9
      end
    }

    Map.new(groups, fn {name, filter} ->
      subset = Enum.filter(rows, filter)

      {name,
       %{
         count: length(subset),
         outcomes: Enum.frequencies_by(subset, & &1.outcome),
         metrics: metrics(subset),
         sample_status:
           if(Enum.count(subset, &(&1.outcome in ["tp_first", "sl_first"])) < 30,
             do: "insufficient_sample",
             else: "descriptive_only"
           )
       }}
    end)
  end

  defp candidate_rr(c) do
    if is_number(c.entry) and is_number(c.stop_loss) and is_number(c.take_profit) do
      risk = abs(c.entry - c.stop_loss)
      reward = if c.action == "buy", do: c.take_profit - c.entry, else: c.entry - c.take_profit
      if risk > 0, do: (reward - 0.4) / (risk + 0.4)
    end
  end

  defp zone_distance(price, %{low: low, high: high}) when is_number(price) do
    cond do
      price < low -> low - price
      price > high -> price - high
      true -> 0.0
    end
  end

  defp zone_distance(_, _), do: nil

  defp average([]), do: nil
  defp average(values), do: Enum.sum(values) / length(values)
end
