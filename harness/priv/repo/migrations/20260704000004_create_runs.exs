defmodule Harness.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs) do
      add :kind, :string, null: false
      add :ref, :string
      add :issue_id, references(:issues, on_delete: :nilify_all)
      add :model, :string
      add :status, :string, null: false, default: "queued"
      add :turns, :integer, null: false, default: 0
      add :tokens_in, :integer, null: false, default: 0
      add :tokens_out, :integer, null: false, default: 0
      add :cost_estimate, :float
      add :used_overage, :boolean, null: false, default: false
      add :worktree, :string
      add :session_id, :string
      add :os_pid, :integer
      add :exit_code, :integer
      add :result_subtype, :string
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:status])
    create index(:runs, [:kind])
    create index(:runs, [:issue_id])
    create index(:runs, [:inserted_at])
  end
end
