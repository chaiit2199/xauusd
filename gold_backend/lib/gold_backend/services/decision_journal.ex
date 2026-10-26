defmodule GoldBackend.Services.DecisionJournal do
  @moduledoc "Durable setup deduplication and evaluations; published signals never consume a fill quota."
  import Ecto.Query
  alias GoldBackend.Repo
  alias GoldBackend.Services.{CandleClock, StrategyPolicy}

  def record(context) do
    candle = CandleClock.closed_at(context.analysis_at)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      plan = enforce_invalidation(context.plan, now)
      record_candidates(plan, now)
      publish? = reserve(plan, candle, now)
      payload = Jason.encode!(plan) |> Jason.decode!()
      version = Map.get(plan, :strategy_version, StrategyPolicy.version())

      quote_at =
        case Map.get(plan, :quote_at) do
          at when is_binary(at) ->
            case DateTime.from_iso8601(at) do
              {:ok, value, _} -> value
              _ -> nil
            end

          _ ->
            nil
        end

      quote_price =
        if not is_nil(quote_at) and Map.get(plan, :price_basis) == "live_quote" and
             is_number(Map.get(plan, :entry)),
           do: Decimal.from_float(plan.entry * 1.0)

      Repo.insert_all("strategy_observations", [
        %{
          evaluated_at: context.analysis_at,
          version: version,
          setup_id: Map.get(plan, :setup_id),
          quote_at: quote_at,
          quote_price: quote_price,
          snapshot: payload
        }
      ])

      Repo.insert_all(
        "strategy_decisions",
        [
          %{
            candle: candle,
            version: version,
            snapshot: payload,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: {:replace, [:snapshot, :updated_at]},
        conflict_target: [:candle, :version]
      )

      Repo.insert_all(
        "strategy_evaluations",
        [
          %{
            evaluated_at: CandleClock.closed_at(context.analysis_at, 60),
            version: version,
            snapshot: payload,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: {:replace, [:snapshot, :updated_at]},
        conflict_target: [:evaluated_at, :version]
      )

      {%{context | plan: plan}, publish?}
    end)
  end

  defp record_candidates(plan, now) do
    candidates = Map.get(plan, :candidate_log, [])

    Enum.each(candidates, fn candidate ->
      id = Map.get(candidate, :id)

      if is_binary(id) do
        selected = id == Map.get(plan, :setup_id)

        snapshot =
          candidate
          |> Map.put(
            :warnings,
            if(selected,
              do: Map.get(plan, :soft_flags, []),
              else: Map.get(candidate, :warnings, [])
            )
          )
          |> Map.put(:blockers, if(selected, do: Map.get(plan, :blocking_reasons, []), else: []))
          |> Jason.encode!()
          |> Jason.decode!()

        Repo.insert_all(
          "strategy_candidates",
          [
            %{
              setup_id: id,
              snapshot: snapshot,
              first_seen_at: now,
              last_seen_at: now,
              plan_ready: selected and Map.get(plan, :planning_action) in ["buy", "sell"],
              ready_to_enter: selected and Map.get(plan, :action) in ["buy", "sell"]
            }
          ],
          on_conflict: {:replace, [:last_seen_at]},
          conflict_target: [:setup_id]
        )

        if selected and Map.get(plan, :planning_action) in ["buy", "sell"] do
          Repo.update_all(from(c in "strategy_candidates", where: c.setup_id == ^id),
            set: [plan_ready: true]
          )
        end

        if selected and Map.get(plan, :action) in ["buy", "sell"] do
          Repo.update_all(from(c in "strategy_candidates", where: c.setup_id == ^id),
            set: [ready_to_enter: true]
          )
        end
      end
    end)
  end

  defp enforce_invalidation(%{setup_id: id} = plan, now) when is_binary(id) do
    if plan.setup_status in ["invalidated", "expired"] do
      reason =
        if plan.setup_status == "expired",
          do: "Setup đã hết hạn; chờ xác nhận mới.",
          else: "Setup đã mất hiệu lực; chờ xác nhận mới."

      Repo.insert_all(
        "strategy_invalidations",
        [
          %{
            setup_id: id,
            state: plan.setup_status,
            reason: reason,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing
      )
    end

    case Repo.one(
           from s in "strategy_invalidations",
             where: s.setup_id == ^id,
             select: %{state: s.state, reason: s.reason}
         ) do
      nil ->
        plan

      terminal ->
        check = %{code: "setup_invalidation", status: "blocked", reason: terminal.reason}

        updated =
          Map.merge(plan, %{
            action: "wait",
            action_label: "Đứng ngoài",
            setup_status: terminal.state,
            trade_plan_status: String.upcase(terminal.state),
            planning_action: "wait",
            block_reason: terminal.reason,
            summary: terminal.reason,
            rule_commentary: plan.rule_commentary <> "\n" <> terminal.reason,
            checks: plan.checks ++ [check],
            blocking_reasons: plan.blocking_reasons ++ [terminal.reason],
            entry_guard: %{blocked: true, reasons: plan.blocking_reasons ++ [terminal.reason]}
          })

        case Map.get(updated, :trade_plan) do
          nil ->
            updated

          trade_plan ->
            status = String.upcase(terminal.state)

            Map.put(updated, :trade_plan, %{
              trade_plan
              | status: status,
                entry: %{trade_plan.entry | status: status}
            })
        end
    end
  end

  defp enforce_invalidation(plan, _), do: plan

  defp reserve(%{action: side, setup_id: id} = plan, candle, now)
       when side in ["buy", "sell"] and is_binary(id) do
    {count, _} =
      Repo.insert_all(
        "strategy_signals",
        [
          %{
            setup_id: id,
            session_key: plan.session_key,
            candle: candle,
            side: side,
            plan: Jason.encode!(plan) |> Jason.decode!(),
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:setup_id]
      )

    if count == 1, do: GoldBackend.Services.SignalHistory.track(plan, DateTime.utc_now())
    count == 1
  end

  defp reserve(_, _, _), do: false
end
