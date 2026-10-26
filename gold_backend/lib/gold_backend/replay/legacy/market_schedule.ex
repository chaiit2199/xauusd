defmodule GoldBackend.Replay.Legacy.MarketSchedule do
  @moduledoc "Only explicitly configured UTC closures excuse missing candles. No inferred holidays or synthetic bars."

  def open?(at), do: not Enum.any?(closures(), &contains?(&1, at))

  def consecutive?(bars, seconds) do
    Enum.all?(Enum.chunk_every(bars, 2, 1, :discard), fn [a, b] ->
      gap = DateTime.diff(b.open_time, a.open_time)

      gap >= seconds and rem(gap, seconds) == 0 and
        (gap == seconds or
           Enum.all?(1..(div(gap, seconds) - 1), fn index ->
             closed_interval?(DateTime.add(a.open_time, index * seconds), seconds)
           end))
    end)
  end

  def closed_interval?(at, seconds) do
    # Require the entire missing bar to fall inside one declared closure.
    Enum.any?(closures(), fn %{from: first, until: last} ->
      DateTime.compare(at, first) != :lt and
        DateTime.compare(DateTime.add(at, seconds), last) != :gt
    end)
  end

  defp contains?(%{from: first, until: last}, at),
    do: DateTime.compare(at, first) != :lt and DateTime.compare(at, last) == :lt

  defp closures do
    Application.get_env(:gold_backend, :market_closures, [])
    |> Enum.flat_map(fn
      %{from: %DateTime{} = first, until: %DateTime{} = last} = interval ->
        if DateTime.compare(first, last) == :lt, do: [interval], else: []

      _ ->
        []
    end)
  end
end
