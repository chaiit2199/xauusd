defmodule GoldBackend.Services.SignalHistory do
  @moduledoc "Persist and expose outcomes of published signals, separate from account trades."
  import Ecto.Query
  alias GoldBackend.Repo
  alias GoldBackend.Trading.MarketCandle
  alias GoldBackend.Services.{SignalSimulator, StrategyPolicy}

  def track(
        %{decision_plan: %{entry_zone: %{low: _, high: _}, expires_at: expiry}} = plan,
        published_at
      ) do
    {:ok, expires_at, _} = DateTime.from_iso8601(expiry)
    stamp = DateTime.utc_now()

    Repo.insert_all(
      "signal_outcomes",
      [
        %{
          setup_id: plan.setup_id,
          published_at: published_at,
          entry_expires_at: expires_at,
          horizon_at: DateTime.add(published_at, StrategyPolicy.simulation_seconds()),
          result: %{"status" => "pending_entry", "entry_touched" => false},
          inserted_at: stamp,
          updated_at: stamp
        }
      ],
      on_conflict: :nothing
    )

    :ok
  end

  def track(_, _), do: :ok

  def reconcile(%{warmup: true}), do: :ok
  def reconcile(%{m15_setup: %{state: "data_unavailable"}}), do: :ok
  def reconcile(%{plan: %{bias: %{adx: nil}}}), do: :ok

  def reconcile(context) do
    rows =
      Repo.all(
        from o in "signal_outcomes",
          join: s in "strategy_setups",
          on: o.setup_id == s.setup_id,
          where: o.entry_expires_at > ^context.analysis_at,
          select: %{id: o.setup_id, snapshot: s.snapshot}
      )

    Enum.each(rows, fn row ->
      setup = row.snapshot |> Jason.encode!() |> Jason.decode!(keys: :atoms!)

      updated =
        GoldBackend.Services.SetupLifecycle.validate(
          setup,
          context.m15_candles,
          context.plan.bias,
          context.analysis_at,
          context.events
        )

      if updated.state == "invalidated" do
        stamp = DateTime.truncate(context.analysis_at, :second)

        Repo.insert_all(
          "strategy_invalidations",
          [
            %{
              setup_id: row.id,
              state: "invalidated",
              reason: updated.reason,
              inserted_at: stamp,
              updated_at: stamp
            }
          ],
          on_conflict: :nothing
        )
      end
    end)
  end

  def refresh(now \\ DateTime.utc_now()) do
    # Retain settled outcomes forever; retry missing observations for seven days.
    cutoff = DateTime.add(now, -7, :day)

    rows =
      Repo.all(
        from o in "signal_outcomes",
          join: s in "strategy_signals",
          on: o.setup_id == s.setup_id,
          left_join: i in "strategy_invalidations",
          on: i.setup_id == s.setup_id,
          where:
            o.published_at >= ^cutoff or
              fragment("?->>'status' IN ('pending_entry', 'entry_touched')", o.result),
          select: %{
            id: o.setup_id,
            published_at: o.published_at,
            entry_expires_at: o.entry_expires_at,
            horizon_at: o.horizon_at,
            result: o.result,
            plan: s.plan,
            cancelled_at: i.inserted_at,
            cancellation: i.state
          }
      )

    Enum.each(rows, fn row ->
      if row.result["status"] in [nil, "pending_entry", "entry_touched", "data_gap"] do
        plan = row.plan
        zone = plan["decision_plan"]["entry_zone"]

        signal = %{
          published_at: utc(row.published_at),
          entry_expires_at: utc(row.entry_expires_at),
          horizon_at: utc(row.horizon_at),
          cancelled_at: if(row.cancellation == "invalidated", do: utc(row.cancelled_at)),
          side: plan["action"],
          entry_low: zone["low"],
          entry_high: zone["high"],
          stop_loss: plan["stop_loss"],
          take_profit: plan["take_profit"]
        }

        bars =
          Repo.all(
            from c in MarketCandle,
              where:
                c.source == "gold_api_ohlc" and c.timeframe == 900 and
                  c.open_time >= ^signal.published_at and c.open_time < ^signal.horizon_at,
              order_by: c.open_time
          )
          |> Enum.map(&MarketCandle.to_bar/1)

        result = SignalSimulator.evaluate(signal, bars, now) |> Jason.encode!() |> Jason.decode!()

        Repo.update_all(from(o in "signal_outcomes", where: o.setup_id == ^row.id),
          set: [result: result, updated_at: now]
        )
      end
    end)

    :ok
  end

  def list(now \\ DateTime.utc_now(), limit \\ 50) do
    rows =
      Repo.all(
        from s in "strategy_signals",
          left_join: o in "signal_outcomes",
          on: s.setup_id == o.setup_id,
          left_join: i in "strategy_invalidations",
          on: i.setup_id == s.setup_id,
          order_by: [desc: s.inserted_at, desc: s.id],
          limit: ^limit,
          select: %{
            setup_id: s.setup_id,
            plan: s.plan,
            published_at: o.published_at,
            fallback_at: s.inserted_at,
            expires_at: o.entry_expires_at,
            horizon_at: o.horizon_at,
            result: o.result,
            invalidation: i.state,
            reason: i.reason
          }
      )

    items =
      Enum.map(rows, fn row ->
        expiry = utc(row.expires_at) || parse(row.plan["setup_expires_at"])

        validity =
          cond do
            row.invalidation == "invalidated" ->
              "invalidated"

            row.invalidation == "expired" or (expiry && DateTime.compare(now, expiry) != :lt) ->
              "expired"

            is_nil(expiry) ->
              "unknown"

            true ->
              "active"
          end

        %{
          setup_id: row.setup_id,
          side: row.plan["action"],
          version: row.plan["strategy_version"],
          setup_kind: row.plan["setup_kind"] || "unknown",
          entry_admission: row.plan["entry_admission"] || "unclassified",
          published_at: iso(utc(row.published_at) || utc(row.fallback_at)),
          expires_at: iso(expiry),
          horizon_at: iso(utc(row.horizon_at)),
          validity: validity,
          validity_reason: row.reason,
          plan: row.plan["decision_plan"],
          result: row.result || %{"status" => "legacy", "entry_touched" => false},
          estimated_net_r: estimated_net_r(row.plan, row.result)
        }
      end)

    %{
      items: items,
      limit: limit,
      model: "m15-touch-v1",
      summary: Enum.frequencies_by(items, & &1.result["status"]),
      groups: summarize_groups(items)
    }
  end

  # Reference-price touch model; no fills, gap slippage, fees or account sizing.
  def estimated_net_r(plan, %{"status" => status, "entry_price" => entry})
      when status in ["tp_first", "sl_first"] and is_number(entry) do
    stop = plan["stop_loss"]
    target = plan["take_profit"]
    cost = plan["spread"]

    if is_number(stop) and is_number(target) and is_number(cost) and cost >= 0 and
         abs(entry - stop) > 0 do
      reward = if plan["action"] == "buy", do: target - entry, else: entry - target
      if status == "sl_first", do: -1.0, else: (reward - cost) / (abs(entry - stop) + cost)
    end
  end

  def estimated_net_r(_, _), do: nil

  def summarize_groups(items) do
    items
    |> Enum.group_by(&{&1.version, &1.side, &1.setup_kind, &1.entry_admission})
    |> Enum.map(fn {{version, side, kind, admission}, rows} ->
      settled =
        rows
        |> Enum.filter(&is_number(&1.estimated_net_r))
        |> Enum.sort_by(&{&1.published_at, &1.setup_id})

      {net, _, drawdown} =
        Enum.reduce(settled, {0.0, 0.0, 0.0}, fn row, {total, peak, dd} ->
          total = total + row.estimated_net_r
          peak = max(peak, total)
          {total, peak, max(dd, peak - total)}
        end)

      %{
        version: version,
        side: side,
        setup_kind: kind,
        entry_admission: admission,
        signals: length(rows),
        settled: length(settled),
        outcomes: Enum.frequencies_by(rows, & &1.result["status"]),
        estimated_net_r: if(settled != [], do: Float.round(net, 2)),
        settled_drawdown_r: if(settled != [], do: Float.round(drawdown, 2))
      }
    end)
    |> Enum.sort_by(&{&1.version, &1.entry_admission, &1.side, &1.setup_kind})
  end

  defp utc(nil), do: nil
  defp utc(%DateTime{} = at), do: at
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp parse(nil), do: nil

  defp parse(s) do
    case DateTime.from_iso8601(s) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp iso(nil), do: nil
  defp iso(at), do: DateTime.to_iso8601(at)
end
