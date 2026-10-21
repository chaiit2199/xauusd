defmodule GoldBackendWeb.Plugs.CORS do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = conn |> get_req_header("origin") |> List.first()

    conn =
      if origin && allowed?(origin) do
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
        |> put_resp_header("access-control-allow-headers", "content-type, accept")
        |> put_resp_header("access-control-max-age", "86400")
        |> put_resp_header("vary", "origin")
      else
        conn
      end

    if conn.method == "OPTIONS" do
      conn |> send_resp(204, "") |> halt()
    else
      conn
    end
  end

  defp allowed?(origin) do
    configured = Application.get_env(:gold_backend, :cors_origins, [])

    origin in configured or local_origin?(origin)
  end

  defp local_origin?(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        host in ["localhost", "127.0.0.1"]

      _ ->
        false
    end
  end
end
