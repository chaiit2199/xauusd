defmodule GoldBackend.Replay.Dataset do
  @moduledoc "Validated OHLC and quote file reader. Timestamps are UTC ISO8601; never fabricates candles."

  def load(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, rows} <- decode(raw, Path.extname(path)),
         {:ok, data} <- normalize(rows) do
      {:ok, data}
    end
  end

  defp decode(raw, ".json") do
    case Jason.decode(raw) do
      {:ok, %{"candles" => candles} = data} when is_list(candles) -> {:ok, data}
      {:ok, candles} when is_list(candles) -> {:ok, %{"candles" => candles}}
      _ -> {:error, "JSON must contain a candles array"}
    end
  end

  defp decode(raw, ".csv") do
    case String.split(raw, ~r/\r?\n/, trim: true) do
      [] ->
        {:error, "empty CSV"}

      [header | lines] ->
        keys = String.split(header, ",") |> Enum.map(&String.trim/1)

        if Enum.sort(keys) != Enum.sort(~w(open_time timeframe open high low close)) do
          {:error, "CSV header must be open_time,timeframe,open,high,low,close"}
        else
          fields = Enum.map(lines, &String.split(&1, ","))

          if Enum.all?(fields, &(length(&1) == length(keys))) do
            {:ok, %{"candles" => Enum.map(fields, &(Enum.zip(keys, &1) |> Map.new()))}}
          else
            {:error, "CSV row has incorrect column count"}
          end
        end
    end
  end

  defp decode(_, _), do: {:error, "use .csv or .json"}

  defp normalize(data) do
    with {:ok, candles} <- map_all(data["candles"], &candle/1),
         {:ok, quotes} <- map_all(Map.get(data, "quotes", []), &parse_quote/1),
         {:ok, calendar} <- calendar(Map.get(data, "calendar")),
         true <- length(Enum.uniq_by(candles, &{&1.timeframe, &1.open_time})) == length(candles),
         :ok <- ordered(candles, quotes) do
      {:ok,
       %{
         candles: Enum.sort_by(candles, & &1.open_time, DateTime),
         quotes: Enum.sort_by(quotes, & &1.timestamp, DateTime),
         calendar: calendar,
         validation: quality(candles, quotes, calendar)
       }}
    else
      false -> {:error, "duplicate candle timeframe/open_time"}
      {:error, _} = error -> error
    end
  end

  defp ordered(candles, quotes) do
    ordered_candles =
      candles
      |> Enum.group_by(& &1.timeframe)
      |> Enum.all?(fn {_, rows} -> strictly_ordered?(Enum.map(rows, & &1.open_time)) end)

    ordered_quotes =
      quotes
      |> Enum.map(& &1.timestamp)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> DateTime.compare(a, b) != :gt end)

    if ordered_candles and ordered_quotes,
      do: :ok,
      else: {:error, "timestamps must increase within each timeframe and quotes must be ordered"}
  end

  defp strictly_ordered?(times),
    do:
      times
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> DateTime.compare(a, b) == :lt end)

  defp quality(candles, quotes, calendar) do
    timeframes =
      Map.new([300, 900, 3600], fn seconds ->
        bars = Enum.filter(candles, &(&1.timeframe == seconds))

        gaps =
          bars
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.filter(fn [a, b] -> DateTime.diff(b.open_time, a.open_time) > seconds end)
          |> Enum.map(fn [a, b] ->
            %{
              after: a.open_time,
              before: b.open_time,
              missing_intervals: div(DateTime.diff(b.open_time, a.open_time), seconds) - 1
            }
          end)

        {seconds, %{candles: length(bars), gaps: gaps}}
      end)

    %{
      timeframes: timeframes,
      warmup_available: timeframes[900].candles >= 30 and timeframes[3600].candles >= 50,
      quote_count: length(quotes),
      calendar_coverage:
        if(calendar,
          do: %{from: calendar.from, until: calendar.until, event_count: length(calendar.events)},
          else: nil
        ),
      gap_note:
        "Gaps include market closures; no candles are synthesized. Review session calendar and gaps before interpreting outcomes.",
      coverage: coverage(candles, quotes, calendar),
      point_in_time: "not_fully_point_in_time"
    }
  end

  defp coverage(candles, quotes, calendar) do
    evaluations =
      candles |> Enum.filter(&(&1.timeframe == 900)) |> Enum.map(&DateTime.add(&1.open_time, 900))

    quote_covered =
      Enum.count(evaluations, fn at ->
        Enum.any?(quotes, fn q ->
          age = DateTime.diff(at, q.timestamp)
          age >= 0 and age < 120
        end)
      end)

    news_covered =
      Enum.count(evaluations, fn at ->
        calendar != nil and DateTime.compare(calendar.from, DateTime.add(at, -1800)) != :gt and
          DateTime.compare(calendar.until, DateTime.add(at, 900)) != :lt
      end)

    %{
      m15_evaluations: length(evaluations),
      fresh_quote_evaluations: quote_covered,
      calendar_covered_evaluations: news_covered,
      note:
        "Coverage is on M15 closes, including warmup; completeness of historical event knowledge cannot be proven from declared range."
    }
  end

  defp map_all(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp map_all(_, _), do: {:error, "rows must be an array"}

  defp candle(row) when is_map(row) do
    with {:ok, at} <- timestamp(row["open_time"]),
         {:ok, seconds} <- timeframe(row["timeframe"]),
         {:ok, open} <- number(row["open"]),
         {:ok, high} <- number(row["high"]),
         {:ok, low} <- number(row["low"]),
         {:ok, close} <- number(row["close"]),
         true <- rem(DateTime.to_unix(at), seconds) == 0 and elem(at.microsecond, 0) == 0,
         true <- low > 0 and low <= min(open, close) and high >= max(open, close),
         true <-
           Map.get(row, "confirmed", true) == true and Map.get(row, "approx", false) == false and
             Map.get(row, "is_approximate", false) == false do
      {:ok,
       %{
         open_time: at,
         timeframe: seconds,
         open: open,
         high: high,
         low: low,
         close: close,
         confirmed: true,
         source: "imported_ohlc"
       }}
    else
      _ -> {:error, "invalid candle: #{inspect(row)}"}
    end
  end

  defp candle(_), do: {:error, "invalid candle"}

  defp calendar(nil), do: {:ok, nil}

  defp calendar(%{"from" => first, "until" => last, "events" => events}) do
    with {:ok, from} <- timestamp(first),
         {:ok, until} <- timestamp(last),
         true <- DateTime.compare(from, until) == :lt,
         {:ok, parsed} <- map_all(events, &event/1) do
      {:ok, %{from: from, until: until, events: parsed}}
    else
      _ -> {:error, "invalid calendar coverage or events"}
    end
  end

  defp calendar(_), do: {:error, "invalid calendar coverage"}

  defp event(%{
         "time" => time,
         "known_at" => known,
         "title" => title,
         "impact" => impact,
         "country" => country
       })
       when is_binary(title) and is_binary(impact) and is_binary(country) do
    with {:ok, at} <- timestamp(time),
         {:ok, known_at} <- timestamp(known),
         true <- DateTime.compare(known_at, at) != :gt do
      {:ok, %{time: at, known_at: known_at, title: title, impact: impact, country: country}}
    else
      _ -> {:error, "invalid event"}
    end
  end

  defp event(_), do: {:error, "invalid event"}

  defp parse_quote(row) when is_map(row) do
    with {:ok, at} <- timestamp(row["timestamp"]),
         {:ok, price} <- number(row["price"]),
         true <- price > 0 do
      {:ok, %{timestamp: at, price: price}}
    else
      _ -> {:error, "invalid quote: #{inspect(row)}"}
    end
  end

  defp parse_quote(_), do: {:error, "invalid quote"}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, 0} -> {:ok, at}
      _ -> :error
    end
  end

  defp timestamp(_), do: :error
  defp timeframe(value) when value in [300, "300", "M5"], do: {:ok, 300}
  defp timeframe(value) when value in [900, "900", "M15"], do: {:ok, 900}
  defp timeframe(value) when value in [3600, "3600", "H1"], do: {:ok, 3600}
  defp timeframe(_), do: :error
  defp number(n) when is_number(n), do: {:ok, n * 1.0}

  defp number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp number(_), do: :error
end
