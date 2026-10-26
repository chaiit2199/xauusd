defmodule GoldBackend.Repo.Migrations.CreateStrategyCandidates do
  use Ecto.Migration

  def change do
    create table(:strategy_candidates, primary_key: false) do
      add(:setup_id, :string, primary_key: true)
      add(:snapshot, :map, null: false)
      add(:first_seen_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:plan_ready, :boolean, null: false, default: false)
      add(:ready_to_enter, :boolean, null: false, default: false)
    end

    create(index(:strategy_candidates, [:first_seen_at]))
  end
end
