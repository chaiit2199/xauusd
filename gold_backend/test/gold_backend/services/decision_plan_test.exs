defmodule GoldBackend.Services.DecisionPlanTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.{DecisionPlan, EntryQuality}

  test "every price in the entry interval preserves structure, drift, stop distance and RR" do
    buy = %{
      action: "buy",
      entry: 4000.0,
      stop_loss: 3992.0,
      take_profit: 4016.0,
      atr: 8.0,
      zone: %{low: 3994.0, high: 3996.0}
    }

    sell = %{
      buy
      | action: "sell",
        stop_loss: 4008.0,
        take_profit: 3984.0,
        zone: %{low: 4004.0, high: 4006.0}
    }

    for setup <- [buy, sell], cost <- [0.0, 0.4, 1.2] do
      zone = DecisionPlan.entry_zone(setup, cost)
      assert zone.low <= zone.high

      for price <- [zone.low, (zone.low + zone.high) / 2, zone.high] do
        q = EntryQuality.assess(setup, price, cost)

        assert q.drift_ok and q.structure_ok and q.levels_ok and q.reward_risk_ok,
               inspect({setup.action, cost, price, q})
      end
    end
  end

  test "no feasible RR interval or no target means no eligible entry zone" do
    s = %{
      action: "buy",
      entry: 100.0,
      stop_loss: 95.0,
      take_profit: 101.0,
      atr: 2.0,
      zone: %{low: 99.0, high: 100.0}
    }

    assert DecisionPlan.entry_zone(s, 0.4) == nil
    assert DecisionPlan.entry_zone(%{s | take_profit: nil}, 0.4) == nil
  end
end
