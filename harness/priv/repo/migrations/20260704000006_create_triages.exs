defmodule Harness.Repo.Migrations.CreateTriages do
  use Ecto.Migration

  def change do
    create table(:triages) do
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :nilify_all)
      add :proposed_route, :string
      add :confidence, :float
      add :reasoning, :text
      add :estimated_scope, :string
      add :risk_flags, {:array, :string}, null: false, default: []
      add :final_route, :string, null: false
      add :decision_reason, :string, null: false
      add :model, :string
      add :attempt, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create index(:triages, [:issue_id])
  end
end
