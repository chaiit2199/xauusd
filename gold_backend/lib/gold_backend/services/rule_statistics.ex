defmodule GoldBackend.Services.RuleStatistics do
  @moduledoc "Count complete one-minute evaluations, including unknown and sole-blocker checks."
  import Ecto.Query
  alias GoldBackend.{Repo, Services.StrategyPolicy}

  def recent(now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -7, :day)
    version = StrategyPolicy.version()

    rows =
      Repo.all(
        from e in "strategy_evaluations",
          where: e.evaluated_at >= ^since and e.evaluated_at <= ^now and e.version == ^version,
          select: e.snapshot
      )

    %{version: version, days: 7, evaluations: length(rows), checks: summarize(rows)}
  end

  def summarize(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      checks = Map.get(row, "checks", [])

      unmet =
        Enum.count(
          checks,
          &(Map.get(&1, "required", true) and &1["status"] not in ["pass", "warning"])
        )

      Enum.reduce(checks, acc, fn c, counts ->
        code = c["code"]

        item =
          Map.get(counts, code, %{
            code: code,
            evaluated: 0,
            pass: 0,
            blocked: 0,
            unknown: 0,
            warning: 0,
            sole_blocker: 0
          })

        status =
          case if(c["required"] == false and c["status"] != "pass",
                 do: "warning",
                 else: c["status"]
               ) do
            "pass" -> :pass
            "blocked" -> :blocked
            "warning" -> :warning
            _ -> :unknown
          end

        item = item |> Map.update!(:evaluated, &(&1 + 1)) |> Map.update!(status, &(&1 + 1))

        item =
          if status == :blocked and unmet == 1,
            do: Map.update!(item, :sole_blocker, &(&1 + 1)),
            else: item

        Map.put(counts, code, item)
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.code)
  end
end
