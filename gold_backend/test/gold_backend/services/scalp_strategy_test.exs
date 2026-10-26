defmodule GoldBackend.Services.ScalpStrategyTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.{EntryQuality, SetupEngine, SetupLifecycle}

  @now ~U[2026-10-23 08:00:00Z]
  @zone %{id: "swing_low", low: 99.0, mid: 100.0, high: 101.0}

  defp bars(seconds) do
    Enum.map(0..49, fn n ->
      %{
        open_time: DateTime.add(@now, (n - 50) * seconds),
        open: 100.0,
        high: 100.5,
        low: 99.5,
        close: 100.0,
        confirmed: true
      }
    end)
    |> List.update_at(-1, &%{&1 | low: 98.5, high: 100.6, close: 100.5})
  end

  test "BUY and SELL pullbacks and countertrend reversals are scanned independently" do
    buy = bars(900)

    sell =
      Enum.map(buy, fn b ->
        %{b | open: 200 - b.open, high: 200 - b.low, low: 200 - b.high, close: 200 - b.close}
      end)

    for {input, side, bias_side, kind} <- [
          {buy, "buy", "buy", "trend_pullback"},
          {sell, "sell", "sell", "trend_pullback"},
          {buy, "buy", "sell", "countertrend_reversal"},
          {sell, "sell", "buy", "countertrend_reversal"}
        ] do
      zone = %{id: "sma20_h1", low: 99.0, mid: 100.0, high: 101.0}
      setup = SetupEngine.assess(input, %{side: bias_side, reason: "H1"}, [zone], @now)
      assert setup.state == "ready"
      assert setup.action == side and setup.setup_kind == kind
      assert Enum.find(setup.branches, &(&1.kind == kind and &1.side == side)).status == "pass"
    end
  end

  test "a prior zone touch followed by confirmation retains touch time" do
    zone = %{id: "sma20_h1", low: 99.0, mid: 100.0, high: 101.0}

    input =
      bars(900)
      |> List.update_at(-2, &%{&1 | open: 101.3, close: 101.02, low: 99.4, high: 101.4})
      |> List.update_at(-1, &%{&1 | open: 101.01, close: 101.4, low: 101.005, high: 101.5})

    setup = SetupEngine.assess(input, %{side: "buy", reason: "H1"}, [zone], @now)
    assert setup.state == "ready"
    assert setup.zone_touched_at == "2026-10-23T07:45:00Z"
    assert setup.confirmation_at == "2026-10-23T08:00:00Z"
  end

  test "M5 disabled retains the full H1/M15 path to a ready signal" do
    h1 =
      for n <- 0..59 do
        %{
          open_time: DateTime.add(@now, (n - 60) * 3600),
          open: 100.0,
          high: if(n == 35, do: 110.0, else: 100.5),
          low: 99.5,
          close: 100.0,
          confirmed: true
        }
      end

    m15 = bars(900)
    bias = GoldBackend.Services.BiasEngine.assess(h1, @now)
    setup = SetupLifecycle.assess_with_m5(m15, [], h1, bias, @now, [])
    assert setup == SetupLifecycle.assess(m15, h1, bias, @now, [])
    assert setup.state == "ready", inspect(setup)
    indicators = GoldBackend.Services.Indicators.summarize_candles(h1, 3600).indicators

    plan =
      GoldBackend.Services.StrategyPlan.build(indicators, setup.entry,
        bias: bias,
        m15_setup: setup,
        as_of: @now,
        quote: %{price: setup.entry, timestamp: @now},
        calendar_status: "ok"
      )

    assert plan.planning_action == "buy"
    assert plan.action == "buy"
    assert plan.trade_plan_status == "READY_TO_ENTER"
    assert plan.timeframe == "M15"
  end

  test "M15 context remains available while H1 history is unavailable" do
    context = GoldBackend.Services.OhlcContext.build(bars(900), [], @now)
    refute context.h1_ready
    assert context.summary_timeframe == "M15"
    assert length(context.m15) == 50
    assert GoldBackend.Services.BiasEngine.assess([], @now).data_status == "unavailable"
  end

  test "M5 confirmation uses closed provider bars and records its own lifetime" do
    setup =
      SetupEngine.assess(
        bars(300),
        %{side: "sell", reason: "H1 bearish"},
        [@zone],
        @now,
        nil,
        300
      )

    assert setup.action == "buy"
    assert setup.setup_kind == "countertrend_reversal"
    assert setup.timeframe_seconds == 300
    assert setup.expires_at == "2026-10-23T08:20:00Z"
    assert setup.zone_touched_at == "2026-10-23T08:00:00Z"
    assert length(setup.candidate_log) > 0

    refute SetupEngine.assess(
             Enum.map(bars(300), &Map.put(&1, :approx, true)),
             %{side: "sell"},
             [@zone],
             @now,
             nil,
             300
           ).state == "ready"
  end

  test "news does not erase an intact technical plan" do
    setup = SetupEngine.assess(bars(900), %{side: "buy"}, [@zone], @now)
    assert setup.state == "ready"
    event = %{impact: "High", country: "USD", time: @now}
    assert SetupLifecycle.validate(setup, [], %{side: "buy"}, @now, [event]).state == "ready"
  end

  test "1.3 R after spread remains acceptable" do
    setup = %{
      action: "buy",
      entry: 100.0,
      stop_loss: 97.0,
      take_profit: 104.82,
      atr: 2.0,
      zone: %{low: 99.0, high: 101.0}
    }

    quality = EntryQuality.assess(setup, 100.0, 0.4)
    assert_in_delta quality.reward_risk, 1.3, 0.001
    assert quality.reward_risk_ok
  end
end
