defmodule GoldBackend.Repo.Migrations.FreezeStrategySetups do
  use Ecto.Migration

  def change do
    create table(:strategy_setups, primary_key: false) do
      add(:setup_id, :string, primary_key: true)
      add(:snapshot, :map, null: false)
      timestamps(type: :utc_datetime)
    end
  end
end
