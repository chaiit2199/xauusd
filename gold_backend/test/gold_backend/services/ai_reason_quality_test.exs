defmodule GoldBackend.Services.AiReasonQualityTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.{AiDecision, InsightCache, TelegramNotifier, TradePlan}
  alias GoldBackendWeb.TradingController

  @reported "Tù trending H1 với giá 4078.7 và chỉ báo principal, diagonal và positive technical indicators, diagonal positive technical indicators. Ví dụ, diagonal positive technical indicators, principal technical indicator, diagonal positive technical indicators, principal technical indicator, diagonal positive technical indicators, principal technical ind..."
  @valid "Giá 4078.7 nằm dưới SMA20 4082.0, MACD -14.3237 cho thấy động lượng giảm. RSI 50.0 chưa xác nhận đảo chiều. Kịch bản bán mất hiệu lực nếu giá vượt vùng cắt lỗ; cần theo dõi rủi ro từ tin kinh tế. Chưa có đủ dữ liệu tin mới để đánh giá tác động."

  test "rejects the reported mixed-language repetition before notification truncation" do
    assert {:error, error} = AiDecision.parse(%{"action" => "sell", "reason" => @reported})
    assert error =~ "lặp nội dung"
  end

  test "Vietnamese accents alone do not validate an English explanation" do
    reason =
      "Vàng is trading below the moving average with negative momentum. The market outlook remains bearish, but a reversal is possible after the next economic release. Wait for confirmation before opening a position."

    assert {:error, "AI chưa trả nhận định tiếng Việt hợp lệ."} =
             AiDecision.validate_reason(reason)
  end

  test "repeated Vietnamese phrases, punctuation changes and long loops are rejected" do
    for reason <- [
          String.duplicate("Giá nằm dưới đường trung bình nên chờ xác nhận. ", 3),
          "Giá đang giảm. Chờ xác nhận xu hướng, CHỜ XÁC NHẬN XU HƯỚNG; chờ xác nhận xu hướng. Chưa có tin mới.",
          String.duplicate(@valid, 20)
        ] do
      assert {:error, _} = AiDecision.validate_reason(reason)
    end
  end

  test "accepts natural Vietnamese with technical abbreviations and repeated indicator names" do
    assert {:ok, :sell, @valid} = AiDecision.parse(%{"action" => "sell", "reason" => @valid})

    reason =
      "SMA20 nằm trên giá hiện tại, SMA20 vẫn hướng xuống. MACD âm xác nhận xu hướng giảm; MACD chưa có dấu hiệu đảo chiều. RSI 36.63 cần được theo dõi cùng ATR14 và EMA50. Chưa có dữ liệu về CPI, NFP, FOMC hay DXY để đánh giá tác động đến XAUUSD."

    assert {:ok, ^reason} = AiDecision.validate_reason(reason)
  end

  test "invalid AI rationale is omitted from the rule notification" do
    snapshot = %{
      cfd_plan: %{action: "sell", entry: 4078.7, take_profit: 4044.14, stop_loss: 4095.98},
      ai_insight: @reported,
      ai_error: nil
    }

    text = TelegramNotifier.format_message(snapshot)
    assert text =~ "Khuyến nghị: Bán"
    refute text =~ "diagonal"
  end

  test "bad rationale does not veto the rule sell" do
    snapshot = TradingController.analysis_snapshot(context(), :sell, @reported, nil)
    assert snapshot.cfd_plan.action == "sell"
    assert snapshot.ai_action == nil
    assert snapshot.ai_error =~ "lặp nội dung"
    assert snapshot.ai_insight == nil
  end

  test "a valid rationale preserves the action and computed levels" do
    context = context()
    snapshot = TradingController.analysis_snapshot(context, :sell, @valid, nil)
    assert snapshot.cfd_plan.action == "sell"
    assert snapshot.ai_action == "sell"
    assert snapshot.ai_error == nil
    assert snapshot.ai_insight == @valid
    assert snapshot.cfd_plan.entry == 4078.7
    assert snapshot.cfd_plan.take_profit == 4044.14
    assert snapshot.cfd_plan.stop_loss == 4095.98
  end

  test "a valid AI sell still becomes wait when the entry violates the pullback rules" do
    context = context()
    context = %{context | indicators: %{context.indicators | sma_20: 4106.66, rsi_14: 36.63}}
    context = %{context | plan: TradePlan.build(context.indicators, context.plan.entry)}
    snapshot = TradingController.analysis_snapshot(context, :sell, @valid, nil)
    assert snapshot.ai_error != nil
    assert snapshot.ai_action == nil
    assert snapshot.cfd_plan.action == "wait"
    assert snapshot.cfd_plan.entry_guard.blocked
    assert snapshot.cfd_plan.block_reason =~ "hơn 2 ATR"

    assert :ok =
             TelegramNotifier.notify(snapshot,
               http_post: fn _, _, _, _ -> flunk("must not send blocked sell") end
             )
  end

  test "opposing AI decisions are blocked without fetching another quote" do
    context = Map.put(context(), :analysis_at, DateTime.utc_now())

    snapshot =
      InsightCache.confirmed_snapshot(context, "sell", {:ok, :buy, @valid},
        quote: fn -> flunk("must not request quote") end
      )

    assert snapshot.cfd_plan.action == "sell"
    assert snapshot.ai_error =~ "chiều khác"
  end

  test "AI enrichment cannot change the published price levels" do
    context = Map.put(context(), :analysis_at, DateTime.utc_now())

    snapshot =
      InsightCache.confirmed_snapshot(context, "sell", {:ok, :sell, @valid},
        quote: fn -> {:ok, %{price: 4100.0}} end
      )

    assert snapshot.cfd_plan == context.plan
  end

  defp context do
    indicators = %{
      current_price: 4078.7,
      sma_20: 4082.0,
      ema_50: 4110.0,
      rsi_14: 50.0,
      macd: -14.3237,
      atr_14: 8.64,
      stochastic_k: 40.0,
      roc_10: -0.2,
      volatility_std: 3.8,
      bollinger_bands: %{upper: 4145.45, lower: 4060.0},
      pivot_level: %{p: 4100.0, r1: 4120.0, s1: 4060.0}
    }

    %{
      indicators: indicators,
      plan: TradePlan.build(indicators, 4078.7),
      warmup: false,
      warmup_detail: nil,
      events: [],
      news: [],
      prices: [],
      news_bias: %{tone_label: "Chưa có tin", digest: "Chưa có tin"},
      price_action: %{},
      price_ticks: 80,
      live_price_ticks: 80,
      summary: %{hourly_samples: 120, alerts: []},
      latest: %{
        price: Decimal.new("4078.7"),
        currency: "USD",
        origin: "gold_api",
        timestamp: ~U[2026-10-22 10:00:00Z]
      }
    }
  end
end
