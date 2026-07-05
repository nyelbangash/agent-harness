defmodule Harness.Repo.Migrations.CreateBriefings do
  use Ecto.Migration

  def change do
    create table(:briefings) do
      add :date, :date, null: false
      add :markdown, :text, null: false
      add :dismissed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:briefings, [:date])
  end
end
