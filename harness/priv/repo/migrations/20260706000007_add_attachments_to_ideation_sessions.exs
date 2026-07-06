defmodule Harness.Repo.Migrations.AddAttachmentsToIdeationSessions do
  use Ecto.Migration

  def change do
    alter table(:ideation_sessions) do
      add :attachments, :text
    end
  end
end
