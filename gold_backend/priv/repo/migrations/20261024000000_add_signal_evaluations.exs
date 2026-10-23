defmodule GoldBackend.Repo.Migrations.AddSignalEvaluations do
  use Ecto.Migration

  def change do
    # Keep v1 tickets intact as a baseline; signals are not broker fills.
    create table(:strategy_signals) do
      add(:setup_id, :string, null: false)
      add(:session_key, :string, null: false)
      add(:candle, :utc_datetime, null: false)
      add(:side, :string, null: false)
      add(:plan, :map, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:strategy_signals, [:setup_id]))

    create table(:strategy_evaluations) do
      add(:evaluated_at, :utc_datetime, null: false)
      add(:version, :string, null: false)
      add(:snapshot, :map, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:strategy_evaluations, [:evaluated_at, :version]))

    create table(:strategy_invalidations, primary_key: false) do
      add(:setup_id, :string, primary_key: true)
      add(:state, :string, null: false)
      add(:reason, :text, null: false)
      timestamps(type: :utc_datetime)
    end
  end
end
