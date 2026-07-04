defmodule Harness.Repo.Migrations.CreatePlans do
  use Ecto.Migration

  def change do
    create table(:plans) do
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :nilify_all), null: false
      add :plan_path, :string, null: false
      add :context_path, :string, null: false
      add :branch, :string
      add :issue_comment_id, :bigint
      add :summary, :text
      add :status, :string, null: false, default: "ready"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:plans, [:issue_id])
  end
end
