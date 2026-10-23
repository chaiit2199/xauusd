defmodule GoldBackend.Services.CalendarCacheTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Services.EconomicCalendar
  @now ~U[2026-10-23 08:00:00Z]

  setup do
    cache = start_supervised!({Agent, fn -> nil end})
    %{cache: cache}
  end

  test "cache avoids per-evaluation HTTP, survives a brief failure, and expires without extending its clock",
       %{cache: cache} do
    event = %{title: "USD event", country: "USD", impact: "High", time: DateTime.add(@now, 600)}
    first = EconomicCalendar.snapshot(@now, 24, cache: cache, fetch: fn -> {:ok, [event]} end)
    assert first.source == "live"

    second =
      EconomicCalendar.snapshot(DateTime.add(@now, 60), 24,
        cache: cache,
        fetch: fn -> flunk("reuse cache") end
      )

    assert second.source == "cache"
    assert second.valid_until == first.valid_until

    fallback =
      EconomicCalendar.snapshot(DateTime.add(@now, 301), 24,
        cache: cache,
        fetch: fn -> :error end
      )

    assert fallback.status == "ok"
    assert fallback.events == [event]
    assert fallback.valid_until == first.valid_until

    assert EconomicCalendar.snapshot(DateTime.add(@now, 900), 24,
             cache: cache,
             fetch: fn -> :error end
           ).status == "unavailable"
  end

  test "cache must cover the requested time range and the correct week", %{cache: cache} do
    friday = ~U[2026-10-23 23:00:00Z]

    assert EconomicCalendar.snapshot(friday, 24, cache: cache, fetch: fn -> {:ok, []} end).status ==
             "ok"

    # Reusing the same download for a wider horizon is not a verified calendar.
    assert EconomicCalendar.snapshot(DateTime.add(friday, 60), 72,
             cache: cache,
             fetch: fn -> :error end
           ).status == "unavailable"

    assert EconomicCalendar.snapshot(~U[2026-10-25 01:00:00Z], 24,
             cache: cache,
             fetch: fn -> :error end
           ).status == "unavailable"
  end
end
