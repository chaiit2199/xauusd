defmodule GoldBackend.Application do
  use Application

  @impl true
  def start(_type, _args) do
    GoldBackend.Services.TelegramNotifier.validate_config()

    children =
      [
        GoldBackend.Repo,
        GoldBackend.Services.CalendarCache,
        {Phoenix.PubSub, name: GoldBackend.PubSub},
        {Task.Supervisor, name: GoldBackend.TaskSupervisor},
        GoldBackendWeb.Endpoint
      ] ++ price_fetcher()

    Supervisor.start_link(children, strategy: :one_for_one, name: GoldBackend.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    GoldBackendWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp price_fetcher do
    if Application.get_env(:gold_backend, :start_price_fetcher, true) do
      [GoldBackend.Services.GoldPriceFetcher, GoldBackend.Services.InsightCache]
    else
      []
    end
  end
end
