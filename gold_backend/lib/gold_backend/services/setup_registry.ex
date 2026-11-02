defmodule GoldBackend.Services.SetupRegistry do
  @moduledoc "Persist the first observed setup so a history correction or restart cannot move its levels."
  import Ecto.Query
  alias GoldBackend.Repo
  alias GoldBackend.Services.SetupLifecycle

  def resolve(setup, bars, bias, now, events) do
    all = [setup | Map.get(setup, :alternatives, [])] |> Enum.uniq_by(&Map.get(&1, :id))

    resolved =
      Enum.map(all, fn candidate ->
        # Timeframe-specific alternatives are validated with their own bars upstream.
        candidate_bars =
          if Map.get(candidate, :timeframe_seconds, 900) ==
               Map.get(setup, :timeframe_seconds, 900),
             do: bars,
             else: []

        resolve_one(Map.delete(candidate, :alternatives), candidate_bars, bias, now, events)
      end)

    Enum.find(resolved, &(&1.state == "ready" and not &1.blocked)) || hd(resolved)
  end

  defp resolve_one(%{id: id} = setup, bars, bias, now, events) do
    stamp = DateTime.truncate(now, :second)

    Repo.insert_all(
      "strategy_setups",
      [
        %{
          setup_id: id,
          snapshot: Jason.encode!(setup) |> Jason.decode!(),
          inserted_at: stamp,
          updated_at: stamp
        }
      ],
      on_conflict: :nothing
    )

    saved = Repo.one!(from s in "strategy_setups", where: s.setup_id == ^id, select: s.snapshot)
    # All keys originate in the fixed SetupEngine/Indicators schema, not user input.
    original = saved |> Jason.encode!() |> Jason.decode!(keys: :atoms!)
    checked = SetupLifecycle.validate(original, bars, bias, now, events)

    if setup.state in ["expired", "invalidated"] do
      Repo.insert_all(
        "strategy_invalidations",
        [
          %{
            setup_id: id,
            state: setup.state,
            reason: setup.reason,
            inserted_at: stamp,
            updated_at: stamp
          }
        ],
        on_conflict: :nothing
      )
    end

    case Repo.one(
           from s in "strategy_invalidations",
             where: s.setup_id == ^id,
             select: %{state: s.state, reason: s.reason}
         ) do
      nil ->
        checked

      terminal ->
        Map.merge(checked, %{blocked: true, state: terminal.state, reason: terminal.reason})
    end
  end

  defp resolve_one(setup, _, _, _, _), do: setup
end
