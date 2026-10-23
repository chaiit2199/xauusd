defmodule GoldBackend.Services.EntryQuality do
  @moduledoc "Symmetric entry checks using the frozen M15 reference, ATR, stop and target."
  alias GoldBackend.Services.StrategyPolicy

  def assess(setup, price, cost) do
    buy? = setup.action == "buy"
    risk = abs(price - setup.stop_loss)
    reward = if buy?, do: setup.take_profit - price, else: price - setup.take_profit
    adverse = max(0.0, if(buy?, do: price - setup.entry, else: setup.entry - price))
    limit = StrategyPolicy.entry_atr() * setup.atr

    levels =
      price > 0 and setup.stop_loss > 0 and setup.take_profit > 0 and risk > 0 and
        risk <= StrategyPolicy.max_stop_atr() * setup.atr and
        if(buy?,
          do: setup.stop_loss < price and price < setup.take_profit,
          else: setup.take_profit < price and price < setup.stop_loss
        )

    structure =
      if Map.get(setup, :setup_kind) == "breakout_retest" do
        if buy?, do: price > setup.stop_loss, else: price < setup.stop_loss
      else
        case Map.get(setup, :zone) do
          %{low: low, high: high} -> if buy?, do: price > low, else: price < high
          _ -> true
        end
      end

    rr = if risk > 0, do: (reward - cost) / (risk + cost), else: 0.0

    %{
      risk: risk,
      reward: reward,
      adverse: adverse,
      limit: limit,
      drift_ok: adverse <= limit + 1.0e-9,
      levels_ok: levels,
      structure_ok: structure,
      target_reached: if(buy?, do: price >= setup.take_profit, else: price <= setup.take_profit),
      reward_risk: rr,
      reward_risk_ok: rr + 1.0e-9 >= StrategyPolicy.min_reward_risk()
    }
  end

  def fresh_quote?(%{price: price, timestamp: %DateTime{} = at}, now)
      when is_number(price) and price > 0 do
    DateTime.diff(now, at) in -5..120
  end

  def fresh_quote?(_, _), do: false
end
