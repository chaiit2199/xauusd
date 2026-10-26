defmodule GoldBackend.Replay.Comparison do
  @moduledoc "Descriptive matching by side and confirmation time; not causal rule attribution."

  def build(old, new) do
    old_keys = MapSet.new(old.candidate_observations, &key/1)
    only_new = Enum.reject(new.candidate_observations, &MapSet.member?(old_keys, key(&1)))

    %{
      match_method:
        "side + confirmation formed_at; different branches at the same time are grouped, so attribution is approximate",
      new_only_count:
        if(is_nil(old.candidate_count) or is_nil(new.candidate_count),
          do: nil,
          else: length(only_new)
        ),
      new_only_metrics: GoldBackend.Replay.Runner.metrics(only_new),
      new_only_outcomes: Enum.frequencies_by(only_new, & &1.outcome),
      new_only_candidates: only_new,
      causal_rule_attribution: "unavailable: matched replay and isolated rule ablations required"
    }
  end

  defp key(row), do: {row.side, row.formed_at}
end
