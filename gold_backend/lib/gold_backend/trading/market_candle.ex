defmodule GoldBackend.Trading.MarketCandle do
  use Ecto.Schema

  schema "market_candles" do
    field :source, :string
    field :timeframe, :integer
    field :open_time, :utc_datetime
    field :open, :decimal
    field :high, :decimal
    field :low, :decimal
    field :close, :decimal
    timestamps()
  end

  def to_bar(row) do
    %{
      open_time: row.open_time,
      open: Decimal.to_float(row.open),
      high: Decimal.to_float(row.high),
      low: Decimal.to_float(row.low),
      close: Decimal.to_float(row.close),
      confirmed: true,
      source: row.source
    }
  end
end
