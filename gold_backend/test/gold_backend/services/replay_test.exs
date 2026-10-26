defmodule GoldBackend.Services.ReplayTest do
  use ExUnit.Case, async: true
  alias GoldBackend.Replay.{Dataset, Runner}
  @as_of ~U[2026-10-23 08:00:00Z]

  defp dataset do
    h1 =
      for n <- 0..59 do
        %{
          open_time: DateTime.add(@as_of, (n - 60) * 3600),
          timeframe: 3600,
          open: 100.0,
          high: if(n == 35, do: 110.0, else: 100.5),
          low: 99.5,
          close: 100.0,
          confirmed: true
        }
      end

    m15 =
      for n <- 0..49 do
        %{
          open_time: DateTime.add(@as_of, (n - 50) * 900),
          timeframe: 900,
          open: 100.0,
          high: if(n == 49, do: 100.6, else: 100.5),
          low: if(n == 49, do: 98.5, else: 99.5),
          close: if(n == 49, do: 100.5, else: 100.0),
          confirmed: true
        }
      end

    %{candles: Enum.sort_by(h1 ++ m15, & &1.open_time, DateTime), quotes: []}
  end

  test "empty history cannot be mistaken for a measured zero-candidate result" do
    for mode <- [:old, :new] do
      result = Runner.run(%{candles: [], quotes: []}, mode)
      assert result.data_quality.status == "insufficient_data"
      assert result.candidate_count == nil and result.ready_to_enter == nil
    end
  end

  test "CSV and JSON validate times, OHLC and reject duplicate rows" do
    path = Path.join(System.tmp_dir!(), "replay-#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(path) end)

    File.write!(
      path,
      "open_time,timeframe,open,high,low,close\n2026-10-23T07:45:00Z,M15,100,101,99,100\n"
    )

    assert {:ok, %{candles: [%{timeframe: 900}]}} = Dataset.load(path)
    File.write!(path, File.read!(path) <> "2026-10-23T07:45:00Z,M15,100,101,99,100\n")
    assert {:error, "duplicate candle timeframe/open_time"} = Dataset.load(path)
  end

  test "future candles and quotes do not alter earlier detected setups" do
    data = dataset()

    future = %{
      open_time: @as_of,
      timeframe: 900,
      open: 100.0,
      high: 101.0,
      low: 99.0,
      close: 100.0,
      confirmed: true
    }

    extended = %{
      data
      | candles: data.candles ++ [future],
        quotes: [%{price: 9999.0, timestamp: DateTime.add(@as_of, 900)}]
    }

    for mode <- [:old, :new] do
      before = Runner.run(data, mode).observations
      if mode == :new, do: assert(before != [])

      after_rows =
        Runner.run(extended, mode).observations
        |> Enum.filter(&(&1.formed_at <= DateTime.to_iso8601(@as_of)))

      for row <- before do
        match = Enum.find(after_rows, &(&1.id == row.id))
        assert match != nil

        assert Map.take(match, [:reference, :stop, :tp1, :formed_at]) ==
                 Map.take(row, [:reference, :stop, :tp1, :formed_at])
      end
    end
  end

  test "readiness requires a recorded quote and calendar, and high-impact news blocks it" do
    data = dataset()
    [setup | _] = Runner.run(data, :new).observations
    {:ok, at, _} = DateTime.from_iso8601(setup.formed_at)
    calendar = %{from: DateTime.add(at, -86400), until: DateTime.add(at, 86400), events: []}

    data =
      Map.merge(data, %{calendar: calendar, quotes: [%{timestamp: at, price: setup.reference}]})

    assert Runner.run(data, :new).ready_to_enter_observed == 1

    event = %{
      time: DateTime.add(at, 300),
      known_at: DateTime.add(at, -86400),
      title: "USD",
      impact: "High",
      country: "USD"
    }

    assert Runner.run(%{data | calendar: %{calendar | events: [event]}}, :new).ready_to_enter_observed ==
             0

    future_event = %{event | known_at: DateTime.add(at, 60)}

    assert Runner.run(%{data | calendar: %{calendar | events: [future_event]}}, :new).ready_to_enter_observed ==
             1
  end

  test "both frozen old and new run without future quotes or fabricated readiness" do
    for mode <- [:old, :new] do
      report = Runner.run(dataset(), mode)
      assert report.strategy == Atom.to_string(mode)
      assert report.ready_to_enter == nil
      assert is_integer(report.candidate_count)
      assert report.evaluated_cycles > 0
      assert report.readiness_note =~ "calendar"
    end
  end

  test "dataset reports gaps and rejects reversed timestamps without synthesizing bars" do
    path = Path.join(System.tmp_dir!(), "gap-#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(path) end)
    header = "open_time,timeframe,open,high,low,close\n"
    first = "2026-10-23T07:00:00Z,M15,100,101,99,100\n"
    second = "2026-10-23T07:30:00Z,M15,100,101,99,100\n"
    File.write!(path, header <> first <> second)
    assert {:ok, data} = Dataset.load(path)
    assert length(data.candles) == 2
    assert [%{missing_intervals: 1}] = data.validation.timeframes[900].gaps
    assert data.validation.point_in_time == "not_fully_point_in_time"
    File.write!(path, header <> second <> first)
    assert {:error, reason} = Dataset.load(path)
    assert reason =~ "timestamps must increase"
  end

  test "chronological split labels small sample and preserves no M5 requirement" do
    result = GoldBackend.Replay.Split.run(dataset())
    assert result.status == "insufficient_sample"

    for mode <- [:old, :new] do
      assert result.reports[mode].out_of_sample.point_in_time == "not_fully_point_in_time"
    end
  end
end
