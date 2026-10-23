defmodule GoldBackend.Services.CalendarCache do
  @moduledoc "Supervised, bounded calendar cache. Restart requires a fresh verification."
  use Agent

  def start_link(opts),
    do: Agent.start_link(fn -> nil end, name: Keyword.get(opts, :name, __MODULE__))
end
