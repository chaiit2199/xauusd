defmodule GoldBackend.Services.SignalQualityTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.{EntryQuality, SetupLifecycle, StrategyPlan, RuleStatistics}
  @now ~U[2026-10-23 08:00:35Z]
  @bias %{side: "buy", reason: "H1 tăng"}
  @indicators %{
    current_price: 4000.0,
    sma_20: 3990.0,
    macd: 1.0,
    rsi_14: 78.0,
    stochastic_k: 84.0
  }

  defp setup do
    SetupLifecycle.identify(%{
      action: "buy",
      state: "ready",
      blocked: false,
      entry: 4000.0,
      stop_loss: 3992.0,
      take_profit: 4016.0,
      atr: 8.0,
      zone: %{id: "support", low: 3994.0, mid: 3995.0, high: 3996.0},
      reason: "M15 xác nhận",
      candle_closed_at: "2026-10-23T08:00:00Z",
      barrier: nil
    })
  end

  defp options(s, price, now \\ @now),
    do: [
      bias: @bias,
      m15_setup: s,
      as_of: now,
      quote: %{price: price, timestamp: now},
      calendar_status: "ok"
    ]

  test "adverse drift is symmetric, ATR based, and has no one-dollar cap" do
    buy = setup()

    sell = %{
      buy
      | action: "sell",
        stop_loss: 4008.0,
        take_profit: 3984.0,
        zone: %{id: "resistance", low: 4004.0, mid: 4005.0, high: 4006.0}
    }

    for {s, price, better} <- [{buy, 4002.4, 3999.0}, {sell, 3997.6, 4001.0}] do
      q = EntryQuality.assess(s, price, 0.4)
      assert q.drift_ok
      assert_in_delta q.adverse, 2.4, 1.0e-8
      refute q.reward_risk_ok
      assert EntryQuality.assess(s, better, 0.4).adverse == 0
    end

    refute EntryQuality.assess(buy, 4002.41, 0.4).drift_ok
  end

  test "momentum extremes warn without vetoing trend setups, RSI alone cannot create one" do
    s = setup()
    plan = StrategyPlan.build(@indicators, s.entry, options(s, s.entry))
    assert plan.action == "buy"
    assert Enum.any?(plan.soft_flags, &String.contains?(&1, "RSI cao"))
    assert Enum.any?(plan.soft_flags, &String.contains?(&1, "Stochastic cao"))
    refute plan.execution_ready
    assert plan.mode == "signals_only"

    neutral =
      StrategyPlan.build(
        @indicators,
        s.entry,
        Keyword.put(options(s, s.entry), :bias, %{@bias | side: "neutral"})
      )

    assert neutral.action == "wait"
  end

  test "entry passing drift still waits for reward risk, without moving stop or target" do
    s = setup()
    plan = StrategyPlan.build(@indicators, 4002.4, options(s, 4002.4))
    assert plan.action == "wait"
    assert plan.setup_status == "wait_pullback"
    assert plan.stop_loss == s.stop_loss
    assert plan.take_profit == s.take_profit
    assert Enum.find(plan.checks, &(&1.code == "entry_drift")).status == "pass"
    assert Enum.find(plan.checks, &(&1.code == "reward_risk")).status == "blocked"
  end

  test "a better price cannot revive broken structure or ignore the five ATR stop limit" do
    s = setup()
    plan = StrategyPlan.build(@indicators, 3993.0, options(s, 3993.0))
    assert plan.action == "wait"
    assert plan.setup_status == "invalidated"
    far_stop = %{s | stop_loss: 3950.0, take_profit: 4100.0}
    assert StrategyPlan.build(@indicators, 4000.0, options(far_stop, 4000.0)).action == "wait"
  end

  test "opposing zone must leave room even when a nominal target offers two R" do
    s = %{setup() | barrier: %{id: "previous_day_high", low: 4004.0, mid: 4005.0, high: 4006.0}}
    plan = StrategyPlan.build(@indicators, 4000.0, options(s, 4000.0))
    assert plan.action == "wait"
    assert Enum.find(plan.checks, &(&1.code == "barrier_room")).status == "blocked"
  end

  test "a quote reaching target invalidates the old setup immediately" do
    s = setup()
    plan = StrategyPlan.build(@indicators, s.take_profit, options(s, s.take_profit))
    assert plan.action == "wait"
    assert plan.setup_status == "invalidated"
  end

  test "an expired quote cannot permanently invalidate a setup" do
    s = setup()

    opts =
      options(s, 3990.0)
      |> Keyword.put(:quote, %{price: 3990.0, timestamp: DateTime.add(@now, -121)})

    plan = StrategyPlan.build(@indicators, 3990.0, opts)
    assert plan.action == "wait"
    assert plan.setup_status == "paused"
  end

  test "notification refuses an expired quote before any network call" do
    snapshot = %{cfd_plan: %{action: "buy"}, signal_valid_until: "2020-01-01T00:00:00Z"}
    assert {:error, reason} = GoldBackend.Services.TelegramNotifier.notify(snapshot)
    assert reason =~ "báo giá đã quá hạn"
  end

  test "setup identity ignores rewritten text and corrected zone prices" do
    s = setup()
    changed = %{s | reason: "AI revised", zone: %{s.zone | low: 3993.0}}
    assert SetupLifecycle.identify(changed).id == s.id
    assert SetupLifecycle.identify(%{s | candle_closed_at: "2026-10-23T08:15:00Z"}).id != s.id
  end

  test "the next M15 candle retains the original confirmation and expires after two candles" do
    h1 =
      Enum.map(0..59, fn x ->
        %{
          open_time: DateTime.add(~U[2026-10-23 08:00:00Z], (x - 60) * 3600),
          open: 100.0 + x,
          close: 100.5 + x,
          low: 99.5 + x,
          high: 101.0 + x,
          confirmed: true
        }
      end)

    m15 =
      Enum.map(0..49, fn x ->
        %{
          open_time: DateTime.add(~U[2026-10-23 08:00:00Z], (x - 50) * 900),
          open: 150.0,
          close: 150.0,
          low: 149.5,
          high: 150.5,
          confirmed: true
        }
      end)
      |> List.update_at(-1, &%{&1 | close: 150.5, low: 147.0, high: 150.6})

    original = SetupLifecycle.assess(m15, h1, @bias, @now, [])
    assert original.state == "ready"

    following = %{
      List.last(m15)
      | open_time: ~U[2026-10-23 08:00:00Z],
        open: 150.5,
        close: 150.5,
        low: 150.3,
        high: 150.7
    }

    continued = SetupLifecycle.assess(m15 ++ [following], h1, @bias, ~U[2026-10-23 08:15:35Z], [])
    assert continued.state == "ready"
    assert continued.id == original.id
    assert continued.atr == original.atr
    assert continued.entry == original.entry
    assert continued.stop_loss == original.stop_loss
    assert continued.take_profit == original.take_profit

    ended =
      SetupLifecycle.assess(
        m15 ++ [following, %{following | open_time: ~U[2026-10-23 08:15:00Z]}],
        h1,
        @bias,
        ~U[2026-10-23 08:30:35Z],
        []
      )

    assert ended.state == "expired"
    assert ended.id == original.id
  end

  test "setup lives two candles and invalidates on structure, target, bias or news" do
    s = setup()
    assert SetupLifecycle.validate(s, [], @bias, ~U[2026-10-23 08:29:59Z], []).state == "ready"
    assert SetupLifecycle.validate(s, [], @bias, ~U[2026-10-23 08:30:00Z], []).state == "expired"

    assert SetupLifecycle.validate(s, [], %{@bias | side: "sell"}, @now, []).state ==
             "invalidated"

    b = %{open_time: ~U[2026-10-23 08:00:00Z], low: 3991.0, close: 4000.0, high: 4001.0}

    assert SetupLifecycle.validate(s, [b], @bias, ~U[2026-10-23 08:15:00Z], []).state ==
             "invalidated"

    assert SetupLifecycle.validate(
             s,
             [%{b | low: 3998.0, high: 4016.0}],
             @bias,
             ~U[2026-10-23 08:15:00Z],
             []
           ).state == "invalidated"

    event = %{impact: "High", country: "USD", time: ~U[2026-10-23 08:10:00Z]}
    assert SetupLifecycle.validate(s, [], @bias, @now, [event]).state == "invalidated"
  end

  test "final quote revalidation recalculates entry and RR with frozen M15 ATR" do
    s = setup()
    plan = StrategyPlan.build(@indicators, 4000.0, options(s, 4000.0))

    context = %{
      plan: plan,
      indicators: Map.put(@indicators, :atr_14, 1000.0),
      m15_setup: s,
      analysis_at: @now,
      calendar_status: "ok",
      events: [],
      warmup: false,
      warmup_detail: nil,
      news_bias: %{},
      latest: %{price: Decimal.new("4000"), timestamp: @now}
    }

    updated = StrategyPlan.revalidate(context, %{price: 4002.4, timestamp: @now}, @now)
    assert updated.plan.entry == 4002.4
    assert updated.plan.entry_limit == 2.4
    assert updated.plan.action == "wait"
    assert StrategyPlan.revalidate(context, nil, @now).plan.setup_status == "paused"

    stale =
      StrategyPlan.revalidate(
        context,
        %{price: 4000.0, timestamp: DateTime.add(@now, -121)},
        @now
      )

    assert stale.plan.action == "wait"
  end

  test "sole-blocker counts exclude unknown dependencies and include passes" do
    rows =
      Enum.map(
        [
          [{"a", "blocked"}, {"b", "pass"}],
          [{"a", "blocked"}, {"b", "unknown"}],
          [{"a", "pass"}, {"b", "pass"}]
        ],
        fn cs ->
          %{
            "checks" =>
              Enum.map(cs, fn {code, status} -> %{"code" => code, "status" => status} end)
          }
        end
      )

    stats = Map.new(RuleStatistics.summarize(rows), &{&1.code, &1})

    assert stats["a"] == %{
             code: "a",
             evaluated: 3,
             pass: 1,
             blocked: 2,
             unknown: 0,
             sole_blocker: 1
           }

    assert stats["b"].unknown == 1
    assert stats["b"].sole_blocker == 0
  end
end
