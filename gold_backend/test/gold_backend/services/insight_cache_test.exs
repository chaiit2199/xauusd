defmodule GoldBackend.Services.InsightCacheTest do
  use ExUnit.Case, async: false

  alias GoldBackend.Services.{CandleClock, InsightCache}

  test "expired calendar pauses a signal and its checks without blocking advisories" do
    data = %{
      calendar_valid_until: "2026-10-23T08:01:00Z",
      cfd_plan: %{
        action: "buy",
        checks: [
          %{code: "calendar_data", status: "pass", required: true},
          %{code: "calendar_window", status: "pass", required: true},
          %{code: "reward_risk", status: "pass", required: true},
          %{code: "bias", status: "warning", required: false}
        ]
      }
    }

    paused = InsightCache.expire_snapshot(data, ~U[2026-10-23 08:01:00Z])
    assert paused.cfd_plan.action == "wait"
    checks = Map.new(paused.cfd_plan.checks, &{&1.code, &1.status})
    assert checks["calendar_data"] == "blocked"
    assert checks["calendar_window"] == "unknown"
    assert checks["reward_risk"] == "unknown"
    assert checks["bias"] == "warning"
  end

  test "setup expiry overrides otherwise fresh metadata" do
    data = %{
      ai_next_analysis_at: "2026-10-23T08:45:00Z",
      cfd_plan: %{action: "buy", setup_expires_at: "2026-10-23T08:30:00Z"}
    }

    result = InsightCache.expire_snapshot(data, ~U[2026-10-23 08:30:00Z])
    assert result.cfd_plan.action == "wait"
    assert result.cfd_plan.setup_status == "expired"
  end

  test "a stale reference quote expires before the M15 analysis boundary" do
    snapshot = %{
      ai_next_analysis_at: "2026-10-23T08:15:00Z",
      signal_valid_until: "2026-10-23T08:02:01Z",
      cfd_plan: %{action: "buy"}
    }

    assert InsightCache.expire_snapshot(snapshot, ~U[2026-10-23 08:02:00Z]) == snapshot
    expired = InsightCache.expire_snapshot(snapshot, ~U[2026-10-23 08:02:01Z])
    assert expired.cfd_plan.action == "wait"
    assert expired.cfd_plan.setup_status == "paused"
    assert expired.ai_error =~ "Báo giá"
  end

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

  test "checks run every minute while candle clock remains M15" do
    assert InsightCache.interval_seconds() == 60
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
        last_slot: CandleClock.closed_at(DateTime.utc_now(), 60),
        timer: timer
      }

      {:noreply, updated} = InsightCache.handle_info(:refresh, state)
      assert updated.job == job
      assert updated.last_slot == state.last_slot
      Process.cancel_timer(updated.timer)
    end
  end

  test "async commentary preserves a published ticket, survives refresh, and ignores old candles" do
    pid = start_supervised!({InsightCache, bootstrap: false})
    now = DateTime.utc_now()
    candle = CandleClock.closed_at(now) |> DateTime.to_iso8601()

    snapshot = %{
      analysis_candle_closed_at: candle,
      ai_next_analysis_at: DateTime.to_iso8601(CandleClock.next_close(now)),
      cfd_plan: %{action: "buy", entry: 100.0, stop_loss: 95.0, take_profit: 110.0},
      ai_status: "pending",
      ai_action: nil,
      ai_insight: nil,
      ai_error: nil
    }

    publish = fn data ->
      ref = make_ref()

      :sys.replace_state(pid, fn state ->
        %{state | job: %{ref: ref}, job_slot: CandleClock.closed_at(now)}
      end)

      send(pid, {ref, {:ok, data}})
      :sys.get_state(pid)
    end

    publish.(snapshot)
    assert InsightCache.snapshot().cfd_plan.action == "buy"
    GenServer.cast(pid, {:commentary, candle, "buy", {:error, "timeout"}})
    :sys.get_state(pid)
    assert InsightCache.snapshot().cfd_plan == snapshot.cfd_plan
    assert InsightCache.snapshot().ai_error == "timeout"
    publish.(snapshot)
    assert InsightCache.snapshot().ai_error == "timeout"
    old = DateTime.add(CandleClock.closed_at(now), -900) |> DateTime.to_iso8601()
    GenServer.cast(pid, {:commentary, old, "buy", {:error, "old failure"}})
    :sys.get_state(pid)
    assert InsightCache.snapshot().ai_error == "timeout"
  end

  test "startup restores stored data and refreshes immediately even when the provider fails" do
    parent = self()
    now = DateTime.utc_now()

    saved = %{
      analysis_candle_closed_at: DateTime.to_iso8601(CandleClock.closed_at(now)),
      ai_next_analysis_at: DateTime.to_iso8601(CandleClock.next_close(now)),
      cfd_plan: %{action: "wait"},
      snapshot_origin: "database",
      current_price: "4100.0"
    }

    restore = fn ->
      send(parent, :restored)
      {:ok, saved}
    end

    compute = fn _ ->
      send(parent, :refreshed_immediately)
      {:error, :provider_offline}
    end

    pid = start_supervised!({InsightCache, restore: restore, compute: compute})
    assert_receive :restored
    assert_receive :refreshed_immediately, 1000
    :sys.get_state(pid)
    assert InsightCache.snapshot().current_price == "4100.0"
    assert InsightCache.snapshot().snapshot_origin == "database"
    assert InsightCache.snapshot().cfd_plan.action == "wait"
  end

  test "failed restore still triggers immediate refresh" do
    parent = self()

    start_supervised!(
      {InsightCache,
       restore: fn -> {:error, :no_rows} end,
       compute: fn _ ->
         send(parent, :refresh_without_rows)
         {:error, :provider_offline}
       end}
    )

    assert_receive :refresh_without_rows, 1000
  end

  test "peek reads the snapshot without waiting for the GenServer mailbox" do
    pid = start_supervised!({InsightCache, bootstrap: false})
    :sys.suspend(pid)

    try do
      result = Task.async(&InsightCache.peek/0) |> Task.await(100)

      assert result == %{
               ai_insight: nil,
               ai_error: nil,
               ai_cached_at: nil,
               ai_ttl_seconds: 60
             }
    after
      :sys.resume(pid)
    end
  end
end
