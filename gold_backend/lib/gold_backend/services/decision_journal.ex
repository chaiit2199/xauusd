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
      publish? = reserve(plan, candle, now)
      payload = Jason.encode!(plan) |> Jason.decode!()
      version = Map.get(plan, :strategy_version, StrategyPolicy.version())

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

        Map.merge(plan, %{
          action: "wait",
          action_label: "Đứng ngoài",
          setup_status: terminal.state,
          block_reason: terminal.reason,
          summary: terminal.reason,
          rule_commentary: plan.rule_commentary <> "\n" <> terminal.reason,
          checks: plan.checks ++ [check],
          blocking_reasons: plan.blocking_reasons ++ [terminal.reason],
          entry_guard: %{blocked: true, reasons: plan.blocking_reasons ++ [terminal.reason]}
        })
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
