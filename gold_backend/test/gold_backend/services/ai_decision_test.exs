defmodule GoldBackend.Services.AiDecisionTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.{AiDecision, TelegramNotifier}

  test "accepts only a structured action with a reason" do
    assert {:ok, :buy, "Xu hướng tăng"} =
             AiDecision.parse(%{"action" => "buy", "reason" => "Xu hướng tăng"})

    assert {:error, _} = AiDecision.parse(%{"action" => "hold", "reason" => "x"})
    assert {:error, _} = AiDecision.parse(%{"action" => "sell", "reason" => " "})
  end

  test "wait never sends a notification" do
    assert :ok = TelegramNotifier.notify(%{cfd_plan: %{action: "wait"}})
  end
end
