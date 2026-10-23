defmodule GoldBackend.Services.Zoi do
  @moduledoc "SMA20 H1 and the previous completed UTC trading day's high/low; zones are built before the trigger candle."
  def build(h1, indicators, at) do
    prior =
      Enum.filter(
        h1,
        &(Date.compare(DateTime.to_date(&1.open_time), DateTime.to_date(at)) == :lt)
      )

    day_zones =
      case List.last(prior) do
        nil ->
          []

        last ->
          day =
            Enum.filter(
              prior,
              &(DateTime.to_date(&1.open_time) == DateTime.to_date(last.open_time))
            )

          # Do not fabricate daily extrema from an incomplete daily slice.
          if length(day) >= 23 do
            [
              zone(
                "previous_day_high",
                Enum.max_by(day, & &1.high).high,
                indicators.atr_14 * 0.2
              ),
              zone("previous_day_low", Enum.min_by(day, & &1.low).low, indicators.atr_14 * 0.2)
            ]
          else
            []
          end
      end

    [zone("sma20_h1", indicators.sma_20, indicators.atr_14 * 0.35) | day_zones]
  end

  def touch?(bar, zone), do: bar.low <= zone.high and bar.high >= zone.low
  defp zone(id, mid, half), do: %{id: id, low: mid - half, mid: mid, high: mid + half}
end
