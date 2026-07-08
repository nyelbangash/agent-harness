defmodule Harness.Repo.Migrations.AddLastSelfAckCommentIdToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :last_self_ack_comment_id, :integer
    end
  end
end
