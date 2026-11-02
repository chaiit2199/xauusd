defmodule GoldBackend.Services.RuleStatisticsTest do
  use ExUnit.Case, async: false
  alias GoldBackend.Repo
  alias GoldBackend.Services.{RuleStatistics, StrategyPolicy}
  @now ~U[2026-11-02 12:00:00Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "empty history preserves the public response contract" do
    assert RuleStatistics.recent(@now) == %{
             version: StrategyPolicy.version(),
             days: 7,
             evaluations: 0,
             checks: [],
             stop_cap: %{evaluations: 0, candidates: 0, sole_candidates: 0}
           }
  end

  test "SQL aggregation matches existing rules including optional checks and missing statuses" do
    snapshots = [
      %{
        "checks" => [
          %{"code" => "quote", "status" => "blocked"},
          %{"code" => "liquidity", "status" => "pass"},
          %{"code" => "optional", "required" => false, "status" => "blocked"},
          %{
            "code" => "entry",
            "required" => false,
            "scope" => "current_entry",
            "status" => "blocked"
          }
        ],
        "stop_cap_audit" => [%{"setup_id" => "a", "sole_blocker" => true}]
      },
      %{
        "checks" => [
          %{"code" => "quote", "status" => "blocked"},
          %{"code" => "liquidity", "status" => "unknown"},
          %{"code" => "optional", "required" => false},
          %{"code" => "entry", "required" => false, "scope" => "current_entry"}
        ],
        "stop_cap_audit" => [
          %{"setup_id" => "a", "sole_blocker" => false},
          %{"setup_id" => "b", "sole_blocker" => true}
        ]
      },
      %{
        "checks" => [
          %{"code" => "quote", "status" => "warning"},
          %{"code" => "liquidity"},
          %{"code" => "optional", "required" => false, "status" => "pass"}
        ],
        "stop_cap_audit" => [%{"sole_blocker" => true}]
      },
      %{}
    ]

    for {snapshot, index} <- Enum.with_index(snapshots),
        do: insert(snapshot, DateTime.add(@now, -index * 60))

    result = RuleStatistics.recent(@now)
    assert result.evaluations == length(snapshots)
    assert result.checks == RuleStatistics.summarize(snapshots)
    assert result.stop_cap == RuleStatistics.stop_caps(snapshots)
  end

  test "seven-day inclusive window and strategy version exclude unrelated history" do
    snapshot = %{"checks" => [%{"code" => "quote", "status" => "pass"}]}
    since = DateTime.add(@now, -7, :day)
    insert(snapshot, since)
    insert(snapshot, @now)
    insert(snapshot, DateTime.add(since, -1))
    insert(snapshot, DateTime.add(@now, 1))
    insert(snapshot, DateTime.add(@now, -60), "old-version")
    assert %{evaluations: 2, checks: [%{pass: 2}]} = RuleStatistics.recent(@now)
  end

  test "large unrelated snapshot fields do not affect compact counters and null arrays are safe" do
    snapshot = %{
      "checks" => [%{"code" => "quote", "status" => "pass"}],
      "unrelated_history" => String.duplicate("large-candle-context-", 5000)
    }

    for index <- 1..100, do: insert(snapshot, DateTime.add(@now, -index * 60))
    insert(%{"checks" => nil, "stop_cap_audit" => nil}, @now)
    result = RuleStatistics.recent(@now)
    assert result.evaluations == 101
    assert [%{pass: 100, evaluated: 100}] = result.checks
    assert byte_size(Jason.encode!(result)) < 1024
  end

  defp insert(snapshot, at, version \\ StrategyPolicy.version()) do
    Repo.insert_all("strategy_evaluations", [
      %{
        evaluated_at: at,
        version: version,
        snapshot: snapshot,
        inserted_at: at,
        updated_at: at
      }
    ])
  end
end
