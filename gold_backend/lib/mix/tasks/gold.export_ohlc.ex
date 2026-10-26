defmodule Mix.Tasks.Gold.ExportOhlc do
  use Mix.Task

  @shortdoc "Export stored OHLC and evaluation quotes from the configured read-only database as JSON"
  def run(_) do
    Mix.Task.run("app.config")
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = GoldBackend.Repo.start_link()

    result =
      GoldBackend.Repo.transaction(fn ->
        GoldBackend.Repo.query!("SET TRANSACTION READ ONLY")

        candles =
          GoldBackend.Repo.query!(
            "SELECT open_time, timeframe, open, high, low, close FROM market_candles WHERE source = 'gold_api_ohlc' ORDER BY open_time, timeframe"
          ).rows

        quotes =
          case GoldBackend.Repo.query!("SELECT to_regclass('strategy_observations')").rows do
            [[nil]] ->
              []

            _ ->
              GoldBackend.Repo.query!(
                "SELECT DISTINCT quote_at, quote_price FROM strategy_observations WHERE quote_at IS NOT NULL AND quote_price IS NOT NULL ORDER BY quote_at, quote_price"
              ).rows
          end

        %{
          candles:
            Enum.map(candles, fn [at, timeframe, open, high, low, close] ->
              %{
                open_time: iso(at),
                timeframe: timeframe,
                open: Decimal.to_float(open),
                high: Decimal.to_float(high),
                low: Decimal.to_float(low),
                close: Decimal.to_float(close)
              }
            end),
          quotes:
            Enum.map(quotes, fn [at, price] ->
              %{timestamp: iso(at), price: Decimal.to_float(price)}
            end)
        }
      end)

    case result do
      {:ok, data} -> IO.puts(Jason.encode!(data))
      {:error, reason} -> Mix.raise("read-only export failed: #{inspect(reason)}")
    end
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp iso(%NaiveDateTime{} = at),
    do: DateTime.from_naive!(at, "Etc/UTC") |> DateTime.to_iso8601()
end
