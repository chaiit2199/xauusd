defmodule GoldBackend.Repo do
  use Ecto.Repo,
    otp_app: :gold_backend,
    adapter: Ecto.Adapters.Postgres
end
