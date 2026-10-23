defmodule Mix.Tasks.Gold.Decisions do
  use Mix.Task
  @shortdoc "Summarize signal checks over the last seven days (no orders sent)"
  def run(_) do
    Mix.Task.run("app.config")
    Application.put_env(:gold_backend, :start_price_fetcher, false)
    Mix.Task.run("app.start")
    stats = GoldBackend.Services.RuleStatistics.recent()
    Mix.shell().info("#{stats.version}: #{stats.evaluations} evaluations / #{stats.days} days")

    Enum.each(stats.checks, fn c ->
      Mix.shell().info(
        "#{c.code}: evaluated=#{c.evaluated} pass=#{c.pass} blocked=#{c.blocked} unknown=#{c.unknown} sole_blocker=#{c.sole_blocker}"
      )
    end)

    Mix.shell().info("Signal evaluations are not fills or profitable-trade outcomes.")
  end
end
