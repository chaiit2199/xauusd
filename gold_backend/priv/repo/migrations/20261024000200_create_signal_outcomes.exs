defmodule GoldBackend.Repo.Migrations.CreateSignalOutcomes do
  use Ecto.Migration

  def change do
    create table(:signal_outcomes, primary_key: false) do
      add(:setup_id, :string, primary_key: true)
      add(:published_at, :utc_datetime_usec, null: false)
      add(:entry_expires_at, :utc_datetime_usec, null: false)
      add(:horizon_at, :utc_datetime_usec, null: false)
      add(:result, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:signal_outcomes, [:published_at]))
  end
end
