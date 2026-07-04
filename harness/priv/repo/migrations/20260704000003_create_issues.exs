defmodule Harness.Repo.Migrations.CreateIssues do
  use Ecto.Migration

  def change do
    create table(:issues) do
      add :repo, :string, null: false
      add :number, :integer, null: false
      add :github_id, :bigint, null: false
      add :title, :string, null: false
      add :body, :text
      add :state, :string, null: false, default: "open"
      add :labels, {:array, :string}, null: false, default: []
      add :author, :string
      add :url, :string
      add :comments_count, :integer, null: false, default: 0
      add :github_updated_at, :utc_datetime_usec
      add :pipeline_state, :string, null: false, default: "incoming"
      add :last_synced_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:issues, [:repo, :number])
    create index(:issues, [:pipeline_state])
    create index(:issues, [:github_updated_at])
  end
end
