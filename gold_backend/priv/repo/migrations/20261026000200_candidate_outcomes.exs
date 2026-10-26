defmodule GoldBackend.Repo.Migrations.CandidateOutcomes do
  use Ecto.Migration

  def change do
    alter table(:strategy_candidates) do
      add(:result, :map)
    end
  end
end
