defmodule GoldBackend.Trading.GoldPrice do
  use Ecto.Schema
  import Ecto.Changeset

  schema "gold_prices" do
    field :price, :decimal
    field :currency, :string, default: "USD"
    field :origin, :string
    field :timestamp, :utc_datetime

    timestamps()
  end

  def changeset(gold_price, attrs) do
    gold_price
    |> cast(attrs, [:price, :currency, :origin, :timestamp])
    |> validate_required([:price, :currency, :origin, :timestamp])
    |> validate_inclusion(:origin, ~w(metals_dev gold_api synthetic seed))
  end
end
