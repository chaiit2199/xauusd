defmodule GoldBackend.Services.IndicatorsTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.Indicators

  test "flat hourly prices produce neutral readings" do
    result = Indicators.calculate_10_indicators(series(List.duplicate(100, 40)))

    assert result.current_price == 100.0
    assert result.sma_20 == 100.0
    assert result.ema_50 == 100.0
    assert result.rsi_14 == 50.0
    assert result.macd == 0.0
    assert result.bollinger_bands == %{upper: 100.0, lower: 100.0}
    assert result.stochastic_k == 50.0
    assert result.roc_10 == 0.0
    assert result.volatility_std == 0.0
    assert result.pivot_level.p == 100.0
    assert Indicators.alerts(result) == []
  end

  test "a rising series sits above SMA 20 with positive ROC" do
    values = Enum.map(1..40, &(&1 + 1000))
    result = Indicators.calculate_10_indicators(series(values))

    assert result.current_price == 1040.0
    assert result.current_price > result.sma_20
    assert result.roc_10 > 0
    assert result.rsi_14 == 100.0
    assert result.macd > 0
  end

  test "M15 aggregation keeps four separate bars per hour" do
    prices =
      Enum.map(0..49, fn index ->
        %{
          price: Decimal.new(100 + index),
          timestamp: DateTime.add(~U[2026-10-01 00:00:00Z], index * 900)
        }
      end)

    result = Indicators.summarize(prices, 900)
    assert result.hourly_samples == 50
    assert result.indicators.sma_20 == 139.5
    assert Indicators.summarize(prices).hourly_samples == 13
  end

  defp series(values) do
    base = ~U[2026-10-01 00:00:00Z]

    Enum.with_index(values, fn value, index ->
      %{
        price: Decimal.new(value),
        timestamp: DateTime.add(base, index * 3600, :second)
      }
    end)
  end
end
