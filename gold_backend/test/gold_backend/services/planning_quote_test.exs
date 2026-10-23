defmodule GoldBackend.Services.PlanningQuoteTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.{StrategyPlan, SetupLifecycle, InsightCache, RuleStatistics}
  @now ~U[2026-10-23 08:05:00Z]
  @i %{current_price: 4000.0, sma_20: 4010.0, macd: -1.0, rsi_14: 50.0}

  defp scenario(side \\ "sell") do
    buy = side == "buy"

    s =
      SetupLifecycle.identify(%{
        action: side,
        state: "ready",
        blocked: false,
        setup_kind: "trend_pullback",
        entry: 4000.0,
        atr: 2.0,
        stop_loss: if(buy, do: 3995.0, else: 4005.0),
        take_profit: if(buy, do: 4010.0, else: 3990.0),
        zone: %{id: "zone", low: 3997.0, mid: 4000.0, high: 4003.0},
        candle_closed_at: "2026-10-23T08:00:00Z",
        reason: "M15 confirmed",
        barrier: nil
      })

    {s, [bias: %{side: side, reason: "H1"}, m15_setup: s, as_of: @now, calendar_status: "ok"]}
  end

  test "a five-minute-old M15 close supports BUY/SELL planning without being a live quote" do
    for side <- ["buy", "sell"] do
      {s, opts} = scenario(side)

      for quote <- [
            nil,
            %{price: 4500.0, timestamp: ~U[2026-10-23 08:00:00Z]},
            %{price: 4500.0, timestamp: DateTime.add(@now, 6)}
          ] do
        p = StrategyPlan.build(@i, 4500.0, Keyword.put(opts, :quote, quote))
        assert p.planning_action == side
        assert p.action == "wait" and p.setup_status == "awaiting_quote"
        assert p.current_entry_status == "unchecked" and p.quote_at == nil
        assert p.entry == 4000.0 and p.price_basis == "m15_close"
        assert p.stop_loss == s.stop_loss and p.take_profit == s.take_profit
        assert p.setup_expires_at == s.expires_at
        assert p.decision_plan.reference_entry == 4000.0
        assert p.decision_plan.reference_at == s.formed_at
        assert p.decision_plan.reference_reward_risk == 1.78
        assert p.decision_plan.reward_risk == nil and p.reward_risk_after_spread == nil
        assert p.decision_plan.current_entry == nil
        checks = Map.new(p.checks, &{&1.code, &1})
        assert checks["quote"].status == "warning" and not checks["quote"].required
        assert checks["trigger"].status == "pass" and checks["m15_data"].status == "pass"

        for code <- [
              "current_entry",
              "setup_target",
              "structure",
              "entry_drift",
              "levels",
              "reward_risk"
            ] do
          assert checks[code].status == "unknown", code
        end

        stats =
          [p]
          |> Jason.encode!()
          |> Jason.decode!()
          |> RuleStatistics.summarize()
          |> Map.new(&{&1.code, &1})

        assert stats["entry_drift"].unknown == 1
      end
    end
  end

  test "fresh quote recomputes current RR without changing reference RR or lifetime" do
    {s, opts} = scenario()

    for {price, action, rr} <- [{4000.0, "sell", 1.78}, {3996.0, "wait", 0.60}] do
      p =
        StrategyPlan.build(
          @i,
          9999.0,
          Keyword.put(opts, :quote, %{price: price, timestamp: @now})
        )

      assert p.entry == price and p.action == action
      assert p.decision_plan.reference_reward_risk == 1.78
      assert p.decision_plan.reward_risk == rr
      assert p.decision_plan.current_entry == price
      assert p.current_entry_status == if(action == "sell", do: "eligible", else: "blocked")
      assert p.setup_expires_at == s.expires_at
    end
  end

  test "missing target, missing candles, expired or invalidated setup cannot become ready" do
    {s, opts} = scenario()

    for changed <- [
          %{s | take_profit: nil},
          %{s | state: "data_unavailable", blocked: true},
          %{s | state: "invalidated", blocked: true},
          %{s | state: "expired", blocked: true}
        ] do
      p = StrategyPlan.build(@i, s.entry, Keyword.put(opts, :m15_setup, changed))
      assert p.action == "wait" and p.current_entry_status != "eligible"
      if is_nil(changed.take_profit), do: assert(p.decision_plan.reference_reward_risk == nil)
      if changed.blocked, do: assert(p.planning_action == "wait")
    end
  end

  test "server cache expires current checks while retaining a timestamped reference plan" do
    {_, opts} = scenario()

    p =
      StrategyPlan.build(@i, 4000.0, Keyword.put(opts, :quote, %{price: 4000.0, timestamp: @now}))

    data = %{
      cfd_plan: p,
      ai_next_analysis_at: "2026-10-23T08:15:00Z",
      calendar_valid_until: "2026-10-23T08:20:00Z",
      signal_valid_until: "2026-10-23T08:07:01Z"
    }

    expired = InsightCache.expire_snapshot(data, ~U[2026-10-23 08:07:01Z]).cfd_plan
    assert expired.action == "wait" and expired.planning_action == "sell"
    assert expired.entry_guard.blocked

    assert expired.setup_status == "awaiting_quote" and
             expired.current_entry_status == "unchecked"

    assert expired.decision_plan.reference_reward_risk == 1.78
    assert expired.decision_plan.reward_risk == nil and expired.decision_plan.current_entry == nil
    checks = Map.new(expired.checks, &{&1.code, &1.status})
    assert checks["quote"] == "warning" and checks["trigger"] == "pass"
    assert checks["entry_drift"] == "unknown" and checks["market_open"] == "unknown"
    # Missing new M15 must not be masked by the earlier quote expiry.
    stale = InsightCache.expire_snapshot(data, ~U[2026-10-23 08:15:00Z]).cfd_plan
    assert stale.setup_status == "paused"
    assert Enum.find(stale.checks, &(&1.code == "m15_data")).status == "blocked"
    terminal = InsightCache.expire_snapshot(data, ~U[2026-10-23 08:30:00Z]).cfd_plan
    assert terminal.setup_status == "expired" and terminal.current_entry_status == "blocked"
  end
end
