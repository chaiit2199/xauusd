defmodule GoldBackend.Replay.Legacy.CandleClock do
  @moduledoc "UTC-aligned M15 analysis slots; independent of process start time."
  @seconds 900
  def interval_seconds, do: @seconds

  def closed_at(now, seconds \\ @seconds) do
    now |> DateTime.to_unix() |> then(&(div(&1, seconds) * seconds)) |> DateTime.from_unix!()
  end

  def next_close(now), do: DateTime.add(closed_at(now), @seconds, :second)
  def delay_ms(now), do: DateTime.diff(next_close(now), now, :millisecond)

  def current?(%DateTime{} = slot, now), do: DateTime.compare(slot, closed_at(now)) == :eq
  def current?(_, _), do: false
end
