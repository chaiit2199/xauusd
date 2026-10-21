defmodule GoldBackend.Services.EconomicCalendar do
  @moduledoc """
  High-impact USD events for the next day.

  A release inside the 30 minutes before or after the print blocks a new
  XAUUSD CFD idea. A failed download does not invent events.
  """

  @url "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
  @titles ~r/cpi|nfp|non-farm|nonfarm|fomc|fed |powell|payroll|ppi|gdp|retail sales|jobless|interest rate|unemployment/i

  def upcoming_usd(now \\ DateTime.utc_now(), within_hours \\ 24) do
    case fetch() do
      {:ok, events} ->
        horizon = DateTime.add(now, within_hours * 3600, :second)
        earliest = DateTime.add(now, -1_800, :second)

        events
        |> Enum.filter(&usd_high_impact?(&1, earliest, horizon))
        |> Enum.sort_by(& &1.time, DateTime)
        |> Enum.take(6)

      :error ->
        []
    end
  end

  def blocking(events, now \\ DateTime.utc_now()) do
    Enum.find(events, fn event ->
      delta = DateTime.diff(event.time, now, :second)
      delta >= -1_800 and delta <= 1_800
    end)
  end

  defp fetch do
    options = [timeout: 4_000, recv_timeout: 4_000, follow_redirect: true]

    case HTTPoison.get(
           @url,
           [{"User-Agent", "gold-backend"}, {"Accept", "application/json"}],
           options
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        decode(body)

      _ ->
        :error
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, rows} when is_list(rows) ->
        {:ok, Enum.flat_map(rows, &normalize/1)}

      _ ->
        :error
    end
  end

  defp normalize(%{"title" => title, "country" => country, "date" => date, "impact" => impact}) do
    case DateTime.from_iso8601(date) do
      {:ok, time, _offset} ->
        [
          %{
            title: title,
            country: country,
            impact: impact,
            time: DateTime.truncate(time, :second)
          }
        ]

      _ ->
        []
    end
  end

  defp normalize(_), do: []

  defp usd_high_impact?(event, earliest, horizon) do
    event.country in ["USD", "All"] and
      event.impact == "High" and
      Regex.match?(@titles, event.title) and
      DateTime.compare(event.time, earliest) != :lt and
      DateTime.compare(event.time, horizon) != :gt
  end
end
