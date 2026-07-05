defmodule Harness.Repo.Migrations.CreateTriageOutcomes do
  use Ecto.Migration

  def change do
    create table(:triage_outcomes) do
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :triage_id, references(:triages, on_delete: :nilify_all)
      add :outcome, :string, null: false
      add :resolved_at, :utc_datetime_usec, null: false
      add :days_open, :float, null: false
      add :amend_commit_count, :integer
      add :shadow, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:triage_outcomes, [:issue_id])
    create index(:triage_outcomes, [:outcome])
    create index(:triage_outcomes, [:triage_id])
  end
end
