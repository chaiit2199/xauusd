defmodule GoldBackend.Services.OhlcContext do
  alias GoldBackend.Services.{CandleClock, Indicators}

  def build(m15, h1, slot) do
    m15 = closed(m15, 900, slot)
    h1 = closed(h1, 3600, CandleClock.closed_at(slot, 3600))

    if m15 == [] or h1 == [] do
      nil
    else
      latest_m15 = List.last(m15)
      latest_h1 = List.last(h1)

      ready =
        length(h1) >= 50 and
          DateTime.compare(
            DateTime.add(latest_h1.open_time, 3600),
            CandleClock.closed_at(slot, 3600)
          ) == :eq

      prices =
        Enum.map(m15, fn bar ->
          %{
            price: Decimal.from_float(bar.close * 1.0),
            timestamp: DateTime.add(bar.open_time, 899),
            currency: "USD",
            origin: "gold_api_ohlc"
          }
        end)

      %{
        summary: Indicators.summarize_candles(h1, 3600),
        prices: prices,
        latest: List.last(prices),
        h1_ready: ready,
        m15: m15,
        h1: h1,
        m15_closed_at: DateTime.add(latest_m15.open_time, 900) |> DateTime.to_iso8601()
      }
    end
  end

  defp closed(bars, seconds, slot) do
    bars
    |> Enum.filter(&(DateTime.compare(DateTime.add(&1.open_time, seconds), slot) != :gt))
    |> Enum.sort_by(& &1.open_time, DateTime)
  end
end
