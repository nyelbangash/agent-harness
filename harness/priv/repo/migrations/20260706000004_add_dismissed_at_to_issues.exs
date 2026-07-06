defmodule Harness.Repo.Migrations.AddDismissedAtToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :dismissed_at, :utc_datetime_usec
    end

    create index(:issues, [:dismissed_at])
  end
end
