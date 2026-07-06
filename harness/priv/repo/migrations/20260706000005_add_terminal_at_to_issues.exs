defmodule Harness.Repo.Migrations.AddTerminalAtToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :terminal_at, :utc_datetime_usec
    end

    execute(
      "UPDATE issues SET terminal_at = updated_at WHERE pipeline_state IN ('done', 'failed', 'skipped')",
      ""
    )

    create index(:issues, [:terminal_at])
  end
end
