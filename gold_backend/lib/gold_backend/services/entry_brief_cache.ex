defmodule GoldBackend.Services.EntryBriefCache do
  @moduledoc "Bounded in-memory cache of validated AI briefs. No market decisions or deliveries are cached."
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  def init(state), do: {:ok, state}
  def get(key, now), do: GenServer.call(__MODULE__, {:get, key, now})

  def put(key, brief, expires, now),
    do: GenServer.call(__MODULE__, {:put, key, brief, expires, now})

  def clear, do: GenServer.call(__MODULE__, :clear)
  def handle_call(:clear, _, _), do: {:reply, :ok, %{}}

  def handle_call({:get, key, now}, _, state) do
    state = prune(state, now)

    result =
      case Map.get(state, key) do
        {brief, _} -> {:ok, brief}
        nil -> :miss
      end

    {:reply, result, state}
  end

  def handle_call({:put, key, brief, expires, now}, _, state) do
    state = prune(state, now)

    state =
      if DateTime.compare(expires, now) == :gt,
        do: Map.put(state, key, {brief, expires}),
        else: state

    state =
      state
      |> Enum.sort_by(fn {_, {_, expiry}} -> DateTime.to_unix(expiry) end, :desc)
      |> Enum.take(256)
      |> Map.new()

    {:reply, :ok, state}
  end

  defp prune(state, now),
    do: Map.reject(state, fn {_, {_, expiry}} -> DateTime.compare(expiry, now) != :gt end)
end
