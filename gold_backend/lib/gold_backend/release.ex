defmodule GoldBackend.Release do
  @moduledoc "Database migrations for releases without starting the HTTP server."
  @app :gold_backend

  @spec migrate() :: :ok
  def migrate do
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end
end
