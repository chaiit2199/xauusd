defmodule GoldBackend.Repo.Migrations.CreateMarketCandles do
  use Ecto.Migration

  def change do
    create table(:market_candles) do
      add(:source, :string, null: false)
      add(:timeframe, :integer, null: false)
      add(:open_time, :utc_datetime, null: false)

      for field <- [:open, :high, :low, :close] do
        add(field, :decimal, precision: 16, scale: 6, null: false)
      end

      timestamps()
    end

    create(unique_index(:market_candles, [:source, :timeframe, :open_time]))

    create(
      constraint(:market_candles, :valid_ohlc,
        check:
          "low > 0 AND high >= low AND high >= open AND high >= close AND low <= open AND low <= close"
      )
    )

    create(constraint(:market_candles, :valid_timeframe, check: "timeframe IN (900, 3600)"))

    # Reserve requests before HTTP, including failures. Survives restarts and
    # serializes the shared free-tier quota across application instances.
    create table(:ohlc_requests) do
      add(:requested_at, :utc_datetime, null: false)
      add(:timeframe, :integer, null: false)
      add(:open_time, :utc_datetime, null: false)
      add(:status, :string, default: "pending", null: false)
    end

    create(index(:ohlc_requests, [:requested_at]))
  end
end
