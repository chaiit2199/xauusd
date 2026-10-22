defmodule GoldBackend.Services.AiDecisionTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.{AiDecision, TelegramNotifier}

  test "accepts only a structured action with a reason" do
    assert {:ok, :buy, "Xu hướng tăng"} =
             AiDecision.parse(%{"action" => "buy", "reason" => "Xu hướng tăng"})

    assert {:error, _} = AiDecision.parse(%{"action" => "hold", "reason" => "x"})
    assert {:error, _} = AiDecision.parse(%{"action" => "sell", "reason" => " "})
  end

  test "invalid and empty Ollama responses return JSON-safe errors" do
    for response <- ["", ~s({"response":""}), ~s({"response":"not json"}), "{}"] do
      assert {:error, error} = AiDecision.decode_response(response)
      assert is_binary(error)
      assert {:ok, _} = Jason.encode(%{ai_error: error})
    end

    response = Jason.encode!(%{response: Jason.encode!(%{action: "sell", reason: "Giảm"})})
    assert {:ok, :sell, "Giảm"} = AiDecision.decode_response(response)
  end

  test "wait never sends a notification" do
    assert :ok = TelegramNotifier.notify(%{cfd_plan: %{action: "wait"}})
  end
end
