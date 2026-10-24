defmodule GoldBackend.Services.StrategyPolicy do
  @moduledoc "Versioned experimental signal parameters; no broker execution or position accounting."
  def version, do: "zoi-v7-structure-ai"
  def assumed_spread, do: 0.4
  def simulation_seconds, do: 7200
  def entry_atr, do: 0.30
  def max_stop_atr, do: 5.0
  def min_reward_risk, do: 1.5
  def setup_seconds, do: 1800
  def quote_seconds, do: 120

  def h1_ready?(bias),
    do:
      Map.get(bias, :data_status) == "ready" or
        (not Map.has_key?(bias, :data_status) and
           (bias.side in ["buy", "sell"] or is_number(Map.get(bias, :adx))))

  def neutral_breakout?(setup, bias),
    do:
      h1_ready?(bias) and bias.side == "neutral" and
        Map.get(bias, :regime) != "transition" and
        Map.get(setup, :setup_kind) == "breakout_retest"

  # Preferred H1 alignment for ranking and advisories. Structure setups may still
  # fire against H1; indicators are context for AI, not a hard gate.
  def direction_aligned?(setup, bias),
    do:
      h1_ready?(bias) and
        (setup.action == bias.side or neutral_breakout?(setup, bias))

  def direction_allowed?(setup, bias), do: direction_aligned?(setup, bias)
end
