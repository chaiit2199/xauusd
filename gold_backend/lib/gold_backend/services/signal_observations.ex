defmodule GoldBackend.Services.SignalObservations do
  @moduledoc "Read-only chart enrichment of stored simulator results; never re-evaluates outcomes."
  import Ecto.Query
  alias GoldBackend.Repo
  alias GoldBackend.Trading.MarketCandle

  def enrich(items) do
    windows =
      Enum.flat_map(items, fn item ->
        with {:ok, from, _} <- DateTime.from_iso8601(item.result["observed_from"] || ""),
             {:ok, through, _} <- DateTime.from_iso8601(item.result["observed_through"] || ""),
             seconds when seconds > 0 and seconds <= 7200 and rem(seconds, 900) == 0 <-
               DateTime.diff(through, from) do
          [{item.setup_id, from, through, div(seconds, 900)}]
        else
          _ -> []
        end
      end)

    predicate =
      Enum.reduce(windows, dynamic(false), fn {_, from, through, _}, acc ->
        dynamic([c], ^acc or (c.open_time >= ^from and c.open_time < ^through))
      end)

    bars =
      if windows == [],
        do: [],
        else:
          Repo.all(
            from c in MarketCandle,
              where: c.source == "gold_api_ohlc" and c.timeframe == 900,
              where: ^predicate,
              select: %{t: c.open_time, high: c.high, low: c.low},
              order_by: c.open_time
          )

    summaries =
      Map.new(windows, fn {id, from, through, count} ->
        observed =
          Enum.filter(
            bars,
            &(DateTime.compare(&1.t, from) != :lt and DateTime.compare(&1.t, through) == :lt)
          )

        complete =
          length(observed) == count and
            Enum.all?(Enum.with_index(observed), fn {bar, i} ->
              DateTime.diff(bar.t, from) == i * 900
            end)

        high =
          if complete,
            do: observed |> Enum.map(&Decimal.to_float(&1.high)) |> Enum.max(),
            else: nil

        low =
          if complete,
            do: observed |> Enum.map(&Decimal.to_float(&1.low)) |> Enum.min(),
            else: nil

        {id, %{"observed_count" => count, "observed_high" => high, "observed_low" => low}}
      end)

    Enum.map(items, fn item ->
      %{
        item
        | result:
            Map.merge(
              item.result,
              Map.get(summaries, item.setup_id, %{
                "observed_count" => 0,
                "observed_high" => nil,
                "observed_low" => nil
              })
            )
      }
    end)
  end
end
