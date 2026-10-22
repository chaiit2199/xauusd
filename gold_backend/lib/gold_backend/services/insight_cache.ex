defmodule GoldBackend.Services.InsightCache do
  use GenServer
  require Logger
  alias GoldBackend.Services.{AiDecision, NewsCrawler, TelegramNotifier}
  alias GoldBackendWeb.TradingController
  @interval_ms 300_000
  @table __MODULE__
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def interval_seconds, do: 300

  def fresh?(%DateTime{} = at, action, current, now \\ DateTime.utc_now()),
    do: action == current and DateTime.diff(now, at, :second) < 300

  def snapshot do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@table, :snapshot) do
          [{:snapshot, data}] -> data
          _ -> nil
        end
    end
  rescue
    ArgumentError -> nil
  end

  def peek do
    case snapshot() do
      nil -> %{ai_insight: nil, ai_error: nil, ai_cached_at: nil, ai_ttl_seconds: 300}
      data -> Map.take(data, [:ai_insight, :ai_error, :ai_cached_at, :ai_ttl_seconds])
    end
  end

  def resolve(_), do: peek()
  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    Process.send_after(self(), :refresh, 8_000)
    {:ok, %{job: nil}}
  end

  @impl true
  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, @interval_ms)

    if state.job do
      {:noreply, state}
    else
      task = Task.Supervisor.async_nolink(GoldBackend.TaskSupervisor, &compute/0)

      timeout = AiDecision.max_duration_ms()

      # News crawling and headline translation run before the AI request budget.
      Process.send_after(self(), {:timeout, task.ref}, timeout + 90_000)
      {:noreply, %{state | job: task}}
    end
  end

  def handle_info({ref, {:ok, snapshot}}, %{job: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    :ets.insert(@table, {:snapshot, snapshot})

    Task.Supervisor.start_child(GoldBackend.TaskSupervisor, fn ->
      TelegramNotifier.notify(snapshot)
    end)

    {:noreply, %{state | job: nil}}
  end

  def handle_info({ref, {:error, reason}}, %{job: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.warning("Analysis failed: #{inspect(reason)}")
    {:noreply, %{state | job: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{job: %{ref: ref}} = state) do
    Logger.warning("Analysis stopped: #{inspect(reason)}")
    {:noreply, %{state | job: nil}}
  end

  def handle_info({:timeout, ref}, %{job: %{ref: ref, pid: pid}} = state) do
    Process.exit(pid, :kill)
    Logger.warning("Analysis timed out")
    {:noreply, %{state | job: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp compute do
    try do
      NewsCrawler.fetch_and_save_all()
    rescue
      error -> Logger.warning("News refresh failed: #{Exception.message(error)}")
    end

    with {:ok, context} <- TradingController.build_context(translate_timeout: 8_000) do
      {action, reason, error} =
        case AiDecision.analyze(context) do
          {:ok, action, reason} ->
            {action, reason, nil}

          {:error, error} ->
            {:wait, "Không có quyết định AI hợp lệ; tiếp tục theo dõi.", error}

          _ ->
            {:wait, "Không có quyết định AI hợp lệ; tiếp tục theo dõi.",
             "Kết quả AI không hợp lệ."}
        end

      snapshot = TradingController.analysis_snapshot(context, action, reason, error)

      snapshot =
        if snapshot.cfd_plan.action != Atom.to_string(action) do
          %{
            snapshot
            | ai_insight: reason <> "\nĐiều kiện khóa lệnh: " <> snapshot.cfd_plan.block_reason
          }
        else
          snapshot
        end

      {:ok, snapshot}
    end
  end
end
