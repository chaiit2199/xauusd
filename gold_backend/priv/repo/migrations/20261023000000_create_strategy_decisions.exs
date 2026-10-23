defmodule GoldBackend.Repo.Migrations.CreateStrategyDecisions do
  use Ecto.Migration

  def change do
    create table(:strategy_decisions) do
      add(:candle, :utc_datetime, null: false)
      add(:version, :string, null: false)
      add(:snapshot, :map, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:strategy_decisions, [:candle, :version]))

    create table(:strategy_tickets) do
      add(:session_key, :string, null: false)
      add(:candle, :utc_datetime, null: false)
      add(:side, :string, null: false)
      add(:plan, :map, null: false)
      timestamps(type: :utc_datetime)
    end

    create(unique_index(:strategy_tickets, [:session_key]))
    create(unique_index(:strategy_tickets, [:candle]))
  end
end
