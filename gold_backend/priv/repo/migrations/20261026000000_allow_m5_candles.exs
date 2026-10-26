defmodule GoldBackend.Repo.Migrations.AllowM5Candles do
  use Ecto.Migration

  def up do
    drop(constraint(:market_candles, :valid_timeframe))
    create(constraint(:market_candles, :valid_timeframe, check: "timeframe IN (300, 900, 3600)"))
  end

  def down do
    execute("DELETE FROM market_candles WHERE timeframe = 300")
    drop(constraint(:market_candles, :valid_timeframe))
    create(constraint(:market_candles, :valid_timeframe, check: "timeframe IN (900, 3600)"))
  end
end
