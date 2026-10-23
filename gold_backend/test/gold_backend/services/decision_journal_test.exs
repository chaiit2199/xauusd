defmodule GoldBackend.Services.DecisionJournalTest do
  use ExUnit.Case, async: false
  alias GoldBackend.Services.DecisionJournal
  alias GoldBackend.Repo
  import Ecto.Query

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "an invalidated setup stays blocked across repeated evaluations" do
    at = ~U[2026-10-23 08:00:35Z]

    plan = %{
      setup_id: "invalid-setup",
      setup_status: "invalidated",
      action: "wait",
      session_key: "day",
      checks: [],
      blocking_reasons: [],
      rule_commentary: "broken"
    }

    assert {:ok, {_, false}} = DecisionJournal.record(%{analysis_at: at, plan: plan})
    revived = %{plan | action: "buy", setup_status: "signal_ready"}

    assert {:ok, {result, false}} =
             DecisionJournal.record(%{analysis_at: DateTime.add(at, 60), plan: revived})

    assert result.plan.action == "wait"
    assert result.plan.setup_status == "invalidated"
    assert Repo.one(from e in "strategy_evaluations", select: count(e.id)) == 2
    assert Repo.one(from s in "strategy_signals", select: count(s.id)) == 0
  end

  test "registry freezes the original ATR, reference, zone, SL, TP and supporting context" do
    alias GoldBackend.Services.{MarketStructure, SetupLifecycle, SetupRegistry}
    at = ~U[2026-10-23 08:00:35Z]
    bias = %{side: "buy"}

    h1 =
      Enum.map(0..59, fn n ->
        close = 4000.0 + rem(n, 7)

        %{
          open_time: DateTime.add(~U[2026-10-23 08:00:00Z], (n - 60) * 3600),
          open: close,
          close: close,
          high: close + 1,
          low: close - 1,
          confirmed: true
        }
      end)

    technical_context = MarketStructure.assess(h1, at)
    assert technical_context.fibonacci != nil
    assert length(technical_context.ribbon.values) == 8

    setup =
      SetupLifecycle.identify(%{
        action: "buy",
        blocked: false,
        state: "ready",
        reason: "original",
        entry: 4000.0,
        stop_loss: 3992.0,
        take_profit: 4016.0,
        atr: 8.0,
        technical_context: technical_context,
        zone: %{id: "support", low: 3994.0, high: 3996.0, mid: 3995.0},
        candle_closed_at: "2026-10-23T08:00:00Z"
      })

    original = SetupRegistry.resolve(setup, [], bias, at, [])

    corrected = %{
      setup
      | entry: 4001.0,
        atr: 9.0,
        take_profit: 4020.0,
        stop_loss: 3990.0,
        technical_context: %{technical_context | fibonacci: nil},
        zone: %{setup.zone | low: 3993.0}
    }

    restored = SetupRegistry.resolve(corrected, [], bias, DateTime.add(at, 60), [])
    assert restored == original
  end

  test "deduplicates setups without using a session quota or replacing current entry checks" do
    at = ~U[2026-10-23 08:00:35Z]

    plan = %{
      action: "buy",
      setup_id: "first-setup",
      setup_status: "signal_ready",
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

    assert duplicate.plan.entry == 100.5

    assert {:ok, {repeated, false}} =
             DecisionJournal.record(%{analysis_at: DateTime.add(at, 900), plan: plan})

    assert repeated.plan.action == "buy"

    for n <- 1..4 do
      assert {:ok, {_, true}} =
               DecisionJournal.record(%{
                 analysis_at: DateTime.add(at, n * 900),
                 plan: %{plan | setup_id: "setup-#{n}"}
               })
    end

    assert {:ok, {_, true}} =
             DecisionJournal.record(%{
               analysis_at: DateTime.add(at, 86400),
               plan: %{plan | session_key: "next-day", setup_id: "next-day-setup"}
             })
  end
end
