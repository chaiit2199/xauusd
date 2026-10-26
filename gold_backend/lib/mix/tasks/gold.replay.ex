defmodule Mix.Tasks.Gold.Replay do
  use Mix.Task

  @shortdoc "Replay old and new strategy against the same validated CSV/JSON without network or database writes"
  def run([path]) do
    case GoldBackend.Replay.Dataset.load(path) do
      {:ok, dataset} ->
        reports = for mode <- [:old, :new], do: GoldBackend.Replay.Runner.run(dataset, mode)
        [old, new] = reports

        Mix.shell().info(
          Jason.encode!(
            %{
              dataset_validation: Map.get(dataset, :validation),
              reports: reports,
              comparison: GoldBackend.Replay.Comparison.build(old, new),
              split: GoldBackend.Replay.Split.run(dataset)
            },
            pretty: true
          )
        )

      {:error, reason} ->
        Mix.raise("Invalid dataset: #{reason}")
    end
  end

  def run(_), do: Mix.raise("Usage: mix gold.replay path/to/dataset.json (or .csv)")
end
