defmodule Harness.Repo.Migrations.AddPrCommentsSinceToRepoStates do
  use Ecto.Migration

  def change do
    alter table(:repo_states) do
      add :pr_comments_since, :utc_datetime_usec
    end
  end
end
