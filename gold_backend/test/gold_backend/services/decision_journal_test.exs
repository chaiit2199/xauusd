defmodule GoldBackend.Services.DecisionJournalTest do
  use ExUnit.Case, async: false
  alias GoldBackend.Services.DecisionJournal
  alias GoldBackend.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "one durable ticket per session, repeated candle retains its original levels" do
    at = ~U[2026-10-23 08:00:35Z]

    plan = %{
      action: "buy",
      action_label: "Mua",
      entry: 100.0,
      stop_loss: 95.0,
      take_profit: 110.0,
      session_key: "test-window",
      checks: [],
      blocking_reasons: [],
      block_reason: nil,
      summary: "ready",
      rule_commentary: "ready"
    }

    assert {:ok, {_, true}} = DecisionJournal.record(%{analysis_at: at, plan: plan})

    assert {:ok, {duplicate, false}} =
             DecisionJournal.record(%{analysis_at: at, plan: %{plan | entry: 100.5}})

    assert duplicate.plan.entry == 100.0

    assert {:ok, {blocked, false}} =
             DecisionJournal.record(%{analysis_at: DateTime.add(at, 900), plan: plan})

    assert blocked.plan.action == "wait"
    assert List.last(blocked.plan.checks).code == "session_limit"

    assert {:ok, {_, true}} =
             DecisionJournal.record(%{
               analysis_at: DateTime.add(at, 86400),
               plan: %{plan | session_key: "next-day"}
             })
  end
end
