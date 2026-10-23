defmodule GoldBackend.Services.InsightCache do
  use GenServer
  require Logger

  alias GoldBackend.Services.{
    AiDecision,
    CandleClock,
    GoldOhlc,
    OhlcSync,
    TelegramNotifier,
    DecisionJournal
  }

  alias GoldBackendWeb.TradingController
  @table __MODULE__
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def interval_seconds, do: 60

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

  def expire_snapshot(data, now) do
    expiry = get_in(data, [:cfd_plan, :setup_expires_at])

    case if(is_binary(expiry), do: DateTime.from_iso8601(expiry), else: :none) do
      {:ok, at, _} ->
        if DateTime.compare(now, at) != :lt,
          do: invalidate(data, "Setup đã hết hạn; chờ xác nhận mới.", "expired"),
          else: expire_quote(data, now)

      _ ->
        expire_quote(data, now)
    end
  end

  defp expire_quote(data, now) do
    case Map.get(data, :signal_valid_until) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, at, _} ->
            if DateTime.compare(now, at) != :lt,
              do: invalidate(data, "Báo giá đã quá hạn; chờ kiểm tra giá mới."),
              else: expire_analysis(data, now)

          _ ->
            invalidate(data, "Thời hạn báo giá không hợp lệ.")
        end

      _ ->
        expire_analysis(data, now)
    end
  end

  defp expire_analysis(%{ai_next_analysis_at: expiry} = data, now) do
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

  defp expire_analysis(data, _now), do: data

  defp invalidate(data, reason, state \\ "paused") do
    Map.merge(data, %{
      rule_action: "wait",
      ai_action: nil,
      ai_insight: nil,
      ai_error: reason,
      rule_commentary: reason,
      cfd_plan:
        Map.merge(data.cfd_plan, %{
          action: "wait",
          action_label: "Đứng ngoài",
          setup_status:
            if(Map.get(data.cfd_plan, :setup_status) in ["invalidated", "expired"],
              do: data.cfd_plan.setup_status,
              else: state
            ),
          execution_ready: false,
          block_reason: reason,
          summary: reason
        })
    })
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    timer = schedule_refresh(DateTime.utc_now())

    state = %{
      job: nil,
      job_slot: nil,
      last_slot: nil,
      timer: timer,
      compute: Keyword.get(opts, :compute, &compute/1),
      restore: Keyword.get(opts, :restore, &TradingController.stored_snapshot/0)
    }

    if Keyword.get(opts, :bootstrap, true),
      do: {:ok, state, {:continue, :bootstrap}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    # Database-only restore: no provider, calendar, AI or notification calls.
    try do
      case state.restore.() do
        {:ok, snapshot} -> :ets.insert(@table, {:snapshot, snapshot})
        {:error, reason} -> Logger.info("No stored market snapshot: #{inspect(reason)}")
      end
    rescue
      error -> Logger.warning("Could not restore market snapshot: #{Exception.message(error)}")
    end

    # Do not wait for the next evaluation after a restart.
    send(self(), :refresh)
    {:noreply, state}
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
      compute_fn = Map.get(state, :compute, &compute/1)
      task = Task.Supervisor.async_nolink(GoldBackend.TaskSupervisor, fn -> compute_fn.(slot) end)

      # The market-data worker never waits for AI; bound provider and DB latency.
      Process.send_after(self(), {:timeout, task.ref}, 120_000)
      {:noreply, %{state | job: task, job_slot: slot, last_slot: slot}}
    end
  end

  def handle_info({ref, {:ok, snapshot}}, %{job: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    if CandleClock.current?(CandleClock.closed_at(state.job_slot), DateTime.utc_now()) do
      context = Map.get(snapshot, :commentary_context)
      snapshot = Map.delete(snapshot, :commentary_context)

      snapshot =
        case :ets.lookup(@table, :snapshot) do
          [{:snapshot, old}] ->
            if old.analysis_candle_closed_at == snapshot.analysis_candle_closed_at and
                 old.cfd_plan.action == snapshot.cfd_plan.action and
                 Map.get(old.cfd_plan, :setup_id) == Map.get(snapshot.cfd_plan, :setup_id) and
                 Map.get(old.cfd_plan, :entry) == Map.get(snapshot.cfd_plan, :entry) do
              Map.merge(snapshot, Map.take(old, [:ai_insight, :ai_action, :ai_error, :ai_status]))
            else
              snapshot
            end

          _ ->
            snapshot
        end

      :ets.insert(@table, {:snapshot, snapshot})

      if context do
        # Publish first. Slow AI and Telegram cannot hold up the market-data worker.
        Task.Supervisor.start_child(GoldBackend.TaskSupervisor, fn ->
          TelegramNotifier.notify(snapshot)
        end)

        Task.Supervisor.start_child(GoldBackend.TaskSupervisor, fn ->
          result = AiDecision.analyze(context)

          GenServer.cast(
            __MODULE__,
            {:commentary, snapshot.analysis_candle_closed_at, snapshot.cfd_plan.action, result,
             snapshot.cfd_plan.setup_id, snapshot.cfd_plan.entry}
          )
        end)
      end
    else
      Logger.warning("Discarded analysis from an expired M15 candle")
    end

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

  defp compute(slot) do
    ohlc_feed = OhlcSync.refresh(slot)
    if ohlc_feed.error, do: Logger.warning("OHLC: #{ohlc_feed.error}")
    GoldBackend.Services.SignalHistory.refresh()

    quote =
      case GoldOhlc.quote() do
        {:ok, value} -> value
        _ -> nil
      end

    with {:ok, context} <-
           TradingController.build_context(
             as_of: DateTime.utc_now(),
             ohlc_feed: ohlc_feed,
             quote: quote,
             news_two_days: true
           ) do
      current_quote =
        case GoldOhlc.quote() do
          {:ok, value} -> value
          _ -> nil
        end

      context =
        GoldBackend.Services.StrategyPlan.revalidate(context, current_quote, DateTime.utc_now())

      GoldBackend.Services.SignalHistory.reconcile(context)

      if CandleClock.closed_at(slot) == CandleClock.closed_at(context.analysis_at) and
           CandleClock.current?(CandleClock.closed_at(context.analysis_at), DateTime.utc_now()) do
        case DecisionJournal.record(context) do
          {:ok, {context, publish?}} ->
            Logger.info(
              "trade_checks " <>
                Jason.encode!(%{
                  candle: CandleClock.closed_at(context.analysis_at),
                  version: context.plan.strategy_version,
                  action: context.plan.action,
                  checks: context.plan.checks
                })
            )

            snapshot = TradingController.rule_snapshot(context)

            snapshot =
              if not publish? and context.plan.action in ["buy", "sell"],
                do:
                  apply_commentary(
                    snapshot,
                    {:error, "Phiếu đã phát trước đó; chưa có bình luận AI trong bộ nhớ."}
                  ),
                else: snapshot

            {:ok,
             if(publish?, do: Map.put(snapshot, :commentary_context, context), else: snapshot)}

          {:error, _} ->
            {:error, "Không lưu được nhật ký quyết định; chưa phát phiếu."}
        end
      else
        {:error, "Nến phân tích đã hết hạn."}
      end
    end
  end

  @impl true
  def handle_cast({:commentary, candle, action, result, setup_id, entry}, state) do
    case :ets.lookup(@table, :snapshot) do
      [{:snapshot, snapshot}] ->
        if Map.get(snapshot.cfd_plan, :setup_id) == setup_id and snapshot.cfd_plan.entry == entry,
          do: handle_cast({:commentary, candle, action, result}, state),
          else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:commentary, candle, action, result}, state) do
    case :ets.lookup(@table, :snapshot) do
      [{:snapshot, snapshot}] ->
        if snapshot.analysis_candle_closed_at == candle and snapshot.cfd_plan.action == action and
             candle == DateTime.to_iso8601(CandleClock.closed_at(DateTime.utc_now())) do
          :ets.insert(@table, {:snapshot, apply_commentary(snapshot, result)})
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def apply_commentary(snapshot, {:ok, action, reason}) do
    if to_string(action) == snapshot.cfd_plan.action do
      case AiDecision.validate_reason(reason) do
        {:ok, text} ->
          Map.merge(snapshot, %{
            ai_action: to_string(action),
            ai_insight: text,
            ai_error: nil,
            ai_status: "ready"
          })

        {:error, error} ->
          apply_commentary(snapshot, {:error, error})
      end
    else
      apply_commentary(
        snapshot,
        {:error, "Bình luận AI khác quyết định rule; không sử dụng bình luận."}
      )
    end
  end

  def apply_commentary(snapshot, {:ok, action, reason, nil}),
    do: apply_commentary(snapshot, {:ok, action, reason})

  def apply_commentary(snapshot, {:error, _, _, error}),
    do: apply_commentary(snapshot, {:error, error})

  def apply_commentary(snapshot, {:error, error}),
    do:
      Map.merge(snapshot, %{ai_action: nil, ai_insight: nil, ai_error: error, ai_status: "error"})

  def apply_commentary(snapshot, _),
    do: apply_commentary(snapshot, {:error, "Bình luận AI không hợp lệ."})

  # Compatibility entry point: AI results only enrich the existing rule snapshot.
  def confirmed_snapshot(context, _rule_action, result, _opts \\ []),
    do: TradingController.rule_snapshot(context) |> apply_commentary(result)
end
