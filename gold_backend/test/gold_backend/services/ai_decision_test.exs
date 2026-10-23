defmodule GoldBackend.Services.AiDecisionTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.{AiDecision, TelegramNotifier}

  test "accepts only a structured action with a reason" do
    assert {:ok, :buy, _reason} =
             AiDecision.parse(%{
               "action" => "buy",
               "reason" =>
                 "Xu hướng tăng, giá nằm trên đường trung bình với động lượng tích cực. Chờ xác nhận và theo dõi rủi ro từ tin kinh tế trước khi mua."
             })

    assert {:error, _} = AiDecision.parse(%{"action" => "hold", "reason" => "x"})
    assert {:error, _} = AiDecision.parse(%{"action" => "sell", "reason" => " "})
    assert {:error, _} = AiDecision.parse(%{"action" => "buy", "reason" => "Giá tăng."})

    assert {:error, _} =
             AiDecision.parse(%{
               "action" => "wait",
               "reason" => String.duplicate("The market is uncertain. ", 5)
             })
  end

  test "invalid and empty Ollama responses return JSON-safe errors" do
    for response <- ["", ~s({"response":""}), ~s({"response":"not json"}), "{}"] do
      assert {:error, error} = AiDecision.decode_response(response)
      assert is_binary(error)
      assert {:ok, _} = Jason.encode(%{ai_error: error})
    end

    assert {:error, _} = AiDecision.decode_response(~s({"response":"{}","done_reason":"length"}))

    response =
      Jason.encode!(%{
        response:
          Jason.encode!(%{
            action: "sell",
            reason:
              "Xu hướng giảm, giá nằm dưới đường trung bình với động lượng yếu. Chờ xác nhận và theo dõi rủi ro từ tin kinh tế trước khi bán."
          })
      })

    assert {:ok, :sell, _reason} =
             AiDecision.decode_response(response)
  end

  test "only a complete visible JSON answer is accepted outside thinking or fences" do
    valid =
      Jason.encode!(%{
        action: "wait",
        reason:
          "Chờ xác nhận xu hướng, chưa giao dịch khi tin tức xung đột. Giá và động lượng chưa đồng thuận nên cần theo dõi thêm trước khi mở vị thế."
      })

    for content <- ["```json\n#{valid}\n```", "<think>English internal text</think>\n#{valid}"] do
      assert {:ok, :wait, _} = AiDecision.decode_response(Jason.encode!(%{response: content}))
    end

    for content <- ["<think>#{valid}", "<think>#{valid}</think>", "prefix #{valid}"] do
      assert {:error, _} = AiDecision.decode_response(Jason.encode!(%{response: content}))
    end

    assert {:error, _} =
             AiDecision.decode_response(Jason.encode!(%{response: valid, done_reason: "length"}))
  end

  test "wait message includes the reason but no order levels" do
    snapshot = %{
      cfd_plan: %{action: "wait", entry: 2000, block_reason: "Chưa đủ tín hiệu"},
      ai_insight: "Chưa đủ tín hiệu",
      ai_error: nil,
      ai_cached_at: "2026-10-22T10:00:00Z"
    }

    message = TelegramNotifier.format_message(snapshot)
    assert message =~ "Khuyến nghị: Đứng ngoài"
    assert message =~ "Chưa đủ tín hiệu"
    refute message =~ "SL:"
  end

  test "buy notification includes entry, target, stop and indicators" do
    snapshot = %{
      cfd_plan: %{action: "buy", entry: 2000, take_profit: 2020, stop_loss: 1990},
      indicators_10: %{sma_20: 1995, macd: 1.2, rsi_14: 60},
      ai_insight: "Xu hướng tăng",
      ai_error: nil
    }

    message = TelegramNotifier.format_message(snapshot)
    assert message =~ "Khuyến nghị: Mua"
    assert message =~ "Giá vào lệnh: 2000"
    assert message =~ "TP: 2020 | SL: 1990"
    assert message =~ "SMA20 1995, MACD 1.2, RSI 60"
  end
end
