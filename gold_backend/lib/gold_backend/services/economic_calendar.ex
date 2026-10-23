defmodule GoldBackend.Services.EconomicCalendar do
  @moduledoc """
  High-impact USD events for the next day.

  A release inside the 15 minutes before or 30 minutes after the print blocks a new
  XAUUSD CFD idea. A failed download does not invent events.
  """

  @url "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
  def upcoming_usd(now \\ DateTime.utc_now(), within_hours \\ 24),
    do: snapshot(now, within_hours).events

  def snapshot(now, within_hours \\ 24, opts \\ []) do
    fetcher = Keyword.get(opts, :fetch, &fetch/0)

    cache =
      Keyword.get(
        opts,
        :cache,
        if(Keyword.has_key?(opts, :fetch), do: nil, else: GoldBackend.Services.CalendarCache)
      )

    saved = cached(cache)
    fresh = usable?(saved, now, within_hours) and DateTime.diff(now, saved.fetched_at) < 300

    entry =
      if fresh do
        saved
      else
        case fetcher.() do
          {:ok, events} ->
            first =
              DateTime.new!(
                Date.add(DateTime.to_date(now), -rem(Date.day_of_week(DateTime.to_date(now)), 7)),
                ~T[00:00:00],
                "Etc/UTC"
              )

            value = %{
              events: events,
              fetched_at: now,
              from: first,
              until: DateTime.add(first, 7 * 86400)
            }

            if Enum.all?(
                 events,
                 &(DateTime.compare(&1.time, first) != :lt and
                     DateTime.compare(&1.time, value.until) == :lt)
               ) and usable?(value, now, within_hours) do
              save(cache, value)
              value
            else
              if usable?(saved, now, within_hours), do: saved
            end

          _ ->
            if usable?(saved, now, within_hours), do: saved
        end
      end

    if entry do
      horizon = DateTime.add(now, within_hours * 3600)
      earliest = DateTime.add(now, -1800)

      validity =
        Enum.min_by(
          [DateTime.add(entry.fetched_at, 900), DateTime.add(entry.until, -within_hours * 3600)],
          &DateTime.to_unix/1
        )

      %{
        status: "ok",
        source: if(entry.fetched_at == now, do: "live", else: "cache"),
        fetched_at: DateTime.to_iso8601(entry.fetched_at),
        valid_until: DateTime.to_iso8601(validity),
        events:
          entry.events
          |> Enum.filter(&usd_high_impact?(&1, earliest, horizon))
          |> Enum.sort_by(& &1.time, DateTime)
      }
    else
      %{status: "unavailable", events: [], source: "unverified", valid_until: nil}
    end
  end

  defp usable?(nil, _, _), do: false

  defp usable?(entry, now, hours) do
    DateTime.diff(now, entry.fetched_at) in 0..899 and
      DateTime.compare(DateTime.add(now, -1800), entry.from) != :lt and
      DateTime.compare(DateTime.add(now, hours * 3600), entry.until) == :lt
  end

  defp cached(nil), do: nil

  defp cached(cache) do
    Agent.get(cache, & &1)
  catch
    :exit, _ -> nil
  end

  defp save(nil, _), do: :ok

  defp save(cache, entry) do
    Agent.update(cache, fn _ -> entry end)
  catch
    :exit, _ -> :ok
  end

  def blocking(events, now \\ DateTime.utc_now()) do
    Enum.find(events, fn event ->
      delta = DateTime.diff(event.time, now, :second)
      delta >= -1_800 and delta <= 900
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
        events = Enum.flat_map(rows, &normalize/1)
        if length(events) == length(rows), do: {:ok, events}, else: :error

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
      DateTime.compare(event.time, earliest) != :lt and
      DateTime.compare(event.time, horizon) != :gt
  end
end
