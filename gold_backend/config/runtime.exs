import Config

config :gold_backend, :ollama,
  url: System.get_env("OLLAMA_URL", "http://localhost:11434/api/generate"),
  model: System.get_env("OLLAMA_MODEL", "deepseek-r1:8b"),
  timeout_ms: System.get_env("OLLAMA_TIMEOUT_MS", "120000") |> String.to_integer()

config :gold_backend, :metals_dev_api_key, System.get_env("METALS_DEV_API_KEY")

config :gold_backend,
       :cors_origins,
       System.get_env("CORS_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000")
       |> String.split(",", trim: true)

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is missing. Example: ecto://USER:PASS@HOST/gold_backend"

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing. Generate one with: mix phx.gen.secret"

  host = System.get_env("PHX_HOST") || "localhost"
  port = System.get_env("PORT", "4000") |> String.to_integer()

  config :gold_backend, GoldBackend.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  config :gold_backend, GoldBackendWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end
