defmodule GoldBackend.Repo.Migrations.CreateStrategyNotifications do
  use Ecto.Migration

  def change do
    create table(:strategy_notifications) do
      add(:setup_id, :text, null: false)
      add(:event, :text, null: false)
      add(:sent_at, :utc_datetime, null: false)
    end

    create(unique_index(:strategy_notifications, [:setup_id, :event]))
  end
end
