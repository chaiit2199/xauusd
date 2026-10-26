defmodule GoldBackend.Repo.Migrations.CreateReplayObservations do
  use Ecto.Migration

  def change do
    create table(:strategy_observations) do
      add(:evaluated_at, :utc_datetime_usec, null: false)
      add(:version, :string, null: false)
      add(:setup_id, :string)
      add(:quote_at, :utc_datetime_usec)
      add(:quote_price, :decimal, precision: 16, scale: 6)
      add(:snapshot, :map, null: false)
    end

    create(index(:strategy_observations, [:evaluated_at, :version]))
  end
end
