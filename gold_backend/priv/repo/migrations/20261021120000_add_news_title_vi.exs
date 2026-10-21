defmodule GoldBackend.Repo.Migrations.AddNewsTitleVi do
  use Ecto.Migration

  def change do
    alter table(:news_articles) do
      add :title_vi, :text
    end
  end
end
