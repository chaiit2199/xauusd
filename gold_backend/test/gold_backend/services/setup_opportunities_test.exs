defmodule GoldBackend.Services.SetupOpportunitiesTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.{MarketStructure, SetupEngine, StrategyPlan}
  @now ~U[2026-10-23 08:00:35Z]
  @zone %{id: "sma20_h1", low: 99.0, mid: 100.0, high: 101.0}
  @resistance %{id: "previous_day_high", low: 108.0, mid: 109.0, high: 110.0}
  @bias %{side: "buy", reason: "H1 tăng"}

  defp bars do
    Enum.map(0..49, fn n ->
      %{
        open_time: DateTime.add(~U[2026-10-23 08:00:00Z], (n - 50) * 900),
        open: 100.0,
        close: 100.0,
        low: 99.5,
        high: 100.5,
        confirmed: true
      }
    end)
  end

  defp trigger, do: List.update_at(bars(), -1, &%{&1 | close: 100.5, low: 97.0, high: 100.6})

  defp plan(s, extra \\ []) do
    StrategyPlan.build(
      %{current_price: 101.0, sma_20: 100.0, macd: 1.0, rsi_14: 80.0, stochastic_k: 90.0},
      s.entry,
      [
        bias: @bias,
        as_of: @now,
        m15_setup: s,
        quote: %{price: s.entry, timestamp: @now},
        calendar_status: "ok"
      ] ++ extra
    )
  end

  test "a poor first zone cannot hide a qualifying BUY or depend on zone ordering" do
    poor = %{id: "previous_day_low", low: 95.5, mid: 98.0, high: 100.5}

    for zones <- [[poor, @zone, @resistance], [@resistance, @zone, poor]] do
      setup = SetupEngine.assess(trigger(), @bias, zones, @now)
      assert setup.zone.id == @zone.id
      assert setup.candidate_count == 2
      assert plan(setup).action == "buy"
    end

    only_poor = SetupEngine.assess(trigger(), @bias, [poor, @resistance], @now)
    assert only_poor.zone.id == poor.id
    assert plan(only_poor).action == "buy"
  end

  test "selection is symmetric for SELL and ignores a candidate with SL beyond five ATR" do
    wide = %{id: "previous_day_low", low: 90.0, mid: 99.0, high: 100.5}
    selected = SetupEngine.assess(trigger(), @bias, [wide, @zone, @resistance], @now)
    refute selected.blocked
    assert selected.zone.id == @zone.id

    mirrored =
      Enum.map(
        trigger(),
        &%{
          &1
          | open: 200 - &1.open,
            close: 200 - &1.close,
            low: 200 - &1.high,
            high: 200 - &1.low
        }
      )

    poor = %{id: "previous_day_high", low: 99.5, mid: 102.0, high: 104.5}
    support = %{id: "previous_day_low", low: 90.0, mid: 91.0, high: 92.0}
    sell = SetupEngine.assess(mirrored, %{@bias | side: "sell"}, [poor, @zone, support], @now)
    assert sell.action == "sell"
    assert sell.zone.id == @zone.id
    assert_in_delta sell.take_profit, sell.entry - 5.0, 0.01

    assert StrategyPlan.build(
             %{current_price: 99.0, sma_20: 100.0, macd: -1.0, rsi_14: 20.0},
             sell.entry,
             bias: %{@bias | side: "sell"},
             as_of: @now,
             m15_setup: sell,
             quote: %{price: sell.entry, timestamp: @now},
             calendar_status: "ok"
           ).action == "sell"
  end

  test "breakout and retest is an alternative trigger for BUY and SELL" do
    breakout = %{open: 100.5, close: 102.0, low: 100.4, high: 102.1}
    retest = %{open: 101.4, close: 102.0, low: 100.8, high: 102.1}
    assert SetupEngine.pattern(retest, breakout, @zone, "buy") == "breakout_retest"

    mirror = fn b ->
      %{open: 200 - b.open, close: 200 - b.close, high: 200 - b.low, low: 200 - b.high}
    end

    assert SetupEngine.pattern(mirror.(retest), mirror.(breakout), @zone, "sell") ==
             "breakout_retest"

    # No breakout close, no retest touch, or a close back inside: no new trigger.
    refute SetupEngine.pattern(retest, %{breakout | close: 100.9}, @zone, "buy")
    refute SetupEngine.pattern(%{retest | low: 101.1}, breakout, @zone, "buy")
    refute SetupEngine.pattern(%{retest | open: 100.9, close: 101.0}, breakout, @zone, "buy")
    late = Map.put(@zone, :known_at, "2026-10-23T07:45:00Z")

    refute SetupEngine.pattern(
             retest,
             Map.put(breakout, :open_time, ~U[2026-10-23 07:30:00Z]),
             late,
             "buy"
           )

    input =
      bars()
      |> List.update_at(-2, &Map.merge(&1, breakout))
      |> List.update_at(-1, &Map.merge(&1, retest))

    setup = SetupEngine.assess(input, @bias, [@zone, @resistance], @now)
    assert setup.pattern == "breakout_retest"
    assert plan(setup).action == "buy"
  end

  test "AOI can host a confirmation but does not add more target barriers" do
    aoi = %{id: "aoi_low_h1", low: 99.0, mid: 99.5, high: 100.0, entry_only: true}
    upper = %{id: "aoi_high_h1", low: 102.0, mid: 102.5, high: 103.0, entry_only: true}
    setup = SetupEngine.assess(trigger(), @bias, [aoi, upper, @resistance], @now)
    assert setup.zone.id == aoi.id
    assert_in_delta setup.take_profit, setup.entry + 5.0, 0.01
    assert plan(setup).action == "buy"
  end

  test "opposing resistance cannot be reused as BUY support without a confirmed breakout retest" do
    resistance = %{@zone | id: "previous_day_high"}
    target = %{@resistance | id: "swing_high_next"}
    assert SetupEngine.assess(trigger(), @bias, [resistance, target], @now).state == "wait_m15"

    input =
      bars()
      |> List.update_at(-2, &%{&1 | open: 100.5, close: 102.0, low: 100.4, high: 102.1})
      |> List.update_at(-1, &%{&1 | open: 101.4, close: 102.0, low: 100.8, high: 102.1})

    setup = SetupEngine.assess(input, @bias, [resistance, target], @now)
    assert setup.pattern == "breakout_retest"
    assert plan(setup).action == "buy"
  end

  test "doubled cost scenario reports fragility without adding another veto" do
    target = %{@resistance | low: 107.4}
    setup = SetupEngine.assess(trigger(), @bias, [@zone, target], @now)
    result = plan(setup)
    assert result.action == "buy"
    assert result.decision_plan.reward_risk >= 1.5
    sensitivity = result.decision_plan.cost_sensitivity
    assert sensitivity.stress_cost == 0.8
    assert sensitivity.stress_reward_risk < 1.5
    assert sensitivity.max_cost_for_min_rr >= 0.4
  end

  test "lack of ribbon, structure or Fibonacci confluence does not veto an otherwise valid setup" do
    context = MarketStructure.assess([], @now)
    setup = SetupEngine.assess(trigger(), @bias, [@zone, @resistance], @now, context)
    result = plan(setup, news_bias: %{high_impact: true})
    assert result.action == "buy"
    assert length(result.decision_plan.supporting_evidence) == 3
    assert Enum.all?(result.decision_plan.supporting_evidence, &(not &1.supports))
    refute Enum.any?(result.soft_flags, &String.contains?(&1, "headline"))
    assert result.decision_plan.technical_context == context
  end
end
