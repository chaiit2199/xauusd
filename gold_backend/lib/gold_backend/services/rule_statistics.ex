defmodule GoldBackend.Services.RuleStatistics do
  @moduledoc "Count complete one-minute evaluations, including unknown and sole-blocker checks."
  alias GoldBackend.{Repo, Services.StrategyPolicy}

  # Aggregate in PostgreSQL: transferring full plan snapshots for every evaluation
  # made overview spend its connection timeout decoding JSONB. Only the compact
  # counters cross the wire now, independent of snapshot size/evaluation count.
  @recent_sql """
  WITH evaluations AS MATERIALIZED (
    SELECT id, snapshot->'checks' AS checks,
           snapshot->'stop_cap_audit' AS stop_cap_audit
    FROM strategy_evaluations
    WHERE evaluated_at >= $1 AND evaluated_at <= $2 AND version = $3
  ), checks AS (
    SELECT e.id, c.item,
      count(*) FILTER (
        WHERE coalesce(c.item->'required', 'true'::jsonb) = 'true'::jsonb
          AND coalesce(c.item->>'status', '') NOT IN ('pass', 'warning')
      ) OVER (PARTITION BY e.id) AS unmet
    FROM evaluations e
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE WHEN jsonb_typeof(e.checks) = 'array' THEN e.checks ELSE '[]'::jsonb END
    ) c(item)
  ), classified AS (
    SELECT item->>'code' AS code, unmet,
      CASE
        WHEN item->'required' = 'false'::jsonb
          AND (item->>'status') IS DISTINCT FROM 'pass'
          AND (item->>'scope') IS DISTINCT FROM 'current_entry' THEN 'warning'
        WHEN item->>'status' IN ('pass', 'blocked', 'warning') THEN item->>'status'
        ELSE 'unknown'
      END AS status
    FROM checks
  ), totals AS (
    SELECT code, count(*) AS evaluated,
      count(*) FILTER (WHERE status = 'pass') AS pass,
      count(*) FILTER (WHERE status = 'blocked') AS blocked,
      count(*) FILTER (WHERE status = 'unknown') AS unknown,
      count(*) FILTER (WHERE status = 'warning') AS warning,
      count(*) FILTER (WHERE status = 'blocked' AND unmet = 1) AS sole_blocker
    FROM classified GROUP BY code
  ), samples AS (
    SELECT s.item FROM evaluations e
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE WHEN jsonb_typeof(e.stop_cap_audit) = 'array'
        THEN e.stop_cap_audit ELSE '[]'::jsonb END
    ) s(item)
  )
  SELECT (SELECT count(*) FROM evaluations),
    coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.code) FROM totals t), '[]'::jsonb),
    (SELECT jsonb_build_object(
      'evaluations', count(*),
      'candidates', count(DISTINCT coalesce(item->'setup_id', 'null'::jsonb)),
      'sole_candidates', count(DISTINCT coalesce(item->'setup_id', 'null'::jsonb))
        FILTER (WHERE item->'sole_blocker' = 'true'::jsonb)
    ) FROM samples)
  """
  @check_fields ~w(code evaluated pass blocked unknown warning sole_blocker)a
  @stop_fields ~w(evaluations candidates sole_candidates)a

  def recent(now \\ DateTime.utc_now()) do
    version = StrategyPolicy.version()
    since = DateTime.add(now, -7, :day)

    %{rows: [[evaluations, checks, stop_cap]]} =
      Repo.query!(@recent_sql, [DateTime.to_naive(since), DateTime.to_naive(now), version])

    %{
      version: version,
      days: 7,
      evaluations: evaluations,
      checks: Enum.map(checks, &known_fields(&1, @check_fields)),
      stop_cap: known_fields(stop_cap, @stop_fields)
    }
  end

  defp known_fields(row, fields) do
    Map.new(fields, fn field -> {field, Map.fetch!(row, Atom.to_string(field))} end)
  end

  def stop_caps(rows) do
    samples = Enum.flat_map(rows, &Map.get(&1, "stop_cap_audit", []))

    %{
      evaluations: length(samples),
      candidates: samples |> Enum.uniq_by(& &1["setup_id"]) |> length(),
      sole_candidates:
        samples
        |> Enum.filter(&(&1["sole_blocker"] == true))
        |> Enum.uniq_by(& &1["setup_id"])
        |> length()
    }
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
          case if(
                 c["required"] == false and c["status"] != "pass" and
                   c["scope"] != "current_entry",
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
