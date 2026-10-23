defmodule GoldBackend.Services.InsightCache do
  use GenServer
  require Logger
  alias GoldBackend.Services.{AiDecision, CandleClock, GoldOhlc, OhlcSync, TelegramNotifier}
  alias GoldBackendWeb.TradingController
  @table __MODULE__
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def interval_seconds, do: 300

  def fresh?(%DateTime{} = at, action, current, now \\ DateTime.utc_now()),
    do:
      action == current and DateTime.compare(now, at) != :lt and
        CandleClock.closed_at(at) == CandleClock.closed_at(now)

  def snapshot do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@table, :snapshot) do
          [{:snapshot, data}] -> expire_snapshot(data, DateTime.utc_now())
          _ -> nil
        end
    end
  rescue
    ArgumentError -> nil
  end

  def peek do
    case snapshot() do
      nil ->
        %{ai_insight: nil, ai_error: nil, ai_cached_at: nil, ai_ttl_seconds: interval_seconds()}

      data ->
        Map.take(data, [:ai_insight, :ai_error, :ai_cached_at, :ai_ttl_seconds])
    end
  end

  def resolve(_), do: peek()

  def expire_snapshot(%{ai_next_analysis_at: expiry} = data, now) do
    case if(is_binary(expiry), do: DateTime.from_iso8601(expiry), else: :invalid) do
      {:ok, at, _} ->
        if DateTime.compare(now, at) != :lt do
          reason = "Nhận định đã hết chu kỳ M15; chờ kết quả cho nến vừa đóng."

          invalidate(data, reason)
        else
          data
        end

      _ ->
        invalidate(data, "Thời hạn nhận định M15 không hợp lệ.")
    end
  end

  def expire_snapshot(data, _now), do: data

  defp invalidate(data, reason) do
    Map.merge(data, %{
      ai_action: nil,
      ai_insight: nil,
      ai_error: reason,
      cfd_plan:
        Map.merge(data.cfd_plan, %{
          action: "wait",
          action_label: "Đứng ngoài",
          block_reason: reason,
          summary: reason
        })
    })
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    timer = schedule_refresh(DateTime.utc_now())
    {:ok, %{job: nil, job_slot: nil, last_slot: nil, timer: timer}}
  end

  @impl true
  def handle_info(:refresh, state) do
    now = DateTime.utc_now()
    slot = CandleClock.closed_at(now, interval_seconds())
    Process.cancel_timer(state.timer)
    state = %{state | timer: schedule_refresh(now)}

    if state.job || state.last_slot == slot do
      {:noreply, state}
    else
      task =
        Task.Supervisor.async_nolink(GoldBackend.TaskSupervisor, fn ->
          compute(slot, Map.get(state, :last_ai_candle))
        end)

      timeout = AiDecision.max_duration_ms()

      # News crawling and headline translation run before the AI request budget.
      Process.send_after(self(), {:timeout, task.ref}, timeout + 150_000)
      {:noreply, %{state | job: task, job_slot: slot, last_slot: slot}}
    end
  end

  def handle_info({ref, {:ok, snapshot}}, %{job: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    if CandleClock.current?(CandleClock.closed_at(state.job_slot), DateTime.utc_now()) do
      :ets.insert(@table, {:snapshot, snapshot})

      Task.Supervisor.start_child(GoldBackend.TaskSupervisor, fn ->
        TelegramNotifier.notify(snapshot)
      end)
    else
      Logger.warning("Discarded analysis from an expired M15 candle")
    end

    state =
      if Map.get(snapshot, :ai_attempted),
        do: Map.put(state, :last_ai_candle, snapshot.analysis_candle_closed_at),
        else: state

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

  defp schedule_refresh(now),
    do:
      Process.send_after(
        self(),
        :refresh,
        (interval_seconds() - rem(DateTime.to_unix(now), interval_seconds())) * 1000 -
          div(elem(now.microsecond, 0), 1000) + 35_000
      )

  defp compute(slot, last_ai_candle) do
    candle_slot = CandleClock.closed_at(slot)
    ohlc_feed = OhlcSync.refresh(slot)
    if ohlc_feed.error, do: Logger.warning("OHLC: #{ohlc_feed.error}")

    with {:ok, quote} <- GoldOhlc.quote(),
         {:ok, context} <-
           TradingController.build_context(
             as_of: slot,
             ohlc_feed: ohlc_feed,
             quote: quote,
             news_two_days: true
           ) do
      rule_action = context.plan.action
      candle = DateTime.to_iso8601(candle_slot)

      cond do
        rule_action not in ["buy", "sell"] ->
          {:ok, TradingController.rule_snapshot(context)}

        candle == last_ai_candle ->
          {:ok, TradingController.rule_snapshot(context, "Đã xử lý tín hiệu của nến M15 này.")}

        true ->
          result = AiDecision.analyze(context)
          snapshot = confirmed_snapshot(context, rule_action, result)
          {:ok, Map.put(snapshot, :ai_attempted, true)}
      end
    end
  end

  def confirmed_snapshot(context, rule_action, result, opts \\ []) do
    quote_fn = Keyword.get(opts, :quote, &GoldOhlc.quote/0)

    case result do
      {:ok, action, reason} when action in [:buy, :sell] ->
        if Atom.to_string(action) == rule_action do
          with {:ok, quote} <- quote_fn.(),
               true <- quote_valid?(context, quote),
               true <-
                 CandleClock.current?(
                   CandleClock.closed_at(context.analysis_at),
                   DateTime.utc_now()
                 ) do
            TradingController.analysis_snapshot(context, action, reason, nil)
          else
            _ ->
              TradingController.rule_snapshot(
                context,
                "Giá hoặc chu kỳ không còn hợp lệ sau khi AI phân tích."
              )
          end
        else
          TradingController.rule_snapshot(context, "AI không xác nhận cùng hướng với rule.")
        end

      {:ok, _, _} ->
        TradingController.rule_snapshot(context, "AI chọn đứng ngoài.")

      {:error, error} ->
        TradingController.rule_snapshot(context, "AI lỗi: #{error}")

      _ ->
        TradingController.rule_snapshot(context, "Kết quả AI không hợp lệ.")
    end
  end

  defp quote_valid?(context, %{price: price}) when is_number(price) do
    plan = context.plan
    # A conservative tolerance; reject stale entry and price beyond the stop.
    abs(price - plan.entry) <= min(0.25 * context.indicators.atr_14, 1.0) and
      if(plan.action == "buy", do: price > plan.stop_loss, else: price < plan.stop_loss)
  end

  defp quote_valid?(_, _), do: false
end
