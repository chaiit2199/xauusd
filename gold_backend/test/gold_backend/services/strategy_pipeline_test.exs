defmodule GoldBackend.Services.StrategyPipelineTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.{
    BiasEngine,
    SetupEngine,
    StrategyPlan,
    EconomicCalendar,
    InsightCache,
    Zoi
  }

  @now ~U[2026-10-23 08:00:35Z]
  @zone %{id: "sma20_h1", low: 99.0, mid: 100.0, high: 101.0}
  @resistance %{id: "previous_day_high", low: 108.0, mid: 109.0, high: 110.0}
  @bias %{side: "buy", reason: "H1 tăng", locked_until: nil, adx: 30.0, slope: 0.5}

  defp bars do
    Enum.map(0..49, fn x ->
      %{
        open_time: DateTime.add(~U[2026-10-23 08:00:00Z], (x - 50) * 900),
        open: 100.0,
        close: 100.0,
        low: 99.5,
        high: 100.5,
        confirmed: true
      }
    end)
  end

  defp triggered do
    bars() |> List.update_at(-1, &%{&1 | open: 100.0, close: 100.5, low: 97.0, high: 100.6})
  end

  test "pinbar at ZOI is valid, same candle outside ZOI waits" do
    setup = SetupEngine.assess(triggered(), @bias, [@zone], @now)
    refute setup.blocked
    assert setup.pattern == "pullback_pinbar"
    assert setup.stop_loss < 97

    assert SetupEngine.assess(
             triggered(),
             @bias,
             [%{@zone | low: 110.0, high: 112.0, mid: 111.0}],
             @now
           ).state == "wait_zoi"
  end

  test "sell confirmation and candle stop are symmetric" do
    mirrored =
      Enum.map(triggered(), fn b ->
        %{b | open: 200 - b.open, close: 200 - b.close, high: 200 - b.low, low: 200 - b.high}
      end)

    support = %{id: "previous_day_low", low: 90.0, mid: 91.0, high: 92.0}
    setup = SetupEngine.assess(mirrored, %{@bias | side: "sell"}, [@zone, support], @now)
    assert setup.action == "sell"
    assert setup.stop_loss > setup.entry
    assert setup.take_profit < setup.entry
  end

  test "engulfing and reclaim are alternatives, not prerequisites of pinbar" do
    prev = %{open: 100.6, close: 99.8, high: 100.8, low: 99.7}
    bar = %{open: 99.7, close: 100.8, high: 100.9, low: 99.6}
    assert SetupEngine.pattern(bar, prev, @zone, "buy") == "pullback_engulfing"
    reclaim = %{open: 99.5, close: 100.8, high: 101.0, low: 98.0}

    assert SetupEngine.pattern(reclaim, %{prev | open: 99.8, close: 100.0}, @zone, "buy") ==
             "sweep_reclaim"

    refute SetupEngine.pattern(bar, prev, @zone, "sell")
  end

  test "a decisive close after a prior zone touch is a valid BUY or SELL reaction" do
    touch = %{open: 100.5, close: 99.8, low: 99.4, high: 100.7}
    reaction = %{open: 101.05, close: 101.6, low: 101.02, high: 101.7}

    assert SetupEngine.pattern(reaction, touch, @zone, "buy") == "reaction_close"

    input =
      bars()
      |> List.update_at(-2, &Map.merge(&1, touch))
      |> List.update_at(-1, &Map.merge(&1, reaction))

    setup = SetupEngine.assess(input, @bias, [@zone, @resistance], @now)
    assert setup.pattern == "reaction_close"
    assert setup.zone_touched_at == "2026-10-23T07:45:00Z"
    assert setup.confirmation_at == "2026-10-23T08:00:00Z"

    delayed =
      bars()
      |> List.update_at(-3, &Map.merge(&1, touch))
      |> List.update_at(-2, &%{&1 | open: 100.8, close: 100.8, low: 100.6, high: 101.0})
      |> List.update_at(-1, &Map.merge(&1, reaction))

    assert SetupEngine.assess(delayed, @bias, [@zone, @resistance], @now).pattern ==
             "reaction_close"

    delayed_three =
      bars()
      |> List.update_at(-4, &Map.merge(&1, touch))
      |> List.update_at(-3, &%{&1 | open: 100.8, close: 100.8, low: 100.6, high: 101.0})
      |> List.update_at(-2, &%{&1 | open: 100.9, close: 100.9, low: 100.7, high: 101.0})
      |> List.update_at(-1, &Map.merge(&1, reaction))

    assert SetupEngine.assess(delayed_three, @bias, [@zone, @resistance], @now).pattern ==
             "reaction_close"

    mirror = fn bar ->
      %{
        bar
        | open: 200 - bar.open,
          close: 200 - bar.close,
          high: 200 - bar.low,
          low: 200 - bar.high
      }
    end

    assert SetupEngine.pattern(mirror.(reaction), mirror.(touch), @zone, "sell") ==
             "reaction_close"
  end

  test "short, approximate, stale, duplicate and unconfirmed data fail closed" do
    for bs <- [
          [],
          Enum.take(triggered(), 29),
          List.update_at(triggered(), -1, &Map.put(&1, :approx, true)),
          List.update_at(triggered(), -1, &%{&1 | confirmed: false}),
          Enum.drop(triggered(), -1),
          List.replace_at(triggered(), 20, Enum.at(triggered(), 19))
        ] do
      assert SetupEngine.assess(bs, @bias, [@zone], @now).state == "data_unavailable"
    end

    forming = %{List.last(triggered()) | open_time: ~U[2026-10-23 08:00:00Z], confirmed: false}

    assert SetupEngine.assess(triggered() ++ [forming], @bias, [@zone], @now) ==
             SetupEngine.assess(triggered(), @bias, [@zone], @now)
  end

  test "bias invalidates immediately but opposite direction waits for cooldown" do
    first = BiasEngine.transition(%{side: "neutral", locked_until: nil, reason: ""}, "buy", @now)
    neutral = BiasEngine.transition(first, "neutral", DateTime.add(@now, 3600))
    assert neutral.side == "neutral"
    assert BiasEngine.transition(neutral, "sell", DateTime.add(@now, 3600)).side == "neutral"
    assert BiasEngine.transition(neutral, "sell", DateTime.add(@now, 7200)).side == "sell"
  end

  test "H1 uses closed bars and a flat market is neutral" do
    h1 =
      Enum.map(0..69, fn x ->
        %{
          open_time: DateTime.add(~U[2026-10-23 08:00:00Z], (x - 70) * 3600),
          open: 100.0 + x,
          close: 100.5 + x,
          low: 99.5 + x,
          high: 101.0 + x,
          confirmed: true
        }
      end)

    assert BiasEngine.assess(h1, @now).side == "buy"
    forming = %{List.last(h1) | open_time: ~U[2026-10-23 08:00:00Z], close: 1.0, confirmed: false}
    assert BiasEngine.assess(h1 ++ [forming], @now) == BiasEngine.assess(h1, @now)
    flat = Enum.map(h1, &%{&1 | open: 100.0, close: 100.0, high: 101.0, low: 99.0})
    assert BiasEngine.assess(flat, @now).side == "neutral"
  end

  defp options(setup, now \\ @now) do
    [
      bias: @bias,
      as_of: now,
      m15_setup: setup,
      quote: %{price: setup.entry, timestamp: now},
      calendar_status: "ok"
    ]
  end

  test "ready setup is not vetoed by RSI; AI may wait but cannot flip side" do
    setup = SetupEngine.assess(triggered(), @bias, [@zone, @resistance], @now)
    i = %{current_price: 101.0, sma_20: 100.0, macd: 1.0, rsi_14: 53.0}

    plan =
      StrategyPlan.build(
        i,
        setup.entry,
        options(setup) ++
          [
            ai_action: :sell,
            news_bias: %{trade_block: true, high_impact: true, tone: :gold_bearish}
          ]
      )

    assert plan.action == "buy"
    assert plan.spread_source == "assumed"
    assert plan.soft_flags != []

    reason =
      "Cấu trúc M15 ủng hộ mua tại vùng hỗ trợ với động lượng còn dương. Chỉ báo RSI trung tính nên cần theo dõi lệch entry. Tin áp lực giảm là rủi ro phụ. Xác nhận mua nếu giá giữ trên điểm vô hiệu."

    wait_reason =
      "Cấu trúc M15 còn đó nhưng tin áp lực giảm và chỉ báo chưa đồng thuận. Chưa mở lệnh khi rủi ro tin còn cao. Theo dõi điểm vô hiệu và chờ xác nhận rõ hơn. Đứng ngoài trong chu kỳ này."

    updated = InsightCache.apply_commentary(%{cfd_plan: plan}, {:ok, :buy, reason})
    assert updated.ai_action == "buy" and updated.ai_status == "ready"
    assert InsightCache.telegram_confirmed?(updated)

    veto = InsightCache.apply_commentary(%{cfd_plan: plan}, {:ok, :wait, wait_reason})
    assert veto.ai_action == "wait" and veto.ai_status == "ready"
    refute InsightCache.telegram_confirmed?(veto)

    for result <- [{:error, "timeout"}, {:ok, :sell, reason}, {:ok, :buy, "quá ngắn"}] do
      bad = InsightCache.apply_commentary(%{cfd_plan: plan}, result)
      assert bad.cfd_plan == plan
      assert bad.ai_status == "error"
      refute InsightCache.telegram_confirmed?(bad)
    end
  end

  test "all independent gates report blocked or unknown and never invent execution readiness" do
    setup = SetupEngine.assess([], @bias, [@zone], @now)
    i = %{current_price: 101.0, sma_20: 100.0, macd: 1.0, rsi_14: 53.0}

    plan =
      StrategyPlan.build(
        i,
        100.0,
        options(setup, ~U[2026-10-23 16:00:00Z])
        |> Keyword.put(:calendar_status, "unavailable")
        |> Keyword.put(:quote, nil)
      )

    assert plan.action == "wait"
    statuses = Map.new(plan.checks, &{&1.code, &1.status})
    assert statuses["session"] == "warning"
    assert statuses["quote"] == "warning"
    assert statuses["calendar_data"] == "unknown"
    assert statuses["reward_risk"] == "unknown"
  end

  test "spread cost, stale quote and a deteriorated RR still block entry" do
    setup = SetupEngine.assess(triggered(), @bias, [@zone, @resistance], @now)
    i = %{current_price: 101.0, sma_20: 100.0, macd: 1.0, rsi_14: 53.0}

    for opts <- [
          Keyword.put(options(setup), :spread, 2.0),
          Keyword.put(options(setup), :quote, %{
            price: setup.entry,
            timestamp: DateTime.add(@now, -121)
          })
        ] do
      assert StrategyPlan.build(i, setup.entry, opts).action == "wait"
    end

    assert StrategyPlan.build(
             i,
             setup.entry + 2,
             Keyword.put(options(setup), :quote, %{price: setup.entry + 2, timestamp: @now})
           ).action == "wait"
  end

  test "a fixed scalp target is allowed when no structural target blocks it" do
    setup = SetupEngine.assess(triggered(), @bias, [@zone], @now)
    assert_in_delta setup.take_profit, setup.entry + 5.0, 0.01
    i = %{current_price: 101.0, sma_20: 100.0, macd: 1.0, rsi_14: 53.0}
    plan = StrategyPlan.build(i, setup.entry, options(setup))
    assert plan.decision_plan.take_profit == setup.take_profit
    assert plan.decision_plan.cost.description =~ "giả định"
  end

  test "calendar includes all High USD events and exact asymmetric boundaries" do
    event = %{title: "New high impact event", country: "USD", impact: "High", time: @now}
    assert EconomicCalendar.snapshot(@now, 24, fetch: fn -> {:ok, [event]} end).events == [event]

    for delta <- [-900, 0, 1800],
        do: assert(EconomicCalendar.blocking([event], DateTime.add(@now, delta)) == event)

    for delta <- [-901, 1801],
        do: assert(EconomicCalendar.blocking([event], DateTime.add(@now, delta)) == nil)

    assert EconomicCalendar.snapshot(@now, 24, fetch: fn -> :error end).status == "unavailable"
  end

  test "previous-day levels are not invented from partial history" do
    assert [%{id: "sma20_h1"}] = Zoi.build([], %{sma_20: 100, atr_14: 2}, @now)
  end
end
