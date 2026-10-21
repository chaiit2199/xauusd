import Config

config :gold_backend, :ollama,
  url: System.get_env("OLLAMA_URL", "http://localhost:11434/api/generate"),
  model: System.get_env("OLLAMA_MODEL", "deepseek-r1:8b"),
  timeout_ms: String.to_integer(System.get_env("OLLAMA_TIMEOUT_MS", "120000"))

config :gold_backend, :metals_dev_api_key, System.get_env("METALS_DEV_API_KEY")

config :gold_backend,
       :cors_origins,
       System.get_env("CORS_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000")
       |> String.split(",", trim: true)

if config_env() == :prod do
  # Production credentials are read at boot, including when running a release.
  # DATABASE_URL được ưu tiên; release cục bộ (rel/env.sh.eex) dùng DB_*.
  database_config =
    case System.get_env("DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        [url: url]

      _ ->
        [
          username: System.fetch_env!("DB_USER"),
          password: System.fetch_env!("DB_PASSWORD"),
          hostname: System.fetch_env!("DB_HOST"),
          database: System.fetch_env!("DB_NAME"),
          port: String.to_integer(System.get_env("DB_PORT", "5432"))
        ]
    end

  config :gold_backend, GoldBackend.Repo, database_config

  config :gold_backend, GoldBackend.Repo,
    pool_size:
      String.to_integer(System.get_env("DB_POOL_SIZE") || System.get_env("POOL_SIZE", "10")),
    show_sensitive_data_on_connection_error: false,
    socket_options: if(System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: [])

  config :gold_backend, GoldBackendWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST", "localhost"), scheme: "https", port: 443],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT", "4000"))
    ],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    server: true
end

if System.get_env("PHX_SERVER") in ["true", "1"] do
  config :gold_backend, GoldBackendWeb.Endpoint, server: true
end
