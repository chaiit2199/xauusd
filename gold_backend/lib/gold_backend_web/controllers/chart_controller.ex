defmodule GoldBackendWeb.ChartController do
  use GoldBackendWeb, :controller
  alias GoldBackend.Services.CandleStore

  # Read-only chart feed; never refreshes providers or evaluates a strategy.
  def index(conn, _params) do
    now = DateTime.utc_now()
    candles = CandleStore.load(900, now)

    items =
      Enum.map(candles, fn c ->
        %{
          t: DateTime.to_unix(c.open_time, :millisecond),
          o: c.open,
          h: c.high,
          l: c.low,
          c: c.close
        }
      end)

    json(conn, %{
      data: %{
        candles: items,
        timeframe: "M15",
        source: "gold_api_ohlc",
        as_of: DateTime.to_iso8601(now)
      }
    })
  end
end
