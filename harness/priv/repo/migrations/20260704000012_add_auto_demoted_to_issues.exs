defmodule Harness.Repo.Migrations.AddAutoDemotedToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :auto_demoted, :boolean, null: false, default: false
    end
  end
end
