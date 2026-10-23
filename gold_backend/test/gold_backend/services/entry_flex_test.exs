defmodule GoldBackend.Services.EntryFlexTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.{
    StrategyPlan,
    SetupLifecycle,
    DecisionPlan,
    EntryQuality,
    SignalHistory,
    RuleStatistics
  }

  @now ~U[2026-10-23 08:00:35Z]
  @i %{current_price: 100.0, sma_20: 99.0, macd: 1.0, rsi_14: 50.0}

  defp trade_setup(side) do
    buy = side == "buy"

    SetupLifecycle.identify(%{
      action: side,
      state: "ready",
      blocked: false,
      setup_kind: "trend_pullback",
      entry: 100.0,
      atr: 2.0,
      stop_loss: if(buy, do: 96.0, else: 104.0),
      take_profit: if(buy, do: 110.0, else: 90.0),
      zone: %{id: "zone", low: 97.0, mid: 100.0, high: 103.0},
      candle_closed_at: "2026-10-23T08:00:00Z",
      reason: "M15 confirmed",
      barrier: nil
    })
  end

  defp opts(s, price),
    do: [
      bias: %{side: s.action, reason: "H1"},
      m15_setup: s,
      as_of: @now,
      quote: %{price: price, timestamp: @now},
      calendar_status: "ok",
      spread: 0.2
    ]

  test "late BUY and SELL with sufficient net RR are admitted without moving frozen levels" do
    for {side, price} <- [{"buy", 101.0}, {"sell", 99.0}] do
      s = trade_setup(side)
      p = StrategyPlan.build(@i, price, opts(s, price))
      assert p.action == side
      assert p.entry_admission == "late_entry"
      assert p.decision_plan.entry_admission == "late_entry"
      assert p.reference_entry == 100.0 and p.reference_atr == 2.0
      assert p.stop_loss == s.stop_loss and p.take_profit == s.take_profit
      assert p.setup_expires_at == s.expires_at
      assert p.reward_risk_after_spread == 1.69
      drift = Enum.find(p.checks, &(&1.code == "entry_drift"))
      assert drift.status == "warning" and not drift.required
      assert p.decision_plan.entry_zone.low <= price and price <= p.decision_plan.entry_zone.high
      assert StrategyPlan.build(@i, s.entry, opts(s, s.entry)).entry_admission == "reference_band"
    end
  end

  test "late entry cannot bypass freshness, news, expiry, confirmation, structure, stop cap or RR" do
    for {side, price, too_late} <- [{"buy", 101.0, 102.0}, {"sell", 99.0, 98.0}] do
      s = trade_setup(side)

      for extra <- [
            [quote: nil],
            [quote: %{price: price, timestamp: DateTime.add(@now, -121)}],
            [calendar_status: "unavailable"],
            [calendar_valid_until: DateTime.to_iso8601(@now)],
            [blocking_event: %{title: "News"}],
            [as_of: ~U[2026-10-23 08:30:00Z]],
            [m15_setup: %{s | blocked: true, state: "wait_m15"}],
            [m15_setup: %{s | blocked: true, state: "invalidated"}],
            [
              m15_setup: %{
                s
                | stop_loss: if(side == "buy", do: 89.0, else: 111.0),
                  take_profit: if(side == "buy", do: 150.0, else: 50.0)
              }
            ]
          ] do
        p = StrategyPlan.build(@i, price, Keyword.merge(opts(s, price), extra))
        assert p.action == "wait", inspect(extra)
        assert p.entry_admission == nil
      end

      assert StrategyPlan.build(@i, too_late, opts(s, too_late)).action == "wait"
      broken = if side == "buy", do: s.zone.low, else: s.zone.high
      assert StrategyPlan.build(@i, broken, opts(s, broken)).setup_status == "invalidated"
    end
  end

  test "expanded entry interval respects the nearest barrier and every hard price gate" do
    for side <- ["buy", "sell"] do
      s = trade_setup(side)
      zone = DecisionPlan.entry_zone(s, 0.2)
      boundary = if side == "buy", do: zone.high, else: zone.low
      refute EntryQuality.assess(s, boundary, 0.2).drift_ok

      for price <- [zone.low, zone.high, (zone.low + zone.high) / 2] do
        q = EntryQuality.assess(s, price, 0.2)
        assert q.levels_ok and q.structure_ok and q.reward_risk_ok
      end

      barrier = if side == "buy", do: %{low: 106.0, high: 107.0}, else: %{low: 93.0, high: 94.0}
      closer = %{s | barrier: Map.put(barrier, :id, "nearest_barrier")}
      narrowed = DecisionPlan.entry_zone(closer, 0.2)
      assert narrowed.low >= zone.low and narrowed.high <= zone.high
      price = if side == "buy", do: narrowed.high, else: narrowed.low
      assert StrategyPlan.build(@i, price, opts(closer, price)).action == side
    end
  end

  test "sole stop-cap audits require all other mandatory checks and deduplicate setup IDs" do
    s = %{trade_setup("buy") | stop_loss: 88.0, take_profit: 130.0}
    rejected = %{s | blocked: true, state: "invalid_levels"}
    selected = Map.put(trade_setup("buy"), :rejected_candidates, [rejected])
    p = StrategyPlan.build(@i, 101.0, opts(selected, 101.0))
    assert p.action == "buy"
    assert [%{sole_blocker: true}] = p.stop_cap_audit
    paused = StrategyPlan.build(@i, 101.0, Keyword.put(opts(selected, 101.0), :quote, nil))
    assert [%{sole_blocker: false}] = paused.stop_cap_audit
    later = DateTime.add(@now, 900)

    next =
      StrategyPlan.build(
        @i,
        101.0,
        Keyword.merge(opts(selected, 101.0),
          as_of: later,
          quote: %{price: 101.0, timestamp: later}
        )
      )

    assert [%{sole_blocker: false}] = next.stop_cap_audit
    rows = [p, p, paused] |> Jason.encode!() |> Jason.decode!()
    assert RuleStatistics.stop_caps(rows) == %{evaluations: 3, candidates: 1, sole_candidates: 1}
  end

  test "after-cost outcome R is symmetric and ambiguous observations stay excluded" do
    for side <- ["buy", "sell"] do
      s = trade_setup(side)
      plan = s |> Map.put(:spread, 0.2) |> Jason.encode!() |> Jason.decode!()
      entry = if side == "buy", do: 101.0, else: 99.0

      assert_in_delta SignalHistory.estimated_net_r(plan, %{
                        "status" => "tp_first",
                        "entry_price" => entry
                      }),
                      8.8 / 5.2,
                      1.0e-9

      assert SignalHistory.estimated_net_r(plan, %{"status" => "sl_first", "entry_price" => entry}) ==
               -1.0

      assert SignalHistory.estimated_net_r(plan, %{
               "status" => "ambiguous",
               "entry_price" => entry
             }) == nil
    end

    base = %{
      version: "v6",
      side: "buy",
      setup_kind: "trend_pullback",
      entry_admission: "late_entry",
      published_at: "2026-10-23T08:00:00Z",
      setup_id: "a",
      estimated_net_r: 2.0,
      result: %{"status" => "tp_first"}
    }

    rows = [
      base,
      %{base | setup_id: "b", estimated_net_r: -1.0, result: %{"status" => "sl_first"}},
      %{base | setup_id: "c", estimated_net_r: nil, result: %{"status" => "ambiguous"}},
      %{base | setup_id: "d", entry_admission: "reference_band"},
      %{base | setup_id: "e", version: "v5", entry_admission: "unclassified"}
    ]

    groups = SignalHistory.summarize_groups(Enum.reverse(rows))
    assert length(groups) == 3
    late = Enum.find(groups, &(&1.entry_admission == "late_entry"))
    assert late.signals == 3 and late.settled == 2
    assert late.estimated_net_r == 1.0 and late.settled_drawdown_r == 1.0
  end
end
