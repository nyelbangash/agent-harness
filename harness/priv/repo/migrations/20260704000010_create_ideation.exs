defmodule Harness.Repo.Migrations.CreateIdeation do
  use Ecto.Migration

  def change do
    create table(:ideation_sessions) do
      add :seed_prompt, :text, null: false
      add :mode, :string, null: false, default: "explore"
      add :budget_minutes, :integer, null: false, default: 180
      add :status, :string, null: false, default: "running"
      # running | stopped | synthesized | failed
      add :stop_reason, :string
      add :iterations, :integer, null: false, default: 0
      add :critiques, :integer, null: false, default: 0
      add :no_progress_streak, :integer, null: false, default: 0
      add :synthesis_path, :string
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ideation_sessions, [:status])

    create table(:ideas) do
      add :session_id, references(:ideation_sessions, on_delete: :delete_all), null: false
      add :parent_id, references(:ideas, on_delete: :nilify_all)
      add :depth, :integer, null: false, default: 0
      add :title, :string, null: false
      add :summary, :text
      add :status, :string, null: false, default: "seed"
      # seed | frontier | expanded | pruned | synthesized
      add :score, :float, null: false, default: 5.0
      add :artifact_path, :string
      add :model_used, :string
      add :tokens_in, :integer, null: false, default: 0
      add :tokens_out, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ideas, [:session_id])
    create index(:ideas, [:parent_id])
    create index(:ideas, [:session_id, :status])
  end
end
