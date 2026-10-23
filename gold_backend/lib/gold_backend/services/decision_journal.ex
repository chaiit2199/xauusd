defmodule GoldBackend.Services.DecisionJournal do
  @moduledoc "Durable decisions per M15 and at most one published ticket per configured VN window. These are signals, not broker fills."
  import Ecto.Query
  alias GoldBackend.Repo

  def record(context) do
    plan = context.plan
    candle = GoldBackend.Services.CandleClock.closed_at(context.analysis_at)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      {plan, publish?} = reserve(plan, candle, now)
      payload = Jason.encode!(plan) |> Jason.decode!()

      Repo.insert_all(
        "strategy_decisions",
        [
          %{
            candle: candle,
            version: "zoi-v1",
            snapshot: payload,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: {:replace, [:snapshot, :updated_at]},
        conflict_target: [:candle, :version]
      )

      {%{context | plan: plan}, publish?}
    end)
  end

  defp reserve(%{action: side} = plan, candle, now) when side in ["buy", "sell"] do
    payload = Jason.encode!(plan) |> Jason.decode!()

    {count, _} =
      Repo.insert_all(
        "strategy_tickets",
        [
          %{
            session_key: plan.session_key,
            candle: candle,
            side: side,
            plan: payload,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing
      )

    if count == 1 do
      check = %{
        code: "session_limit",
        status: "pass",
        reason: "Chưa phát phiếu khác trong khung giờ hôm nay."
      }

      {%{plan | checks: plan.checks ++ [check]}, true}
    else
      existing =
        Repo.one(
          from t in "strategy_tickets",
            where: t.session_key == ^plan.session_key,
            select: %{candle: t.candle, side: t.side, plan: t.plan}
        )

      # Do not reissue an altered entry/SL/TP for the same trigger.
      same_candle =
        not is_nil(existing) and existing.candle in [candle, DateTime.to_naive(candle)] and
          existing.side == plan.action

      reason = "Đã phát một phiếu trong khung 14:00–22:00 hôm nay."
      check = %{code: "session_limit", status: "blocked", reason: reason}

      if same_candle do
        original =
          Map.new(plan, fn {k, v} -> {k, Map.get(existing.plan, Atom.to_string(k), v)} end)

        {original, false}
      else
        {%{
           plan
           | action: "wait",
             action_label: "Đứng ngoài",
             block_reason: reason,
             summary: reason,
             checks: plan.checks ++ [check],
             blocking_reasons: plan.blocking_reasons ++ [reason],
             rule_commentary: plan.rule_commentary <> "\n" <> reason
         }, false}
      end
    end
  end

  defp reserve(plan, candle, _) do
    existing =
      Repo.one(
        from t in "strategy_tickets", where: t.session_key == ^plan.session_key, select: t.candle
      )

    blocked = not is_nil(existing) and existing not in [candle, DateTime.to_naive(candle)]

    check = %{
      code: "session_limit",
      status: if(blocked, do: "blocked", else: "pass"),
      reason: "Tối đa một phiếu mỗi khung 14:00–22:00 giờ Việt Nam."
    }

    reasons = if blocked, do: plan.blocking_reasons ++ [check.reason], else: plan.blocking_reasons
    {%{plan | checks: plan.checks ++ [check], blocking_reasons: reasons}, false}
  end
end
