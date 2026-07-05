defmodule Harness.Repo.Migrations.CreatePrCommentHandles do
  use Ecto.Migration

  def change do
    create table(:pr_comment_handles) do
      add :repo, :string, null: false
      add :pr_number, :integer, null: false
      add :comment_id, :bigint, null: false
      # "review" = inline diff comment; "issue" = PR conversation comment
      add :comment_type, :string, null: false
      # "fix" | "decline_with_reason" — filled by RespondWorker after completion
      add :action, :string
      add :run_id, :bigint

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:pr_comment_handles, [:repo, :comment_id, :comment_type])
  end
end
