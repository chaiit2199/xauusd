defmodule GoldBackend.Replay.Legacy.BreakoutZone do
  @moduledoc "A 20-bar M15 range known before breakout becomes a retest zone after its breakout close."
  def build(bars, atr) when length(bars) >= 22 and atr > 0 do
    breakout = Enum.at(bars, -2)
    reference = bars |> Enum.drop(-2) |> Enum.take(-20)
    high = Enum.max_by(reference, & &1.high).high
    low = Enum.min_by(reference, & &1.low).low
    buffer = max(0.1 * atr, 0.01)

    Enum.flat_map([{"buy", high}, {"sell", low}], fn {side, level} ->
      crossed =
        if side == "buy",
          do: breakout.open <= level and breakout.close > level + buffer,
          else: breakout.open >= level and breakout.close < level - buffer

      if crossed do
        [
          %{
            id: "breakout_#{side}_#{DateTime.to_unix(breakout.open_time)}",
            low: level - buffer,
            mid: level,
            high: level + buffer,
            entry_only: true,
            side: side,
            known_at: DateTime.to_iso8601(breakout.open_time),
            formed_at: DateTime.to_iso8601(DateTime.add(breakout.open_time, 900))
          }
        ]
      else
        []
      end
    end)
  end

  def build(_, _), do: []
end
