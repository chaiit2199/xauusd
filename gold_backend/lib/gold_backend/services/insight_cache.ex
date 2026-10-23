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
      rule_commentary: reason,
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

    # Do not wait for the next five-minute boundary after a restart.
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
                 old.cfd_plan.action == snapshot.cfd_plan.action do
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
            {:commentary, snapshot.analysis_candle_closed_at, snapshot.cfd_plan.action, result}
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

    with {:ok, quote} <- GoldOhlc.quote(),
         {:ok, context} <-
           TradingController.build_context(
             as_of: DateTime.utc_now(),
             ohlc_feed: ohlc_feed,
             quote: quote,
             news_two_days: true
           ),
         {:ok, current_quote} <- GoldOhlc.quote() do
      context =
        if context.plan.action in ["buy", "sell"] and not quote_valid?(context, current_quote) do
          reason = "Giá thay đổi trong lúc phân tích; chờ chu kỳ tiếp theo."
          check = %{code: "publication_quote", status: "blocked", reason: reason}

          plan =
            Map.merge(context.plan, %{
              action: "wait",
              action_label: "Đứng ngoài",
              block_reason: reason,
              summary: reason,
              rule_commentary: reason,
              checks: context.plan.checks ++ [check],
              blocking_reasons: context.plan.blocking_reasons ++ [reason]
            })

          %{context | plan: plan}
        else
          context
        end

      publication_now = DateTime.utc_now()
      event = GoldBackend.Services.EconomicCalendar.blocking(context.events, publication_now)
      vn_hour = DateTime.add(publication_now, 7 * 3600).hour

      context =
        if context.plan.action in ["buy", "sell"] and
             (not is_nil(event) or vn_hour < 14 or vn_hour >= 22) do
          reason = "Cửa sổ tin hoặc phiên giao dịch đã thay đổi trước khi phát phiếu."
          check = %{code: "publication_window", status: "blocked", reason: reason}

          plan =
            Map.merge(context.plan, %{
              action: "wait",
              action_label: "Đứng ngoài",
              block_reason: reason,
              summary: reason,
              rule_commentary: reason,
              checks: context.plan.checks ++ [check],
              blocking_reasons: context.plan.blocking_reasons ++ [reason]
            })

          %{context | plan: plan}
        else
          context
        end

      if CandleClock.closed_at(slot) == CandleClock.closed_at(context.analysis_at) and
           CandleClock.current?(CandleClock.closed_at(context.analysis_at), DateTime.utc_now()) do
        case DecisionJournal.record(context) do
          {:ok, {context, publish?}} ->
            Logger.info(
              "trade_checks " <>
                Jason.encode!(%{
                  candle: CandleClock.closed_at(context.analysis_at),
                  version: "zoi-v1",
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

  defp quote_valid?(context, %{price: price, timestamp: at}) when is_number(price) do
    plan = context.plan
    age = DateTime.diff(DateTime.utc_now(), at)

    age in -5..120 and abs(price - plan.entry) <= min(0.25 * context.indicators.atr_14, 1.0) and
      if(plan.action == "buy",
        do: price > plan.stop_loss and price < plan.take_profit,
        else: price < plan.stop_loss and price > plan.take_profit
      )
  end

  defp quote_valid?(_, _), do: false
end
