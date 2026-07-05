defmodule Harness.Repo.Migrations.CreateIssueDrafts do
  use Ecto.Migration

  def change do
    create table(:issue_drafts) do
      add :prompt,         :text, null: false
      add :repo,           :string, null: false
      add :run_id,         references(:runs, on_delete: :nilify_all)
      add :title,          :string
      add :body,           :text
      add :scope_hint,     :string
      add :open_questions, :text
      add :status,         :string, null: false, default: "draft"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:issue_drafts, [:status])
    create index(:issue_drafts, [:inserted_at])
    create index(:issue_drafts, [:run_id])
  end
end
