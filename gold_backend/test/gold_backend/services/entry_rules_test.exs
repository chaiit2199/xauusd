defmodule GoldBackend.Services.EntryRulesTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.{EntryRules, TradePlan, TelegramNotifier}

  test "allows a trend-aligned entry near SMA after RSI resets for both sides" do
    for side <- [:sell, :buy] do
      i = indicators(side)
      assert %{blocked: false, reasons: []} = EntryRules.assess(i, side)
      plan = TradePlan.build(i, i.current_price, ai_action: side)
      assert plan.action == Atom.to_string(side)
      refute plan.entry_guard.blocked
    end
  end

  test "AI cannot override RSI and stochastic chase limits" do
    for {side, field, value, text} <- [
          {:sell, :rsi_14, 34.99, "RSI"},
          {:sell, :stochastic_k, 29.99, "Stochastic"},
          {:buy, :rsi_14, 65.01, "RSI"},
          {:buy, :stochastic_k, 75.01, "Stochastic"}
        ] do
      i = Map.put(indicators(side), field, value)
      plan = TradePlan.build(i, i.current_price, ai_action: side)
      assert plan.action == "wait"
      assert plan.block_reason =~ text
      assert [zone] = plan.watchlist
      assert zone.side == Atom.to_string(side)
      assert zone.order_type == if(side == :sell, do: "sell_limit", else: "buy_limit")

      assert :ok =
               TelegramNotifier.notify(%{cfd_plan: plan, ai_error: nil},
                 http_post: fn _, _, _, _ -> flunk("blocked entry must not send") end
               )
    end
  end

  test "reset RSI ranges are inclusive and do not unlock wrong-side extremes" do
    for {side, range} <- [{:sell, 45..55}, {:buy, 45..50}], rsi <- range do
      refute EntryRules.assess(%{indicators(side) | rsi_14: rsi}, side).blocked
    end

    for {side, rsi} <- [
          {:sell, 35},
          {:sell, 44.99},
          {:sell, 55.01},
          {:buy, 44.99},
          {:buy, 50.01},
          {:buy, 65}
        ] do
      assert Enum.any?(
               EntryRules.assess(%{indicators(side) | rsi_14: rsi}, side).reasons,
               &String.contains?(&1, "Chờ RSI")
             )
    end

    refute EntryRules.assess(%{indicators(:sell) | stochastic_k: 30}, :sell).blocked
    refute EntryRules.assess(%{indicators(:buy) | stochastic_k: 75}, :buy).blocked
  end

  test "touching or approaching either Bollinger band blocks trend chasing" do
    for side <- [:sell, :buy], offset <- [0, 0.25, -0.25] do
      i = indicators(side)

      bands =
        if side == :sell,
          do: %{lower: i.current_price - offset, upper: 120.0},
          else: %{lower: 80.0, upper: i.current_price + offset}

      result = EntryRules.assess(%{i | bollinger_bands: bands}, side)
      assert result.blocked
      assert Enum.any?(result.reasons, &String.contains?(&1, "Bollinger"))
    end
  end

  test "SMA stretch uses ATR and the 2 ATR cutoff is strict" do
    for side <- [:sell, :buy] do
      i = indicators(side)
      direction = if side == :sell, do: 1, else: -1
      at_limit = %{i | sma_20: i.current_price + direction * 2}
      beyond = %{i | sma_20: i.current_price + direction * 2.01}

      refute Enum.any?(
               EntryRules.assess(at_limit, side).reasons,
               &String.contains?(&1, "hơn 2 ATR")
             )

      assert Enum.any?(
               EntryRules.assess(beyond, side).reasons,
               &String.contains?(&1, "hơn 2 ATR")
             )
    end
  end

  test "support and resistance proximity blocks entries at S1, R1 and Pivot" do
    for {side, key, level} <- [
          {:sell, :s1, 99.5},
          {:sell, :p, 99.5},
          {:buy, :r1, 100.5},
          {:buy, :p, 100.5}
        ] do
      i = indicators(side)
      i = put_in(i, [:pivot_level, key], level)

      assert Enum.any?(
               EntryRules.assess(i, side).reasons,
               &(String.contains?(&1, "S1/Pivot") or String.contains?(&1, "R1/Pivot"))
             )
    end
  end

  test "a retest requires ordered break, revisit and continuation; extrema are insufficient" do
    assert EntryRules.retest_state([], 100, :sell, 0.25) == :unknown
    assert EntryRules.retest_state([102, 98, 99.9, 99.6], 100, :sell, 0.25) == :confirmed
    assert EntryRules.retest_state([98, 102, 100.1, 100.4], 100, :buy, 0.25) == :confirmed
    assert EntryRules.retest_state([102, 99.9, 99.6, 98], 100, :sell, 0.25) == :pending
    assert EntryRules.retest_state([99, 98, 99.9, 99.6], 100, :sell, 0.25) == :unknown
    assert EntryRules.retest_state([102, 98, 99.9], 100, :sell, 0.25) == :testing
    assert EntryRules.retest_state([102, 98, 99.9, 99.6, 102, 98], 100, :sell, 0.25) == :pending
  end

  test "a break without retest stays blocked even with RSI reset and price near SMA" do
    for side <- [:sell, :buy] do
      i = indicators(side)
      key = if side == :sell, do: :s1, else: :r1
      i = put_in(i, [:pivot_level, key], 100.0)
      assert EntryRules.assess(i, side).blocked
      assert EntryRules.assess(i, side, %{low: 98.0, high: 102.0}).blocked
      prices = if side == :sell, do: [102, 98, 99.9, 99.6], else: [98, 102, 100.1, 100.4]
      refute EntryRules.assess(i, side, %{prices: prices}).blocked
    end
  end

  test "blocked sell uses only a sell pullback; blocked buy uses only a buy pullback" do
    for side <- [:sell, :buy] do
      i = %{indicators(side) | rsi_14: if(side == :sell, do: 30, else: 70)}
      plan = TradePlan.build(i, i.current_price, ai_action: side)
      assert [zone] = plan.watchlist
      assert zone.entry_low < zone.entry_high
      assert zone.reward_risk > 0

      if side == :sell do
        assert zone.entry_low > plan.entry
        assert zone.stop_loss > zone.entry_high
        assert zone.take_profit < zone.entry_low
        assert zone.condition =~ "45–55"
      else
        assert zone.entry_high < plan.entry
        assert zone.stop_loss < zone.entry_low
        assert zone.take_profit > zone.entry_high
        assert zone.condition =~ "45–50"
      end
    end
  end

  test "reported price and indicators block a sell despite attractive reward/risk" do
    i = %{
      indicators(:sell)
      | current_price: 4078.7,
        sma_20: 4106.66,
        ema_50: 4110.0,
        macd: -14.3237,
        rsi_14: 36.63,
        atr_14: 8.64,
        bollinger_bands: %{lower: 4058.56, upper: 4154.76},
        pivot_level: %{s1: 4118.17, p: 4130.23, r1: 4139.37}
    }

    plan = TradePlan.build(i, 4078.7, ai_action: :sell)
    assert plan.reward_risk_after_spread > 1.9
    assert plan.action == "wait"
    assert plan.block_reason =~ "hơn 2 ATR"
    assert [zone] = plan.watchlist
    assert zone.entry_low == 4102.34
    assert zone.entry_high == 4106.66
  end

  test "seed quotes never publish pending entry zones and AI cannot reverse the trend" do
    i = indicators(:sell)
    assert TradePlan.build(i, i.current_price, warmup: true, ai_action: :sell).watchlist == []
    plan = TradePlan.build(i, i.current_price, ai_action: :buy)
    assert plan.action == "wait"
    assert [zone] = plan.watchlist
    assert zone.side == "sell"
  end

  test "confirmed sweeps replace only the pullback location requirement on both sides" do
    for side <- [:buy, :sell] do
      i = away_from_sma(side)
      setup = sweep(i, side)
      assert %{blocked: true, reasons: [reason]} = EntryRules.assess(i, side)
      assert reason =~ "0,5 ATR"
      assert %{blocked: false, reasons: []} = EntryRules.assess(i, side, %{}, m15_setup: setup)

      legacy = TradePlan.build(i, i.current_price, ai_action: side)
      assert legacy.action == "wait"
      plan = TradePlan.build(i, i.current_price, ai_action: side, m15_setup: setup)
      assert plan.action == Atom.to_string(side)
      assert plan.stop_loss == setup.stop_loss
    end
  end

  test "missing, pending, unknown and wrong-side setups do not waive the location check" do
    for side <- [:buy, :sell] do
      i = away_from_sma(side)
      setup = sweep(i, side)
      other = if side == :buy, do: :sell, else: :buy

      for candidate <- [
            nil,
            %{setup | blocked: true},
            %{setup | pattern: nil},
            %{setup | pattern: "breakout"},
            %{setup | action: Atom.to_string(other)},
            sweep(i, other)
          ] do
        result = EntryRules.assess(i, side, %{}, m15_setup: candidate)
        assert result.blocked
        assert Enum.any?(result.reasons, &String.contains?(&1, "0,5 ATR"))
      end
    end
  end

  test "confirmed sweeps still obey RSI, stochastic, stretch and unconfirmed pivot breaks" do
    for side <- [:buy, :sell] do
      i = away_from_sma(side)

      for {changes, reason} <- [
            {%{rsi_14: if(side == :sell, do: 34.0, else: 66.0)}, "RSI"},
            {%{rsi_14: if(side == :sell, do: 44.0, else: 51.0)}, "Chờ RSI"},
            {%{stochastic_k: if(side == :sell, do: 29.0, else: 76.0)}, "Stochastic"},
            {%{sma_20: i.current_price + if(side == :sell, do: 2.1, else: -2.1)}, "hơn 2 ATR"},
            {%{pivot_level: %{s1: 100.0, r1: 100.0, p: 105.0}}, "chưa xác nhận retest"}
          ] do
        changed = Map.merge(i, changes)
        result = EntryRules.assess(changed, side, %{}, m15_setup: sweep(changed, side))
        assert result.blocked
        assert Enum.any?(result.reasons, &String.contains?(&1, reason))

        assert TradePlan.build(changed, changed.current_price,
                 ai_action: side,
                 m15_setup: sweep(changed, side)
               ).action == "wait"
      end
    end
  end

  defp away_from_sma(side) do
    %{indicators(side) | sma_20: if(side == :sell, do: 101.0, else: 99.0)}
  end

  defp sweep(i, side) do
    %{
      blocked: false,
      action: Atom.to_string(side),
      indicators: i,
      atr: i.atr_14,
      pattern: if(side == :sell, do: "bearish_sweep_pinbar", else: "bullish_sweep_pinbar"),
      stop_loss: i.current_price + if(side == :sell, do: 3.0, else: -3.0)
    }
  end

  defp indicators(side) do
    sell? = side == :sell

    %{
      current_price: if(sell?, do: 99.6, else: 100.4),
      sma_20: 100.0,
      ema_50: if(sell?, do: 101.0, else: 99.0),
      macd: if(sell?, do: -1.0, else: 1.0),
      rsi_14: 48.0,
      stochastic_k: 50.0,
      atr_14: 1.0,
      roc_10: if(sell?, do: -0.2, else: 0.2),
      volatility_std: 1.0,
      bollinger_bands: %{lower: 90.0, upper: 110.0},
      pivot_level: %{s1: 95.0, p: if(sell?, do: 105.0, else: 95.0), r1: 110.0}
    }
  end
end
