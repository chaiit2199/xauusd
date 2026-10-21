import Config

config :gold_backend,
  ecto_repos: [GoldBackend.Repo],
  generators: [timestamp_type: :utc_datetime],
  start_price_fetcher: true

config :gold_backend, GoldBackendWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: GoldBackendWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GoldBackend.PubSub

config :gold_backend, :ollama,
  url: "http://localhost:11434/api/generate",
  model: "deepseek-r1:1.5b",
  timeout_ms: 120_000

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
