defmodule Harness.Repo.Migrations.CreateRunEvents do
  use Ecto.Migration

  def change do
    create table(:run_events) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :type, :string, null: false
      add :payload, :map, null: false
      add :at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:run_events, [:run_id, :seq])
  end
end
