defmodule GoldBackend.Services.PlanPublisher do
  @moduledoc "Durable successful-delivery deduplication per setup and lifecycle event. Failed deliveries retry on subsequent evaluations."
  import Ecto.Query
  alias GoldBackend.Repo
  alias GoldBackend.Services.TelegramNotifier

  def publish(snapshot, opts \\ [])

  def publish(%{cfd_plan: %{setup_id: id} = plan} = snapshot, opts) when is_binary(id) do
    terminal = terminal_state(plan, Keyword.get(opts, :now, DateTime.utc_now()))

    plan =
      if terminal,
        do: Map.merge(plan, %{setup_status: terminal, plan_status: String.upcase(terminal)}),
        else: plan

    snapshot = %{snapshot | cfd_plan: plan}

    events =
      if Map.get(plan, :plan_status) == "PLAN_READY" and
           Map.get(plan, :trade_plan_status) == "READY_TO_ENTER",
         do: ["READY_TO_ENTER"],
         else: []

    Enum.map(events, fn event ->
      # Transaction-scoped lock is released on process exit; no persistent session lock.
      Repo.transaction(
        fn ->
          key = id <> ":" <> event
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])

          if Repo.exists?(
               from n in "strategy_notifications", where: n.setup_id == ^id and n.event == ^event
             ) do
            :already_sent
          else
            result =
              if event not in ["INVALIDATED", "EXPIRED"] and
                   terminal_state(plan, Keyword.get(opts, :now, DateTime.utc_now())),
                 do: {:error, :superseded},
                 else: TelegramNotifier.notify_event(snapshot, event, opts)

            case result do
              :ok ->
                Repo.insert_all("strategy_notifications", [
                  %{
                    setup_id: id,
                    event: event,
                    sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
                  }
                ])

                :sent

              {:error, _} = error ->
                error
            end
          end
        end,
        timeout: 20_000
      )
    end)
  end

  def publish(_, _), do: []
  def publish_terminal(snapshot, opts \\ [])

  def publish_terminal(%{cfd_plan: %{setup_id: id} = plan} = snapshot, opts) when is_binary(id) do
    if terminal_state(plan, Keyword.get(opts, :now, DateTime.utc_now())),
      do: publish(snapshot, opts),
      else: []
  end

  def publish_terminal(_, _), do: []

  defp terminal_state(plan, now) do
    stored =
      Repo.one(
        from i in "strategy_invalidations", where: i.setup_id == ^plan.setup_id, select: i.state
      )

    case DateTime.from_iso8601(Map.get(plan, :setup_expires_at) || "") do
      {:ok, expiry, _} -> stored || if(DateTime.compare(now, expiry) != :lt, do: "expired")
      _ -> stored
    end
  end
end
