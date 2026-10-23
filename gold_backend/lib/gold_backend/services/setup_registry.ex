defmodule GoldBackend.Services.SetupRegistry do
  @moduledoc "Persist the first observed setup so a history correction or restart cannot move its levels."
  import Ecto.Query
  alias GoldBackend.Repo
  alias GoldBackend.Services.SetupLifecycle

  def resolve(%{id: id} = setup, bars, bias, now, events) do
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
    SetupLifecycle.validate(original, bars, bias, now, events)
  end

  def resolve(setup, _, _, _, _), do: setup
end
