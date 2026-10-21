defmodule GoldBackend.Repo.Migrations.CreateGoldTradingTables do
  use Ecto.Migration

  def change do
    create table(:gold_prices) do
      add :price, :decimal, precision: 12, scale: 2, null: false
      add :currency, :string, default: "USD", null: false
      add :origin, :string, null: false
      add :timestamp, :utc_datetime, null: false

      timestamps()
    end

    create index(:gold_prices, [:timestamp])

    create table(:news_articles) do
      add :title, :text, null: false
      add :url, :text, null: false
      add :source, :string, null: false
      add :content, :text
      add :published_at, :utc_datetime

      timestamps()
    end

    create unique_index(:news_articles, [:url])
    create index(:news_articles, [:published_at])
  end
end
