defmodule GoldBackend.Services.InsightCache do
  @moduledoc """
  Keeps one H1 commentary for five minutes.

  A timer refreshes news lightly, rebuilds the ticket from the latest rows,
  then asks the local model to explain price + indicators + headlines.
  A request inside the window returns the stored note when the ticket still
  has the same side. The page load never starts a new note.
  """

  use GenServer

  alias GoldBackend.Services.NewsCrawler
  alias GoldBackendWeb.TradingController

  require Logger

  @ttl_seconds 5 * 60
  @interval_ms 5 * 60 * 1000
  @boot_delay_ms 8_000
  @job_timeout_ms 165_000
  @call_timeout 170_000
  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def interval_seconds, do: @ttl_seconds

  def peek do
    case :ets.whereis(@table) do
      :undefined ->
        blank()

      _table ->
        case :ets.lookup(@table, :cache) do
          [{:cache, state}] -> view(state)
          _ -> blank()
        end
    end
  rescue
    ArgumentError -> blank()
  end

  def resolve(context) do
    case Process.whereis(__MODULE__) do
      nil ->
        blank()

      pid ->
        try do
          GenServer.call(pid, {:resolve, context}, @call_timeout)
        catch
          :exit, reason ->
            Logger.warning("Insight resolve unavailable: #{inspect(reason)}")
            peek()
        end
    end
  end

  def fresh?(cached_at, action, current_action, now \\ DateTime.utc_now())

  def fresh?(%DateTime{} = cached_at, action, current_action, now) do
    action == current_action and DateTime.diff(now, cached_at, :second) < @ttl_seconds
  end

  def fresh?(_cached_at, _action, _current_action, _now), do: false

  @impl true
  def init(_state) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    state = empty_state()
    publish(state)
    Process.send_after(self(), :refresh, @boot_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule()

    if state.job_ref do
      Logger.info("Insight refresh skipped: previous background job is still running")
      {:noreply, state}
    else
      {:noreply, start_job(state, &refresh_from_database/0)}
    end
  end

  def handle_info({ref, {:ok, cache}}, %{job_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_job(state, cache)}
  end

  def handle_info({ref, {:error, reason}}, %{job_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    Logger.warning("Insight background job skipped: #{inspect(reason)}")
    {:noreply, finish_job(state, nil)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{job_ref: ref} = state) do
    Logger.warning("Insight background job stopped: #{inspect(reason)}")
    {:noreply, finish_job(state, nil)}
  end

  def handle_info({:job_timeout, ref}, %{job_ref: ref, job_pid: pid} = state) do
    Process.exit(pid, :kill)
    Logger.warning("Insight background job exceeded #{@job_timeout_ms}ms and was stopped")
    {:noreply, finish_job(state, nil)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:resolve, context}, from, state) do
    cond do
      usable?(state, context.plan.action) ->
        {:reply, view(state), state}

      state.job_ref ->
        {:noreply, %{state | waiters: [from | state.waiters]}}

      true ->
        job = fn -> {:ok, compute(context)} end
        {:noreply, start_job(state, job, from)}
    end
  end

  defp refresh_from_database do
    refresh_news()

    case TradingController.build_context(translate_timeout: 8_000) do
      {:ok, context} ->
        {:ok, compute(context)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_news do
    sources = NewsCrawler.fetch_and_save_all()
    saved = Enum.reduce(sources, 0, fn source, acc -> acc + source.saved end)
    Logger.info("Insight cycle crawled news, saved #{saved} articles")
  rescue
    error ->
      Logger.warning("Insight news crawl skipped: #{Exception.message(error)}")
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

  defp start_job(state, fun, waiter \\ nil) do
    task = Task.Supervisor.async_nolink(GoldBackend.TaskSupervisor, fun)
    Process.send_after(self(), {:job_timeout, task.ref}, @job_timeout_ms)

    waiters = if waiter, do: [waiter | state.waiters], else: state.waiters
    %{state | job_ref: task.ref, job_pid: task.pid, waiters: waiters}
  end

  defp finish_job(state, cache) do
    next_state =
      state
      |> maybe_store(cache)
      |> Map.merge(%{job_ref: nil, job_pid: nil, waiters: []})

    response = view(next_state)
    Enum.each(state.waiters, &GenServer.reply(&1, response))
    publish(next_state)
    next_state
  end

  defp maybe_store(state, nil), do: state

  defp maybe_store(state, cache) do
    Map.merge(state, Map.take(cache, [:insight, :error, :generated_at, :action]))
  end

  defp publish(state) do
    :ets.insert(@table, {:cache, Map.take(state, [:insight, :error, :generated_at, :action])})
  end

  defp view(state) do
    if fresh?(state.generated_at, state.action, state.action) do
      %{
        ai_insight: state.insight,
        ai_error: state.error,
        ai_cached_at: DateTime.to_iso8601(state.generated_at),
        ai_ttl_seconds: @ttl_seconds
      }
    else
      blank()
    end
  end

  defp blank,
    do: %{ai_insight: nil, ai_error: nil, ai_cached_at: nil, ai_ttl_seconds: @ttl_seconds}

  defp empty_state do
    %{
      insight: nil,
      error: nil,
      generated_at: nil,
      action: nil,
      job_ref: nil,
      job_pid: nil,
      waiters: []
    }
  end

  defp schedule do
    Process.send_after(self(), :refresh, @interval_ms)
  end
end
