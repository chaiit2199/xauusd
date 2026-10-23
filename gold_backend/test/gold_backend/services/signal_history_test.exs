defmodule GoldBackend.Services.SignalHistoryTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias GoldBackend.Repo
  alias GoldBackend.Services.{CandleClock, CandleStore, DecisionJournal, SignalHistory}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp plan(now) do
    %{
      setup_id: "history-setup",
      setup_status: "signal_ready",
      action: "buy",
      action_label: "Mua",
      entry: 100.0,
      stop_loss: 95.0,
      take_profit: 110.0,
      session_key: "test",
      checks: [],
      blocking_reasons: [],
      block_reason: nil,
      summary: "ready",
      rule_commentary: "ready",
      setup_expires_at: DateTime.to_iso8601(DateTime.add(now, 1800)),
      strategy_version: "zoi-v3-structure",
      decision_plan: %{
        entry_zone: %{low: 99.0, high: 101.0},
        expires_at: DateTime.to_iso8601(DateTime.add(now, 1800)),
        take_profit: 110.0
      }
    }
  end

  test "published plan survives repeated evaluations and outcomes are durable and idempotent" do
    now = DateTime.utc_now()
    p = plan(now)
    assert {:ok, {_, true}} = DecisionJournal.record(%{analysis_at: now, plan: p})

    assert {:ok, {_, false}} =
             DecisionJournal.record(%{
               analysis_at: DateTime.add(now, 60),
               plan: %{p | take_profit: 120.0}
             })

    assert Repo.one(from o in "signal_outcomes", select: count(o.setup_id)) == 1
    [item] = SignalHistory.list().items
    {:ok, published, _} = DateTime.from_iso8601(item.published_at)
    start = CandleClock.next_close(published)

    for {at, high, close} <- [{start, 102.0, 100.0}, {DateTime.add(start, 900), 111.0, 110.0}] do
      CandleStore.put(
        %{
          source: "gold_api_ohlc",
          open_time: at,
          open: 100.0,
          high: high,
          low: 99.0,
          close: close
        },
        900
      )
    end

    evaluated = DateTime.add(start, 1800)
    assert :ok = SignalHistory.refresh(evaluated)
    [outcome] = SignalHistory.list(evaluated).items
    assert outcome.plan["take_profit"] == 110.0
    assert outcome.result["status"] == "tp_first"
    assert outcome.result["entry_touched"]
    assert outcome.validity == "expired"
    assert :ok = SignalHistory.refresh(DateTime.add(evaluated, 900))
    assert hd(SignalHistory.list(evaluated).items).result == outcome.result

    conn =
      GoldBackendWeb.TradingController.signal_history(
        Plug.Test.conn(:get, "/api/trading/signals"),
        %{}
      )

    assert conn.status == 200
    assert length(Jason.decode!(conn.resp_body)["data"]["items"]) == 1
  end

  test "a quote-invalidated signal remains in history and is not reissued" do
    now = DateTime.utc_now()
    p = plan(now)
    assert {:ok, {_, true}} = DecisionJournal.record(%{analysis_at: now, plan: p})

    assert {:ok, {_, false}} =
             DecisionJournal.record(%{
               analysis_at: DateTime.add(now, 60),
               plan: %{p | action: "wait", setup_status: "invalidated"}
             })

    [item] = SignalHistory.list().items
    assert item.validity == "invalidated"
    assert item.plan["take_profit"] == 110.0

    assert {:ok, {result, false}} =
             DecisionJournal.record(%{analysis_at: DateTime.add(now, 120), plan: p})

    assert result.plan.action == "wait"
  end

  test "entry experiment group and levels are frozen at first publication" do
    now = DateTime.utc_now()

    p =
      Map.merge(plan(now), %{
        entry_admission: "late_entry",
        setup_kind: "trend_pullback",
        spread: 0.4
      })

    assert {:ok, {_, true}} = DecisionJournal.record(%{analysis_at: now, plan: p})

    assert {:ok, {_, false}} =
             DecisionJournal.record(%{
               analysis_at: DateTime.add(now, 60),
               plan: %{p | entry_admission: "reference_band", stop_loss: 90.0}
             })

    data = SignalHistory.list()
    assert [item] = data.items
    assert item.entry_admission == "late_entry" and item.setup_kind == "trend_pullback"
    assert [group] = data.groups
    assert group.signals == 1 and group.settled == 0 and group.estimated_net_r == nil
  end

  test "reference plans do not reserve or publish a signal before a fresh quote arrives" do
    now = DateTime.utc_now()

    s =
      GoldBackend.Services.SetupLifecycle.identify(%{
        action: "buy",
        state: "ready",
        blocked: false,
        setup_kind: "trend_pullback",
        entry: 100.0,
        stop_loss: 95.0,
        take_profit: 110.0,
        atr: 2.0,
        zone: %{id: "support", low: 96.0, mid: 97.0, high: 98.0},
        barrier: nil,
        candle_closed_at: DateTime.to_iso8601(CandleClock.closed_at(now)),
        reason: "M15"
      })

    i = %{current_price: 100.0, sma_20: 99.0, macd: 1.0, rsi_14: 50.0}
    opts = [bias: %{side: "buy", reason: "H1"}, m15_setup: s, as_of: now, calendar_status: "ok"]
    pending = GoldBackend.Services.StrategyPlan.build(i, 100.0, opts)
    assert pending.planning_action == "buy" and pending.action == "wait"
    assert {:ok, {_, false}} = DecisionJournal.record(%{analysis_at: now, plan: pending})
    assert SignalHistory.list().items == []

    live =
      GoldBackend.Services.StrategyPlan.build(
        i,
        100.0,
        Keyword.put(opts, :quote, %{price: 100.0, timestamp: now})
      )

    assert live.action == "buy" and live.setup_id == pending.setup_id
    assert {:ok, {_, true}} = DecisionJournal.record(%{analysis_at: now, plan: live})
    assert {:ok, {_, false}} = DecisionJournal.record(%{analysis_at: now, plan: live})
    assert length(SignalHistory.list().items) == 1
  end

  test "missing bars can be repaired without fabricating an initial result" do
    now = DateTime.utc_now()
    assert {:ok, {_, true}} = DecisionJournal.record(%{analysis_at: now, plan: plan(now)})
    [item] = SignalHistory.list().items
    {:ok, published, _} = DateTime.from_iso8601(item.published_at)
    start = CandleClock.next_close(published)
    finish = DateTime.add(start, 900)
    SignalHistory.refresh(finish)
    assert hd(SignalHistory.list().items).result["status"] == "data_gap"

    CandleStore.put(
      %{
        source: "gold_api_ohlc",
        open_time: start,
        open: 100.0,
        high: 111.0,
        low: 99.0,
        close: 110.0
      },
      900
    )

    SignalHistory.refresh(finish)
    assert hd(SignalHistory.list().items).result["status"] == "tp_first"
  end

  test "older signals are invalidated by a new valid H1 direction, not by missing data" do
    alias GoldBackend.Services.{SetupLifecycle, SetupRegistry}
    now = DateTime.utc_now()
    formed = CandleClock.closed_at(now)

    s =
      SetupLifecycle.identify(%{
        action: "buy",
        blocked: false,
        state: "ready",
        reason: "ready",
        entry: 100.0,
        stop_loss: 95.0,
        take_profit: 110.0,
        atr: 2.0,
        zone: %{id: "support", low: 98.0, mid: 99.0, high: 100.0},
        candle_closed_at: DateTime.to_iso8601(formed)
      })

    SetupRegistry.resolve(s, [], %{side: "buy"}, now, [])
    p = %{plan(now) | setup_id: s.id}
    assert {:ok, {_, true}} = DecisionJournal.record(%{analysis_at: now, plan: p})

    context = %{
      analysis_at: DateTime.add(now, 60),
      plan: %{bias: %{side: "neutral", adx: nil}},
      m15_candles: [],
      events: [],
      warmup: true
    }

    SignalHistory.reconcile(context)
    assert hd(SignalHistory.list().items).validity == "active"
    SignalHistory.reconcile(%{context | warmup: false, plan: %{bias: %{side: "sell", adx: 30.0}}})
    assert hd(SignalHistory.list().items).validity == "invalidated"
  end
end
