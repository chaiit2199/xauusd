defmodule GoldBackend.Services.TradePlanTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.{OllamaAnalyzer, TradePlan}

  test "a downtrend with room to sell places the stop above entry and the target below" do
    plan =
      TradePlan.build(
        indicators(%{rsi_14: 48.0, stochastic_k: 40.0, macd: -2.0, roc_10: -0.4}),
        4130.4
      )

    assert plan.action == "sell"
    assert plan.action_label == "Bán"
    assert plan.stop_distance == 4.0
    assert plan.take_distance == 8.0
    assert plan.stop_loss > plan.entry
    assert plan.take_profit < plan.entry
    assert plan.reward_risk == 2.0
    assert plan.reward_risk_after_spread > 1.5
    assert plan.stop_points == round(plan.stop_distance * 100)
    assert plan.take_points == plan.stop_points * 2
    assert plan.risk_score in 1..10
  end

  test "an uptrend places the stop below entry" do
    plan =
      TradePlan.build(
        indicators(%{
          current_price: 200.0,
          sma_20: 199.8,
          ema_50: 180.0,
          rsi_14: 48.0,
          macd: 1.5,
          roc_10: 0.8,
          stochastic_k: 55.0,
          atr_14: 1.0,
          volatility_std: 1.2,
          bollinger_bands: %{upper: 210.0, lower: 170.0},
          pivot_level: %{p: 195.0, r1: 205.0, s1: 185.0}
        }),
        200.0
      )

    assert plan.action == "buy"
    assert plan.action_label == "Mua"
    assert plan.stop_loss < plan.entry
    assert plan.take_profit > plan.entry
  end

  test "seeded history blocks a live order" do
    plan =
      TradePlan.build(indicators(%{}), 4130.4,
        warmup: true,
        warmup_detail: "Giá hiện tại vẫn là dữ liệu khởi tạo (seed)."
      )

    assert plan.action == "wait"
    assert plan.block_reason =~ "khởi tạo"
  end

  test "news digest is attached to the ticket and raises risk when conflicting" do
    bias = %{
      tone: :gold_bullish,
      tone_label: "Tin nghiêng ủng hộ vàng",
      high_impact: true,
      trade_block: false,
      digest: "Tin nghiêng ủng hộ vàng (ủng hộ 2, đè 0)."
    }

    plan =
      TradePlan.build(indicators(%{stochastic_k: 5.0, rsi_14: 32.0}), 4130.4, news_bias: bias)

    assert plan.news_tone == "Tin nghiêng ủng hộ vàng"
    assert plan.news_digest =~ "ủng hộ vàng"
    assert Enum.any?(plan.notes, &String.contains?(&1, "ngược hướng"))
    assert plan.risk_score >= 7
  end

  test "recent high-impact USD news locks an otherwise valid sell" do
    bias = %{
      tone: :mixed,
      tone_label: "Tin trái chiều",
      high_impact: true,
      trade_block: true,
      digest: "Có tin USD tác động mạnh mới xuất hiện."
    }

    plan = TradePlan.build(indicators(%{}), 4130.4, news_bias: bias)

    assert plan.action == "wait"
    assert plan.block_reason =~ "Khóa lệnh 90 phút"
  end

  test "V reversal from below the lower band blocks a late sell" do
    plan =
      TradePlan.build(
        indicators(%{
          current_price: 4100.9,
          sma_20: 4121.97,
          ema_50: 4125.11,
          rsi_14: 39.12,
          macd: -8.8254,
          bollinger_bands: %{upper: 4154.69, lower: 4089.24},
          atr_14: 8.83,
          stochastic_k: 28.0,
          pivot_level: %{p: 4130.23, r1: 4139.37, s1: 4118.17},
          roc_10: -0.99
        }),
        4100.9,
        price_action: %{
          low: 4069.8,
          high: 4123.6,
          rebound_from_low: 31.1,
          pullback_from_high: 22.7
        }
      )

    assert plan.action == "wait"
    assert plan.block_reason =~ "Không bán đuổi"
    assert plan.block_reason =~ "4069.80"
  end

  test "commentary that recommends a buy is replaced by the locked ticket" do
    plan = TradePlan.build(indicators(%{}), 4130.4, warmup: true)

    {:ok, text} =
      OllamaAnalyzer.align({:ok, "DeepSeek khuyên 3. Định kiến: Mua tại 4130."}, plan)

    assert String.downcase(text) =~ "không giao dịch"
    refute text =~ "DeepSeek"
    refute text =~ "Định kiến: Mua"
  end

  test "selling into an oversold stochastic stays flat and still publishes levels" do
    plan = TradePlan.build(indicators(%{stochastic_k: 5.0, rsi_14: 32.0}), 4130.4)

    assert plan.action == "wait"
    assert plan.action_label == "Không giao dịch"
    assert plan.lean == "sell"
    assert plan.stop_loss > plan.entry
    assert plan.take_profit < plan.entry
    assert plan.risk_score >= 7
    assert [short] = plan.watchlist
    assert short.side == "sell"
    assert short.entry_low < short.entry_high
    assert short.stop_loss > short.entry_high
    assert short.order_type == "sell_limit"
    assert short.entry_low > plan.entry
    assert short.condition =~ "RSI 45–55"
  end

  defp indicators(overrides) do
    Map.merge(
      %{
        current_price: 4130.4,
        sma_20: 4131.2,
        ema_50: 4140.11,
        rsi_14: 48.0,
        macd: -3.3,
        bollinger_bands: %{upper: 4145.45, lower: 4128.0},
        atr_14: 2.0,
        stochastic_k: 40.0,
        pivot_level: %{p: 4145.13, r1: 4152.16, s1: 4120.0},
        roc_10: -0.2,
        volatility_std: 3.8
      },
      overrides
    )
  end
end
