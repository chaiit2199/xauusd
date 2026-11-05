defmodule GoldBackend.Services.ZoneTouchTest do
  use ExUnit.Case, async: false
  alias GoldBackend.Services.{Zoi, SetupEngine}

  setup do
    old = Application.get_env(:gold_backend, :zone_touch)
    Application.put_env(:gold_backend, :zone_touch, atr_ratio: 0.05, max_usd: 0.30)

    on_exit(fn ->
      if old,
        do: Application.put_env(:gold_backend, :zone_touch, old),
        else: Application.delete_env(:gold_backend, :zone_touch)
    end)

    :ok
  end

  test "near touches are symmetric, capped and do not change structural boundaries" do
    original = %{id: "sma20_h1", low: 99.0, mid: 100.0, high: 101.0}
    zone = Zoi.with_touch_tolerance(original, 4.0)
    assert Map.drop(zone, [:touch_tolerance]) == original
    assert_in_delta zone.touch_tolerance, 0.20, 0.000001
    assert Zoi.touch?(%{low: 101.2, high: 102.0}, zone)
    assert Zoi.touch?(%{low: 98.0, high: 98.8}, zone)
    refute Zoi.touch?(%{low: 101.21, high: 102.0}, zone)
    refute Zoi.touch?(%{low: 98.0, high: 98.79}, zone)
    assert Zoi.with_touch_tolerance(original, 20.0).touch_tolerance == 0.30
    refute Zoi.touch?(%{low: 101.1, high: 102.0}, original)
    Application.put_env(:gold_backend, :zone_touch, atr_ratio: 0.0, max_usd: 0.30)
    assert Zoi.with_touch_tolerance(original, 4.0).touch_tolerance == 0
  end

  test "M15 near-touch pinbar becomes a candidate but still requires confirmation" do
    now = ~U[2026-10-23 08:00:35Z]

    bars =
      Enum.map(0..49, fn n ->
        %{
          open_time: DateTime.add(~U[2026-10-23 08:00:00Z], (n - 50) * 900),
          open: 102.0,
          close: 102.0,
          low: 101.5,
          high: 102.5,
          confirmed: true
        }
      end)

    zone = %{id: "sma20_h1", low: 99.0, mid: 100.0, high: 101.0}
    bias = %{side: "buy", reason: "test"}

    trigger =
      List.update_at(bars, -1, &%{&1 | open: 101.8, close: 101.9, low: 101.04, high: 102.0})

    relaxed = SetupEngine.assess(trigger, bias, [zone], now)
    assert relaxed.candidate_count > 0
    no_confirmation = List.update_at(trigger, -1, &%{&1 | open: 101.5, close: 101.5})
    assert SetupEngine.assess(no_confirmation, bias, [zone], now).candidate_count == 0
    too_far = List.update_at(trigger, -1, &%{&1 | low: 101.2})
    assert SetupEngine.assess(too_far, bias, [zone], now).candidate_count == 0
    assert relaxed.zone.low == zone.low
    assert relaxed.zone.high == zone.high
    assert SetupEngine.assess(bars, bias, [zone], now).candidate_count == 0
    Application.put_env(:gold_backend, :zone_touch, atr_ratio: 0.0, max_usd: 0.30)
    assert SetupEngine.assess(trigger, bias, [zone], now).candidate_count == 0
  end
end
