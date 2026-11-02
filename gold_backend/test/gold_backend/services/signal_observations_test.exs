defmodule GoldBackend.Services.SignalObservationsTest do
  use ExUnit.Case, async: false
  alias GoldBackend.Repo
  alias GoldBackend.Services.{CandleStore, SignalObservations}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "enrichment retains stored outcome and reports extrema only for complete observed windows" do
    now = ~U[2026-11-01 00:00:00Z]

    for i <- 0..7 do
      CandleStore.put(
        %{
          source: "gold_api_ohlc",
          open_time: DateTime.add(now, i * 900),
          open: 100.0,
          high: 102.0 + i,
          low: 99.0,
          close: 101.0
        },
        900
      )
    end

    original = %{
      "status" => "ambiguous",
      "entry_price" => 100.0,
      "observed_from" => DateTime.to_iso8601(now),
      "observed_through" => DateTime.to_iso8601(DateTime.add(now, 7200))
    }

    [enriched] = SignalObservations.enrich([%{setup_id: "complete", result: original}])
    assert Map.take(enriched.result, Map.keys(original)) == original
    assert enriched.result["observed_high"] == 109.0
    assert enriched.result["observed_low"] == 99.0
    assert enriched.result["observed_count"] == 8

    missing =
      Map.put(original, "observed_from", DateTime.to_iso8601(DateTime.add(now, -900)))
      |> Map.put("observed_through", DateTime.to_iso8601(DateTime.add(now, 6300)))

    [partial] = SignalObservations.enrich([%{setup_id: "partial", result: missing}])
    assert partial.result["observed_high"] == nil
    assert partial.result["status"] == "ambiguous"
  end
end
