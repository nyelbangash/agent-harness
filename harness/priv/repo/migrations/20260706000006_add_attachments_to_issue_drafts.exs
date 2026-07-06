defmodule Harness.Repo.Migrations.AddAttachmentsToIssueDrafts do
  use Ecto.Migration

  def change do
    alter table(:issue_drafts) do
      add :attachments, :text
    end
  end
end
