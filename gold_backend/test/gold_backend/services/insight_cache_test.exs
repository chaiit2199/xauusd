defmodule GoldBackend.Services.InsightCacheTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.InsightCache

  test "a note stays usable for five minutes when the side is unchanged" do
    now = ~U[2026-10-21 13:00:00Z]
    cached_at = DateTime.add(now, -4 * 60, :second)

    assert InsightCache.fresh?(cached_at, "wait", "wait", now)
  end

  test "a note is cleared at five minutes" do
    now = ~U[2026-10-21 13:05:00Z]
    cached_at = DateTime.add(now, -5 * 60, :second)

    refute InsightCache.fresh?(cached_at, "wait", "wait", now)
  end

  test "a changed ticket side cannot reuse the stored note" do
    now = ~U[2026-10-21 13:02:00Z]
    cached_at = DateTime.add(now, -60, :second)

    refute InsightCache.fresh?(cached_at, "wait", "sell", now)
  end

  test "interval is five minutes" do
    assert InsightCache.interval_seconds() == 300
  end
end
