defmodule GoldBackend.Services.InsightCache do
  @moduledoc """
  Keeps one H1 commentary for 15 minutes.

  A timer clears that note and writes a new one from the latest rows in the
  database. A request inside the window returns the stored note when the
  ticket still has the same side. The page load never starts a new note.
  """

  use GenServer

  alias GoldBackendWeb.TradingController

  require Logger

  @ttl_seconds 15 * 60
  @interval_ms 15 * 60 * 1000
  @call_timeout 150_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def peek do
    case Process.whereis(__MODULE__) do
      nil -> blank()
      pid -> GenServer.call(pid, :peek, 5_000)
    end
  end

  def resolve(context) do
    case Process.whereis(__MODULE__) do
      nil -> view(compute(context))
      pid -> GenServer.call(pid, {:resolve, context}, @call_timeout)
    end
  end

  def fresh?(cached_at, action, current_action, now \\ DateTime.utc_now())

  def fresh?(%DateTime{} = cached_at, action, current_action, now) do
    action == current_action and DateTime.diff(now, cached_at, :second) < @ttl_seconds
  end

  def fresh?(_cached_at, _action, _current_action, _now), do: false

  @impl true
  def init(_state) do
    schedule()
    {:ok, empty_state()}
  end

  @impl true
  def handle_info(:refresh, _state) do
    schedule()
    {:noreply, refresh_from_database()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:peek, _from, state) do
    {:reply, view(state), state}
  end

  def handle_call({:resolve, context}, _from, state) do
    state = if usable?(state, context.plan.action), do: state, else: compute(context)
    {:reply, view(state), state}
  end

  defp refresh_from_database do
    case TradingController.build_context(translate_timeout: 8_000) do
      {:ok, context} ->
        compute(context)

      {:error, reason} ->
        Logger.warning("Insight refresh skipped: #{reason}")
        empty_state()
    end
  end

  defp compute(context) do
    {text, error} = TradingController.write_commentary(context)

    %{
      insight: text,
      error: error,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      action: context.plan.action
    }
  end

  defp usable?(state, action) do
    fresh?(state.generated_at, state.action, action)
  end

  defp view(state) do
    if fresh?(state.generated_at, state.action, state.action) do
      %{
        ai_insight: state.insight,
        ai_error: state.error,
        ai_cached_at: DateTime.to_iso8601(state.generated_at)
      }
    else
      blank()
    end
  end

  defp blank, do: %{ai_insight: nil, ai_error: nil, ai_cached_at: nil}

  defp empty_state, do: %{insight: nil, error: nil, generated_at: nil, action: nil}

  defp schedule do
    Process.send_after(self(), :refresh, @interval_ms)
  end
end
