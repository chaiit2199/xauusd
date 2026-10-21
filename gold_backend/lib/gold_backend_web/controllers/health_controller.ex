defmodule GoldBackendWeb.HealthController do
  use GoldBackendWeb, :controller

  alias GoldBackend.Repo

  def show(conn, _params) do
    case Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _} ->
        json(conn, %{status: "ok", database: "up"})

      {:error, _} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", database: "down"})
    end
  rescue
    _ in [DBConnection.ConnectionError] ->
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "error", database: "down"})
  catch
    :exit, _ ->
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "error", database: "down"})
  end
end
