defmodule Harness.Repo.Migrations.AddPrToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :pr_url, :string
      add :pr_number, :integer
    end
  end
end
