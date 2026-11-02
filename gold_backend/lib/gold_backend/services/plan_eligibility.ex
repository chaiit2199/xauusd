defmodule GoldBackend.Services.PlanEligibility do
  @moduledoc "Frozen-reference hard gates, independent of live-quote admission."
  alias GoldBackend.Services.EntryQuality

  def checks(setup, spread) do
    valid_numbers =
      Enum.all?(
        [setup.entry, setup.stop_loss, setup.take_profit, setup.atr],
        &(is_number(&1) and &1 > 0)
      )

    quality =
      if valid_numbers and setup.action in ["buy", "sell"],
        do: EntryQuality.assess(setup, setup.entry, spread)

    invalidation = Map.get(setup, :invalidation_price)
    confirmation = Map.get(setup, :confirmation_at) || Map.get(setup, :formed_at)

    [
      check(
        "plan_confirmation",
        is_binary(Map.get(setup, :id)) and is_binary(confirmation) and not setup.blocked and
          setup.state == "ready",
        "Cần setup có xác nhận từ nến đã đóng và định danh cố định."
      ),
      check(
        "plan_invalidation",
        is_number(invalidation) and invalidation > 0 and valid_numbers and
          if(setup.action == "buy",
            do: setup.stop_loss <= invalidation and invalidation < setup.take_profit,
            else: setup.take_profit < invalidation and invalidation <= setup.stop_loss
          ),
        "Plan phải có SL và điểm vô hiệu cấu trúc rõ ràng."
      ),
      check(
        "plan_levels",
        quality != nil and quality.levels_ok,
        "Entry tham chiếu phải nằm giữa SL và TP; SL cấu trúc không vượt 5 giá."
      ),
      check(
        "plan_reward_risk",
        quality != nil and quality.reward_risk_ok,
        "R:R tại entry tham chiếu sau chi phí phải đạt ít nhất 1,2; không di chuyển SL/TP để vượt điều kiện."
      )
    ]
  end

  defp check(code, valid, reason),
    do: %{
      code: code,
      status: if(valid, do: "pass", else: "blocked"),
      reason: reason,
      required: true,
      scope: "plan"
    }
end
