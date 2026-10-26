defmodule GoldBackend.Replay.Split do
  @moduledoc "Chronological 70/30 trading-date split; OOS sees earlier candles only for warmup."

  def run(dataset) do
    days =
      dataset.candles
      |> Enum.filter(&(&1.timeframe == 900))
      |> Enum.map(&DateTime.to_date(&1.open_time))
      |> Enum.uniq()
      |> Enum.sort(Date)

    if length(days) < 2 do
      %{status: "insufficient_sample", trading_days: length(days)}
    else
      index = max(1, min(length(days) - 1, trunc(length(days) * 0.7)))
      boundary = days |> Enum.at(index) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

      in_sample = %{
        dataset
        | candles:
            Enum.filter(
              dataset.candles,
              &(DateTime.compare(DateTime.add(&1.open_time, &1.timeframe), boundary) != :gt)
            ),
          quotes: Enum.filter(dataset.quotes, &(DateTime.compare(&1.timestamp, boundary) == :lt))
      }

      reports =
        for mode <- [:old, :new], into: %{} do
          {mode,
           %{
             development: GoldBackend.Replay.Runner.run(in_sample, mode),
             out_of_sample:
               GoldBackend.Replay.Runner.run(dataset, mode, evaluation_from: boundary)
           }}
        end

      %{
        status: if(length(days) < 90, do: "insufficient_sample", else: "descriptive_only"),
        boundary: boundary,
        development_days: index,
        out_of_sample_days: length(days) - index,
        methodology:
          "Cutoff is UTC trading dates present in dataset; OOS uses prior candles only as warmup. Development outcomes after cutoff are unavailable. Parameters must be fixed before OOS.",
        reports: reports
      }
    end
  end
end
