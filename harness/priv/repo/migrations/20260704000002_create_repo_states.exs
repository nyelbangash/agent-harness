defmodule Harness.Repo.Migrations.CreateRepoStates do
  use Ecto.Migration

  def change do
    create table(:repo_states) do
      add :repo, :string, null: false
      add :etag, :string
      add :last_polled_at, :utc_datetime_usec
      add :last_status, :integer
      add :default_branch, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repo_states, [:repo])
  end
end
