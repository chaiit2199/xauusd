defmodule GoldBackend.Services.SetupPolicyTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.{
    SetupEngine,
    SetupLifecycle,
    StrategyPlan,
    EntryQuality,
    DecisionPlan,
    RuleStatistics
  }

  @now ~U[2026-10-23 16:00:35Z]
  @neutral %{
    side: "neutral",
    reason: "H1 trung tính",
    adx: 15.0,
    data_status: "ready",
    regime: "neutral"
  }
  @i %{current_price: 102.0, sma_20: 102.0, macd: 0.0, rsi_14: 50.0}

  defp bars do
    Enum.map(0..49, fn n ->
      %{
        open_time: DateTime.add(~U[2026-10-23 16:00:00Z], (n - 50) * 900),
        open: 100.0,
        high: 101.0,
        low: 99.0,
        close: 100.0,
        confirmed: true
      }
    end)
    # Target is a pivot confirmed before the 20-bar breakout range starts.
    |> List.update_at(10, &%{&1 | high: 110.0})
    |> List.update_at(-2, &%{&1 | open: 100.5, close: 102.0, high: 102.1, low: 100.0})
    |> List.update_at(-1, &%{&1 | open: 101.4, close: 102.2, high: 102.4, low: 100.95})
  end

  defp plan(s, bias \\ @neutral, extra \\ []) do
    StrategyPlan.build(
      @i,
      s.entry,
      Keyword.merge(
        [
          bias: bias,
          m15_setup: s,
          as_of: @now,
          quote: %{price: s.entry, timestamp: @now},
          calendar_status: "ok"
        ],
        extra
      )
    )
  end

  test "neutral H1 allows symmetrical breakout retest with M15 targets outside preferred hours" do
    mirror =
      Enum.map(
        bars(),
        &%{
          &1
          | open: 200 - &1.open,
            close: 200 - &1.close,
            high: 200 - &1.low,
            low: 200 - &1.high
        }
      )

    for {input, side} <- [{bars(), "buy"}, {mirror, "sell"}] do
      s = SetupEngine.assess(input, @neutral, [], @now)
      assert s.state == "ready"
      assert s.setup_kind == "breakout_retest"
      assert s.zone.formed_at == "2026-10-23T15:45:00Z"
      assert String.starts_with?(s.barrier.id, "m15_swing_")
      p = plan(s)
      assert p.action == side
      assert p.decision_plan.side == side
      checks = Map.new(p.checks, &{&1.code, &1})
      assert checks["bias"].status == "warning"
      assert checks["session"].status == "warning"
      refute checks["direction"].required
      refute Map.has_key?(checks, "barrier_room")
      assert checks["reward_risk"].status == "pass"
      assert p.blocking_reasons == []
    end
  end

  test "missing H1, transition and opposing H1 are advisory" do
    s = SetupEngine.assess(bars(), @neutral, [], @now)

    for bias <- [
          %{@neutral | data_status: "unavailable", adx: nil},
          %{@neutral | regime: "transition"}
        ] do
      assert plan(s, bias).action == "buy"
    end

    # Structure BUY against H1 SELL: indicators do not block the rule ticket.
    opposing = plan(s, %{@neutral | side: "sell", regime: "sell"})
    assert opposing.action == "buy"
    checks = Map.new(opposing.checks, &{&1.code, &1})
    refute checks["direction"].required
    assert checks["direction"].status == "warning"

    assert SetupEngine.assess(
             bars(),
             %{@neutral | data_status: "unavailable", adx: nil},
             [],
             @now
           ).state == "ready"

    pullback = %{s | setup_kind: "trend_pullback"}
    # Neutral H1 still withholds trend-pullback planning preference in engine; a
    # ready pullback snapshot against neutral remains eligible once levels pass.
    assert plan(pullback, %{@neutral | side: "buy"}).action == "buy"
  end

  test "directional breakout runs independently while the old pullback zone is untouched" do
    mirror =
      Enum.map(
        bars(),
        &%{
          &1
          | open: 200 - &1.open,
            close: 200 - &1.close,
            high: 200 - &1.low,
            low: 200 - &1.high
        }
      )

    for {input, side, low, high} <- [{bars(), "buy", 50.0, 51.0}, {mirror, "sell", 149.0, 150.0}] do
      bias = %{@neutral | side: side, regime: side}
      old_zone = %{id: "sma20_h1", low: low, high: high, mid: (low + high) / 2}
      s = SetupEngine.assess(input, bias, [old_zone], @now)
      assert s.state == "ready" and s.setup_kind == "breakout_retest"
      assert plan(s, bias).action == side
      pullback = Enum.find(s.branches, &(&1.kind == "trend_pullback" and &1.side == side))
      breakout = Enum.find(s.branches, &(&1.kind == "breakout_retest" and &1.side == side))
      assert pullback.status == "unknown" and pullback.candidate_count == 0
      assert breakout.status == "pass" and breakout.side == side
    end
  end

  test "rejected wide stops retain levels for auditing without hiding an eligible alternative" do
    wide = %{id: "sma20_h1", low: 50.0, high: 101.0, mid: 100.0}
    bias = %{@neutral | side: "buy", regime: "buy"}
    s = SetupEngine.assess(bars(), bias, [wide], @now)
    assert s.state == "ready"
    assert plan(s, bias).action == "buy"
    assert [rejected] = s.rejected_candidates
    assert rejected.blocked and rejected.rejection_reason == "stop_cap"
    assert is_binary(rejected.id) and rejected.stop_loss < 50.0
    assert_in_delta rejected.take_profit, rejected.entry + 5.0, 0.01
  end

  test "a failed retest cannot be relabeled as a pullback at the newly formed breakout zone" do
    input =
      bars() |> List.update_at(-1, &%{&1 | open: 101.2, close: 101.4, low: 100.7, high: 101.5})

    bias = %{@neutral | side: "buy", regime: "buy"}
    assert SetupEngine.assess(input, bias, [], @now).blocked
  end

  test "neutral H1 permits a confirmed pinbar at a valid zone" do
    input =
      bars()
      |> List.update_at(-2, &%{&1 | open: 100.0, close: 100.0, low: 99.0, high: 101.0})
      |> List.update_at(-1, &%{&1 | open: 100.0, close: 100.5, low: 97.0, high: 100.6})

    zone = %{id: "sma20_h1", low: 99.0, mid: 100.0, high: 101.0}
    assert SetupEngine.assess(input, @neutral, [zone], @now).state == "ready"
  end

  test "retest candle cannot redefine the zone formed at the preceding breakout close" do
    original = SetupEngine.assess(bars(), @neutral, [], @now)
    wider = bars() |> List.update_at(-1, &%{&1 | high: 105.0})
    updated = SetupEngine.assess(wider, @neutral, [], @now)
    assert updated.zone == original.zone
    assert updated.zone.formed_at < updated.formed_at
    assert updated.barrier == original.barrier
  end

  test "retest tolerates an intrabar edge breach until SL, but a closing invalidation cancels permanently" do
    s = SetupEngine.assess(bars(), @neutral, [], @now)
    price = (s.zone.low + s.stop_loss) / 2
    assert EntryQuality.assess(s, price, 0.4).structure_ok
    refute EntryQuality.assess(s, s.stop_loss, 0.4).structure_ok
    assert SetupLifecycle.validate(s, [], @neutral, @now, []).state == "ready"
    b = %{open_time: ~U[2026-10-23 16:00:00Z], low: price, high: s.entry, close: price}

    assert SetupLifecycle.validate(s, [b], @neutral, DateTime.add(@now, 900), []).state ==
             "invalidated"

    b = %{b | close: s.entry}
    assert SetupLifecycle.validate(s, [b], @neutral, DateTime.add(@now, 900), []).state == "ready"
    interval = DecisionPlan.entry_zone(s, 0.4)
    assert EntryQuality.assess(s, interval.low, 0.4).structure_ok
    assert EntryQuality.assess(s, interval.high, 0.4).reward_risk_ok
  end

  test "calendar failure, expired verification and stale quotes still block a neutral breakout" do
    s = SetupEngine.assess(bars(), @neutral, [], @now)

    for extra <- [
          [calendar_status: "unavailable"],
          [calendar_valid_until: DateTime.to_iso8601(@now)],
          [quote: %{price: s.entry, timestamp: DateTime.add(@now, -121)}]
        ] do
      assert plan(s, @neutral, extra).action == "wait"
    end

    p = plan(s, @neutral, calendar_status: "unavailable")
    assert Enum.find(p.checks, &(&1.code == "calendar_window")).reason =~ "Chưa xác minh"
  end

  test "advisories do not hide a sole blocker or become unknown in statistics" do
    rows = [
      %{
        "checks" => [
          %{"code" => "session", "status" => "warning", "required" => false},
          %{"code" => "direction", "status" => "pass", "required" => false},
          %{"code" => "quote", "status" => "blocked", "required" => true}
        ]
      }
    ]

    stats = Map.new(RuleStatistics.summarize(rows), &{&1.code, &1})
    assert stats["quote"].sole_blocker == 1
    assert stats["session"].warning == 1
    assert stats["session"].blocked == 0
    assert stats["session"].unknown == 0
  end
end
