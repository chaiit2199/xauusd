defmodule GoldBackend.Services.StrategyPolicy do
  @moduledoc "Versioned experimental signal parameters; no broker execution or position accounting."
  def version, do: "zoi-v4-confluence"
  def assumed_spread, do: 0.4
  def simulation_seconds, do: 7200
  def entry_atr, do: 0.30
  def max_stop_atr, do: 5.0
  def min_reward_risk, do: 1.5
  def setup_seconds, do: 1800
  def quote_seconds, do: 120
end
