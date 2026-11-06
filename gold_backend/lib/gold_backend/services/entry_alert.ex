defmodule GoldBackend.Services.EntryAlert do
  @moduledoc "Prepare AI wording on PLAN_READY; recheck fresh prices and all entry rules before delivery."
  require Logger
  import Ecto.Query
  alias GoldBackend.Repo

  alias GoldBackend.Services.{
    AiDecision,
    GoldOhlc,
    StrategyPlan,
    PlanPublisher,
    CandleClock,
    EntryBriefCache
  }

  alias GoldBackendWeb.TradingController

  def publish(snapshot, opts \\ [])

  def publish(%{cfd_plan: plan, entry_context: context}, opts) when is_map(context) do
    if Map.get(plan, :plan_status) == "PLAN_READY" or
         Map.get(plan, :trade_plan_status) == "READY_TO_ENTER" do
      id = plan.setup_id

      # Delivery must never wait on an in-flight AI preparation lock.
      lane = if plan[:trade_plan_status] == "READY_TO_ENTER", do: :delivery, else: :prepare
      :global.trans({{__MODULE__, id, lane}, self()}, fn -> run(plan, context, opts) end)
    else
      []
    end
  end

  def publish(_, _), do: []

  defp run(plan, context, opts) do
    id = plan.setup_id
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    now = clock.()

    cond do
      Repo.exists?(
        from n in "strategy_notifications",
          where: n.setup_id == ^id and n.event == "READY_TO_ENTER"
      ) ->
        log(id, :dedup, :already_sent)
        :already_sent

      not current?(context, now) ->
        fail(id, :context, :expired)

      Map.get(plan, :trade_plan_status) == "READY_TO_ENTER" ->
        brief =
          case EntryBriefCache.get(cache_key(context, now), now) do
            {:ok, value} ->
              if AiDecision.validate_brief(value) == :ok, do: value, else: nil

            :miss ->
              nil
          end

        log(id, :wording, if(brief, do: :cached_ai, else: :ai_unavailable))
        deliver(context, brief, opts, clock)

      true ->
        with {:ok, brief} <- prepared(context, opts, now, clock),
             :ok <- ensure_current(context, clock.()),
             :ok <- share_brief(context, brief) do
          log(id, :prepare, :ready)
          :prepared
        else
          {:error, {stage, reason}} -> fail(id, stage, reason)
        end
    end
  rescue
    error -> fail(plan.setup_id, :exception, error.__struct__)
  end

  def cache_key(context, now) do
    config = Application.get_env(:gold_backend, :ollama, [])
    input = AiDecision.entry_brief_input(context, now)

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {:brief_v2, CandleClock.closed_at(context.analysis_at), Keyword.get(config, :model),
         Keyword.get(config, :entry_brief_num_predict, 450), input}
      )
    )
  end

  defp prepared(context, opts, now, clock) do
    key = cache_key(context, now)

    case EntryBriefCache.get(key, now) do
      {:ok, brief} ->
        log(context.plan.setup_id, :cache, :hit)
        {:ok, brief}

      :miss ->
        log(context.plan.setup_id, :ai, :started)
        started = System.monotonic_time(:millisecond)
        result = Keyword.get(opts, :brief, &AiDecision.entry_brief/1).(context)
        elapsed = System.monotonic_time(:millisecond) - started

        case result do
          {:ok, brief} ->
            with :ok <- stage(:validation, AiDecision.validate_brief(brief)),
                 :ok <- ensure_current(context, clock.()) do
              expiry = CandleClock.next_close(context.analysis_at)
              EntryBriefCache.put(key, brief, expiry, clock.())

              Logger.info(
                "entry_alert " <>
                  Jason.encode!(%{
                    setup_id: context.plan.setup_id,
                    stage: "ai",
                    result: "ready",
                    elapsed_ms: elapsed
                  })
              )

              {:ok, brief}
            end

          {:error, reason} ->
            {:error, {:ai, reason}}

          _ ->
            {:error, {:ai, :unexpected_result}}
        end
    end
  end

  defp deliver(context, brief, opts, clock) do
    id = context.plan.setup_id

    with {:ok, quote} <- stage(:quote, Keyword.get(opts, :quote, &GoldOhlc.quote/0).()),
         now = clock.(),
         :ok <- ensure_current(context, now),
         fresh = Keyword.get(opts, :revalidate, &StrategyPlan.revalidate/3).(context, quote, now),
         :ok <- trace_revalidation(context.plan, fresh.plan, quote),
         :ok <- same_ready_setup(context.plan, fresh.plan) do
      snapshot =
        Keyword.get(opts, :snapshot, &TradingController.rule_snapshot/1).(fresh)
        |> Map.put(:entry_brief, brief)

      result = Keyword.get(opts, :publish, &PlanPublisher.publish/1).(snapshot)
      log(id, :delivery, result)
      result
    else
      {:error, {stage, reason}} -> fail(id, stage, reason)
    end
  end

  defp trace_revalidation(old, fresh, quote) do
    Logger.info(
      "entry_revalidation " <>
        Jason.encode!(%{
          setup_id: old[:setup_id],
          previous_status: old[:trade_plan_status],
          quote_price: quote[:price],
          quote_at: quote[:timestamp],
          reference_entry: old[:reference_entry],
          stop_loss: old[:stop_loss],
          take_profit: old[:take_profit],
          fresh_setup_id: fresh[:setup_id],
          status: fresh[:trade_plan_status],
          blockers: fresh[:blocking_reasons]
        })
    )

    :ok
  end

  defp same_ready_setup(old, fresh) do
    reason =
      cond do
        fresh.setup_id != old.setup_id ->
          :setup_changed

        fresh.action != old.action ->
          :direction_changed

        fresh.trade_plan_status != "READY_TO_ENTER" ->
          {:not_ready, fresh.trade_plan_status}

        fresh.stop_loss != old.stop_loss or fresh.take_profit != old.take_profit ->
          :levels_changed

        true ->
          nil
      end

    if reason, do: {:error, {:revalidation, reason}}, else: :ok
  end

  defp current?(context, now) do
    candle_ok = CandleClock.current?(CandleClock.closed_at(context.analysis_at), now)
    expiry = Map.get(context.plan, :setup_expires_at)

    expiry_ok =
      if is_nil(expiry),
        do: true,
        else:
          (case DateTime.from_iso8601(expiry) do
             {:ok, at, _} -> DateTime.compare(now, at) == :lt
             _ -> false
           end)

    candle_ok and expiry_ok
  end

  defp ensure_current(context, now),
    do: if(current?(context, now), do: :ok, else: {:error, {:context, :expired}})

  defp stage(_, :ok), do: :ok
  defp stage(_, {:ok, result}), do: {:ok, result}
  defp stage(stage, {:error, reason}), do: {:error, {stage, reason}}

  defp fail(id, stage, reason) do
    Logger.warning(
      "entry_alert " <>
        Jason.encode!(%{
          setup_id: id,
          stage: to_string(stage),
          result: "skipped",
          reason: inspect(reason, limit: 10, printable_limit: 240)
        })
    )

    {:error, {stage, reason}}
  end

  defp log(id, stage, result),
    do:
      Logger.info(
        "entry_alert " <>
          Jason.encode!(%{
            setup_id: id,
            stage: to_string(stage),
            result: inspect(result, limit: 10, printable_limit: 240)
          })
      )

  defp share_brief(context, brief) do
    if Process.whereis(GoldBackend.Services.InsightCache) do
      text = Enum.map_join(["reason", "opportunity", "risk"], "\n", &Map.fetch!(brief, &1))

      GenServer.cast(
        GoldBackend.Services.InsightCache,
        {:commentary, DateTime.to_iso8601(CandleClock.closed_at(context.analysis_at)),
         context.plan.action, {:ok, context.plan.action, text}, context.plan.setup_id,
         context.plan.entry}
      )
    end

    :ok
  end
end
