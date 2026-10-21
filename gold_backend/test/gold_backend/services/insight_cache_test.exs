defmodule GoldBackend.Services.InsightCacheTest do
  use ExUnit.Case, async: true

  alias GoldBackend.Services.InsightCache

  test "a note stays usable for fifteen minutes when the side is unchanged" do
    now = ~U[2026-10-21 13:00:00Z]
    cached_at = DateTime.add(now, -14 * 60, :second)

    assert InsightCache.fresh?(cached_at, "wait", "wait", now)
  end

  test "a note is cleared at fifteen minutes" do
    now = ~U[2026-10-21 13:15:00Z]
    cached_at = DateTime.add(now, -15 * 60, :second)

    refute InsightCache.fresh?(cached_at, "wait", "wait", now)
  end

  test "a changed ticket side cannot reuse the stored note" do
    now = ~U[2026-10-21 13:05:00Z]
    cached_at = DateTime.add(now, -60, :second)

    refute InsightCache.fresh?(cached_at, "wait", "sell", now)
  end
end
