defmodule Mix.Tasks.Gold.Decisions do
  use Mix.Task
  import Ecto.Query
  @shortdoc "Summarize unique M15 decisions and blocking checks (no orders sent)"
  def run(_) do
    Mix.Task.run("app.config")
    Application.put_env(:gold_backend, :start_price_fetcher, false)
    Mix.Task.run("app.start")
    rows = GoldBackend.Repo.all(from d in "strategy_decisions", select: d.snapshot)

    counts =
      rows
      |> Enum.flat_map(&Map.get(&1, "checks", []))
      |> Enum.reject(&(&1["status"] == "pass"))
      |> Enum.frequencies_by(&{&1["code"], &1["status"]})

    Mix.shell().info("Unique M15 decisions: #{length(rows)}")

    Enum.sort(counts)
    |> Enum.each(fn {{code, status}, n} -> Mix.shell().info("#{code} [#{status}]: #{n}") end)

    Mix.shell().info(
      "Blocked counts are not missed profitable trades. Validate outcomes separately."
    )
  end
end
