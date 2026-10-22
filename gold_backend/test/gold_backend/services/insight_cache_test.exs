defmodule GoldBackend.Services.InsightCacheTest do
  use ExUnit.Case, async: false

  alias GoldBackend.Services.{CandleClock, InsightCache}

  test "a note stays usable inside its quarter hour when the side is unchanged" do
    now = ~U[2026-10-21 13:14:59Z]
    cached_at = ~U[2026-10-21 13:01:00Z]

    assert InsightCache.fresh?(cached_at, "wait", "wait", now)
  end

  test "a note expires on the boundary even if computation just finished" do
    now = ~U[2026-10-21 13:15:00Z]
    cached_at = DateTime.add(now, -1, :second)

    refute InsightCache.fresh?(cached_at, "wait", "wait", now)
  end

  test "a changed ticket side cannot reuse the stored note" do
    now = ~U[2026-10-21 13:02:00Z]
    cached_at = DateTime.add(now, -60, :second)

    refute InsightCache.fresh?(cached_at, "wait", "sell", now)
  end

  test "interval is fifteen minutes aligned to UTC including day rollover" do
    assert InsightCache.interval_seconds() == 900
    assert CandleClock.next_close(~U[2026-10-21 13:07:00Z]) == ~U[2026-10-21 13:15:00Z]
    assert CandleClock.next_close(~U[2026-10-21 23:59:59Z]) == ~U[2026-10-22 00:00:00Z]
    assert CandleClock.delay_ms(~U[2026-10-21 13:14:59.500Z]) == 500
    assert CandleClock.delay_ms(~U[2026-10-21 13:15:00Z]) == 900_000
  end

  test "future notes cannot be reused" do
    refute InsightCache.fresh?(~U[2026-10-21 13:04:00Z], "sell", "sell", ~U[2026-10-21 13:03:00Z])
  end

  test "expired or malformed snapshots clear the action and explanation" do
    snapshot = %{
      ai_next_analysis_at: "2026-10-21T13:15:00Z",
      cfd_plan: %{action: "sell"},
      ai_insight: "old",
      ai_action: "sell",
      ai_error: nil
    }

    assert InsightCache.expire_snapshot(snapshot, ~U[2026-10-21 13:14:59Z]) == snapshot

    for expiry <- [snapshot.ai_next_analysis_at, "bad timestamp", nil] do
      expired =
        InsightCache.expire_snapshot(
          %{snapshot | ai_next_analysis_at: expiry},
          ~U[2026-10-21 13:15:00Z]
        )

      assert expired.cfd_plan.action == "wait"
      assert expired.ai_action == nil
      assert expired.ai_insight == nil
      assert is_binary(expired.ai_error)
    end
  end

  test "a worker finishing after its slot is discarded without publishing" do
    ref = make_ref()
    slot = DateTime.utc_now() |> CandleClock.closed_at() |> DateTime.add(-900)
    state = %{job: %{ref: ref}, job_slot: slot}
    assert {:noreply, %{job: nil}} = InsightCache.handle_info({ref, {:ok, %{}}}, state)
  end

  test "refresh skips overlapping jobs and duplicate triggers within one slot" do
    for job <- [%{ref: make_ref()}, nil] do
      timer = Process.send_after(self(), :refresh, 900_000)

      state = %{
        job: job,
        job_slot: nil,
        last_slot: CandleClock.closed_at(DateTime.utc_now()),
        timer: timer
      }

      {:noreply, updated} = InsightCache.handle_info(:refresh, state)
      assert updated.job == job
      assert updated.last_slot == state.last_slot
      Process.cancel_timer(updated.timer)
    end
  end

  test "peek reads the snapshot without waiting for the GenServer mailbox" do
    pid = start_supervised!(InsightCache)
    :sys.suspend(pid)

    try do
      result = Task.async(&InsightCache.peek/0) |> Task.await(100)

      assert result == %{
               ai_insight: nil,
               ai_error: nil,
               ai_cached_at: nil,
               ai_ttl_seconds: 900
             }
    after
      :sys.resume(pid)
    end
  end
end
