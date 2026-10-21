defmodule GoldBackend.Trading.NewsArticle do
  use Ecto.Schema
  import Ecto.Changeset

  schema "news_articles" do
    field :title, :string
    field :title_vi, :string
    field :url, :string
    field :source, :string
    field :content, :string
    field :published_at, :utc_datetime

    timestamps()
  end

  def changeset(news_article, attrs) do
    news_article
    |> cast(attrs, [:title, :title_vi, :url, :source, :content, :published_at])
    |> validate_required([:title, :url, :source])
    |> validate_length(:title, min: 10, max: 500)
    |> unique_constraint(:url)
  end
end
