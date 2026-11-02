defmodule GoldBackend.Services.EntryAlert do
  @moduledoc "AI wording followed by a fresh quote and the unchanged entry rules."
  require Logger
  import Ecto.Query
  alias GoldBackend.Repo
  alias GoldBackend.Services.{AiDecision, GoldOhlc, StrategyPlan, PlanPublisher, CandleClock}
  alias GoldBackendWeb.TradingController

  def publish(snapshot, opts \\ [])

  def publish(
        %{cfd_plan: %{trade_plan_status: "READY_TO_ENTER", setup_id: id}, entry_context: context},
        opts
      )
      when is_map(context) do
    # Serialize per setup on this node without holding a database connection during AI.
    :global.trans({{__MODULE__, id}, self()}, fn ->
      if Repo.exists?(
           from n in "strategy_notifications",
             where: n.setup_id == ^id and n.event == "READY_TO_ENTER"
         ) do
        :already_sent
      else
        brief_fn = Keyword.get(opts, :brief, &AiDecision.entry_brief/1)
        quote_fn = Keyword.get(opts, :quote, &GoldOhlc.quote/0)
        revalidate = Keyword.get(opts, :revalidate, &StrategyPlan.revalidate/3)
        snapshot_fn = Keyword.get(opts, :snapshot, &TradingController.rule_snapshot/1)
        publish_fn = Keyword.get(opts, :publish, &PlanPublisher.publish/1)
        clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

        result =
          with {:ok, brief} <- brief_fn.(context),
               :ok <- AiDecision.validate_brief(brief),
               :ok <-
                 share_brief(
                   context,
                   {:ok, context.plan.action,
                    Enum.map_join(["reason", "opportunity", "risk"], "\n", &Map.fetch!(brief, &1))}
                 ),
               {:ok, quote} <- quote_fn.(),
               now = clock.(),
               true <- CandleClock.current?(CandleClock.closed_at(context.analysis_at), now),
               fresh = revalidate.(context, quote, now),
               true <-
                 fresh.plan.setup_id == id and fresh.plan.action == context.plan.action and
                   fresh.plan.trade_plan_status == "READY_TO_ENTER" and
                   fresh.plan.stop_loss == context.plan.stop_loss and
                   fresh.plan.take_profit == context.plan.take_profit do
            fresh |> snapshot_fn.() |> Map.put(:entry_brief, brief) |> publish_fn.()
          else
            _ -> {:error, :entry_alert_not_ready}
          end

        if match?({:error, _}, result),
          do:
            Logger.warning(
              "Entry alert skipped: AI unavailable, stale context or current entry no longer eligible"
            )

        result
      end
    end)
  end

  def publish(_, _), do: []

  defp share_brief(context, result) do
    if Process.whereis(GoldBackend.Services.InsightCache) do
      GenServer.cast(
        GoldBackend.Services.InsightCache,
        {:commentary, DateTime.to_iso8601(CandleClock.closed_at(context.analysis_at)),
         context.plan.action, result, context.plan.setup_id, context.plan.entry}
      )
    end

    :ok
  end
end
