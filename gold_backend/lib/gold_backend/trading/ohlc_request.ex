defmodule GoldBackend.Trading.OhlcRequest do
  use Ecto.Schema

  schema "ohlc_requests" do
    field :requested_at, :utc_datetime
    field :timeframe, :integer
    field :open_time, :utc_datetime
    field :status, :string
  end
end
