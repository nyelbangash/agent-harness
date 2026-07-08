defmodule Harness.Repo.Migrations.CreateProjectStates do
  use Ecto.Migration

  def change do
    create table(:project_states) do
      add :owner, :string, null: false
      add :number, :integer, null: false
      add :last_polled_at, :utc_datetime_usec
      add :last_status, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:project_states, [:owner, :number])
  end
end
